/*
 * norc-rtc: the media of a call (audio and video over WebRTC) with GStreamer's
 * webrtcbin, controlled with JSON lines on stdin and stdout (see protocol.md).
 *
 * All state is changed on the main loop: input lines are read on a thread and
 * passed to it, webrtcbin's callbacks only write messages (under a lock) or
 * emit its signals.
 */

#define GST_USE_UNSTABLE_API
#include <gst/gst.h>
#include <gst/sdp/sdp.h>
#include <gst/webrtc/webrtc.h>
#include <json-glib/json-glib.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <io.h>
#define read _read
#else
#include <unistd.h>
#endif

static GMainLoop *loop;
static GstElement *pipeline, *webrtc;
static int exit_code = 0;

/* Guards stdout, written by the main loop and the threads of webrtcbin */
static GMutex output_lock;

/* The direction of a media, from the own side */
typedef enum { NONE, SEND, RECEIVE, BOTH } Direction;

static Direction audio = BOTH, video = NONE;
static gboolean test = FALSE, bundle = TRUE;

static gboolean sends(Direction d);
static void set_directions(void);
static void update_sending(void);
static const char *transceiver_media(GstWebRTCRTPTransceiver *t);
static gchar *stun = NULL, **turn = NULL;
static gchar *audio_source = NULL, *audio_sink = NULL, *video_source = NULL,
             *video_sink = NULL, *audio_file = NULL;

static gboolean parse_direction(const char *value, Direction *d,
                                GError **error) {
  const char *names[] = {"none", "send", "receive", "both"};
  for (int i = 0; i < 4; i++)
    if (g_strcmp0(value, names[i]) == 0) {
      *d = (Direction)i;
      return TRUE;
    }
  g_set_error(error, G_OPTION_ERROR, G_OPTION_ERROR_BAD_VALUE,
              "invalid direction: %s (both, send, receive, none)", value);
  return FALSE;
}

static gboolean audio_option(const char *name, const char *value,
                             gpointer data, GError **error) {
  return parse_direction(value, &audio, error);
}

/* --video: both directions */
static gboolean video_option(const char *name, const char *value,
                             gpointer data, GError **error) {
  return parse_direction(value ? value : "both", &video, error);
}

static GOptionEntry options[] = {
    {"audio", 0, 0, G_OPTION_ARG_CALLBACK, audio_option,
     "Audio: both directions (default), send, receive or none", "DIRECTION"},
    {"video", 0, G_OPTION_FLAG_OPTIONAL_ARG, G_OPTION_ARG_CALLBACK,
     video_option, "Video: both directions (without value), send, receive or none",
     "DIRECTION"},
    {"stun", 0, 0, G_OPTION_ARG_STRING, &stun, "STUN server",
     "stun://HOST:PORT"},
    {"turn", 0, 0, G_OPTION_ARG_STRING_ARRAY, &turn, "TURN server (repeatable)",
     "turn://USER:PASSWORD@HOST:PORT"},
    {"audio-source", 0, 0, G_OPTION_ARG_STRING, &audio_source,
     "Audio source (default autoaudiosrc)", "PIPELINE"},
    {"audio-file", 0, 0, G_OPTION_ARG_FILENAME, &audio_file,
     "Play a file (any format GStreamer decodes) instead of the audio source",
     "PATH"},
    {"audio-sink", 0, 0, G_OPTION_ARG_STRING, &audio_sink,
     "Audio sink (default autoaudiosink)", "PIPELINE"},
    {"video-source", 0, 0, G_OPTION_ARG_STRING, &video_source,
     "Video source (default autovideosrc)", "PIPELINE"},
    {"video-sink", 0, 0, G_OPTION_ARG_STRING, &video_sink,
     "Video sink (default autovideosink)", "PIPELINE"},
    {"no-bundle", 0, G_OPTION_FLAG_REVERSE, G_OPTION_ARG_NONE, &bundle,
     "A connection for each media (the peer doesn't support BUNDLE)", NULL},
    {"test", 0, 0, G_OPTION_ARG_NONE, &test,
     "Test signals as sources, discard received media", NULL},
    {NULL}};

/* --- Messages
 * -------------------------------------------------------------------------------------------------
 */

/* A message to write: `type` and the members added to the returned builder,
 * written by `write_message` */
static JsonBuilder *message(const char *type) {
  JsonBuilder *b = json_builder_new();
  json_builder_begin_object(b);
  json_builder_set_member_name(b, "type");
  json_builder_add_string_value(b, type);
  return b;
}

static void member(JsonBuilder *b, const char *name, const char *value) {
  json_builder_set_member_name(b, name);
  json_builder_add_string_value(b, value);
}

static void write_message(JsonBuilder *b) {
  json_builder_end_object(b);
  JsonNode *root = json_builder_get_root(b);
  gchar *line = json_to_string(root, FALSE);
  g_mutex_lock(&output_lock);
  fputs(line, stdout);
  fputc('\n', stdout);
  fflush(stdout);
  g_mutex_unlock(&output_lock);
  g_free(line);
  json_node_unref(root);
  g_object_unref(b);
}

/* A message with one string member, e.g. {"type": "state", "state":
 * "connected"} */
static void send_value(const char *type, const char *name, const char *value) {
  JsonBuilder *b = message(type);
  member(b, name, value);
  write_message(b);
}

/* Reports an error and ends the call */
static void fail(const char *format, ...) {
  va_list args;
  va_start(args, format);
  gchar *text = g_strdup_vprintf(format, args);
  va_end(args);
  send_value("error", "message", text);
  g_free(text);
  exit_code = 1;
  g_main_loop_quit(loop);
}

/* --- Session descriptions
 * ------------------------------------------------------------------------------------
 */

static void send_description(GstWebRTCSessionDescription *desc) {
  gchar *text = gst_sdp_message_as_text(desc->sdp);
  JsonBuilder *b = message("sdp");
  member(b, "sdp_type", gst_webrtc_sdp_type_to_string(desc->type));
  member(b, "sdp", text);
  write_message(b);
  g_free(text);
}

/* The offer or answer created by webrtcbin: set as local description, sent to
 * the peer */
/* The answer is set (own or of the peer): the negotiated directions apply */
static void on_answer_set(GstPromise *promise, gpointer user_data) {
  gst_promise_unref(promise);
  update_sending();
}

static void on_description_created(GstPromise *promise, gpointer user_data) {
  const char *kind = user_data;
  GstWebRTCSessionDescription *desc = NULL;
  if (gst_promise_wait(promise) == GST_PROMISE_RESULT_REPLIED) {
    const GstStructure *reply = gst_promise_get_reply(promise);
    GError *error = NULL;
    if (gst_structure_get(reply, "error", G_TYPE_ERROR, &error, NULL)) {
      fail("cannot create the %s: %s", kind, error->message);
      g_error_free(error);
    } else
      gst_structure_get(reply, kind, GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &desc,
                        NULL);
  }
  gst_promise_unref(promise);
  if (desc == NULL)
    return;
  // the answer negotiated the directions
  g_signal_emit_by_name(
      webrtc, "set-local-description", desc,
      (desc->type == GST_WEBRTC_SDP_TYPE_ANSWER)
          ? gst_promise_new_with_change_func(on_answer_set, NULL, NULL)
          : NULL);
  send_description(desc);
  gst_webrtc_session_description_free(desc);
}

static void create(const char *kind) {
  GstPromise *promise = gst_promise_new_with_change_func(on_description_created,
                                                         (gpointer)kind, NULL);
  g_signal_emit_by_name(
      webrtc, strcmp(kind, "offer") == 0 ? "create-offer" : "create-answer",
      NULL, promise);
}

/* The peer's description was set: an offer is answered */
static void on_remote_set(GstPromise *promise, gpointer user_data) {
  gboolean offer = GPOINTER_TO_INT(user_data);
  const GstStructure *reply =
      (gst_promise_wait(promise) == GST_PROMISE_RESULT_REPLIED)
          ? gst_promise_get_reply(promise)
          : NULL;
  GError *error = NULL;
  if (reply != NULL &&
      gst_structure_get(reply, "error", G_TYPE_ERROR, &error, NULL)) {
    fail("invalid sdp: %s", error->message);
    g_error_free(error);
  } else if (offer) {
    set_directions();
    create("answer");
  } else
    update_sending();
  gst_promise_unref(promise);
}

static void set_remote(const char *type, const char *text) {
  GstWebRTCSDPType sdp_type;
  if (g_strcmp0(type, "offer") == 0)
    sdp_type = GST_WEBRTC_SDP_TYPE_OFFER;
  else if (g_strcmp0(type, "answer") == 0)
    sdp_type = GST_WEBRTC_SDP_TYPE_ANSWER;
  else {
    fail("invalid sdp_type: %s", type ? type : "(none)");
    return;
  }
  GstSDPMessage *sdp;
  if (text == NULL || gst_sdp_message_new_from_text(text, &sdp) != GST_SDP_OK ||
      gst_sdp_message_medias_len(sdp) == 0) {
    fail("invalid sdp: no media");
    return;
  }
  GstWebRTCSessionDescription *desc =
      gst_webrtc_session_description_new(sdp_type, sdp);
  GstPromise *promise = gst_promise_new_with_change_func(
      on_remote_set, GINT_TO_POINTER(sdp_type == GST_WEBRTC_SDP_TYPE_OFFER),
      NULL);
  g_signal_emit_by_name(webrtc, "set-remote-description", desc, promise);
  gst_webrtc_session_description_free(desc);
}

/* --- ICE and the connection
 * ----------------------------------------------------------------------------------
 */

static void on_ice_candidate(GstElement *webrtc, guint mline, gchar *candidate,
                             gpointer user_data) {
  JsonBuilder *b = message("candidate");
  json_builder_set_member_name(b, "mline");
  json_builder_add_int_value(b, mline);
  member(b, "candidate", candidate);
  write_message(b);
}

static void on_gathering_state(GstElement *webrtc, GParamSpec *spec,
                               gpointer user_data) {
  GstWebRTCICEGatheringState state;
  g_object_get(webrtc, "ice-gathering-state", &state, NULL);
  if (state == GST_WEBRTC_ICE_GATHERING_STATE_COMPLETE)
    send_value("gathering", "state", "complete");
}

static void on_connection_state(GstElement *webrtc, GParamSpec *spec,
                                gpointer user_data) {
  GstWebRTCPeerConnectionState state;
  g_object_get(webrtc, "connection-state", &state, NULL);
  const char *name = NULL;
  switch (state) {
  case GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTING:
    name = "connecting";
    break;
  case GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTED:
    name = "connected";
    break;
  case GST_WEBRTC_PEER_CONNECTION_STATE_DISCONNECTED:
    name = "disconnected";
    break;
  case GST_WEBRTC_PEER_CONNECTION_STATE_FAILED:
    name = "failed";
    break;
  case GST_WEBRTC_PEER_CONNECTION_STATE_CLOSED:
    name = "closed";
    break;
  default:
    break;
  }
  if (name != NULL)
    send_value("state", "state", name);
}

/* --- Media
 * ---------------------------------------------------------------------------------------------------
 */

/* A decoded stream of the peer: played (or discarded with --test) */
static void on_decoded(GstElement *decodebin, GstPad *pad, gpointer user_data) {
  GstCaps *caps = gst_pad_get_current_caps(pad);
  const char *name = gst_structure_get_name(gst_caps_get_structure(caps, 0));
  const gboolean audio = g_str_has_prefix(name, "audio/");
  gst_caps_unref(caps);
  if (!audio && !g_str_has_prefix(name, "video/"))
    return;
  gchar *desc =
      test    ? g_strdup("queue ! fakesink")
      : audio ? g_strdup_printf("queue ! audioconvert ! audioresample ! %s",
                                audio_sink ? audio_sink : "autoaudiosink")
              : g_strdup_printf("queue ! videoconvert ! %s",
                                video_sink ? video_sink : "autovideosink");
  GError *error = NULL;
  GstElement *sink = gst_parse_bin_from_description(desc, TRUE, &error);
  g_free(desc);
  if (sink == NULL) {
    fail("cannot play the %s: %s", audio ? "audio" : "video", error->message);
    g_error_free(error);
    return;
  }
  gst_bin_add(GST_BIN(pipeline), sink);
  gst_element_sync_state_with_parent(sink);
  GstPad *sinkpad = gst_element_get_static_pad(sink, "sink");
  gst_pad_link(pad, sinkpad);
  gst_object_unref(sinkpad);
  send_value("media", "media", audio ? "audio" : "video");
}

/* A stream of the peer (RTP): decoded */
static void on_incoming(GstElement *webrtc, GstPad *pad, gpointer user_data) {
  if (GST_PAD_DIRECTION(pad) != GST_PAD_SRC)
    return;
  GstWebRTCRTPTransceiver *t = NULL;
  g_object_get(pad, "transceiver", &t, NULL);
  const char *media = (t != NULL) ? transceiver_media(t) : NULL;
  gst_clear_object(&t);
  const Direction d = (g_strcmp0(media, "audio") == 0) ? audio : video;
  if (media != NULL && d != RECEIVE && d != BOTH) {
    // a media not received (the peer sends it anyway): discarded
    GstElement *sink = gst_element_factory_make("fakesink", NULL);
    gst_bin_add(GST_BIN(pipeline), sink);
    gst_element_sync_state_with_parent(sink);
    GstPad *sinkpad = gst_element_get_static_pad(sink, "sink");
    gst_pad_link(pad, sinkpad);
    gst_object_unref(sinkpad);
    return;
  }
  GstElement *decodebin = gst_element_factory_make("decodebin", NULL);
  g_signal_connect(decodebin, "pad-added", G_CALLBACK(on_decoded), NULL);
  gst_bin_add(GST_BIN(pipeline), decodebin);
  gst_element_sync_state_with_parent(decodebin);
  GstPad *sinkpad = gst_element_get_static_pad(decodebin, "sink");
  gst_pad_link(pad, sinkpad);
  gst_object_unref(sinkpad);
}

static void mute(const char *media, gboolean muted) {
  if (g_strcmp0(media, "audio") == 0 && sends(audio)) {
    GstElement *volume = gst_bin_get_by_name(GST_BIN(pipeline), "audio-mute");
    g_object_set(volume, "mute", muted, NULL);
    gst_object_unref(volume);
  } else if (g_strcmp0(media, "video") == 0 && sends(video)) {
    GstElement *valve = gst_bin_get_by_name(GST_BIN(pipeline), "video-mute");
    g_object_set(valve, "drop", muted, NULL);
    gst_object_unref(valve);
  }
}

static gboolean on_bus_message(GstBus *bus, GstMessage *msg,
                               gpointer user_data) {
  if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
    GError *error = NULL;
    gst_message_parse_error(msg, &error, NULL);
    fail("%s: %s", GST_OBJECT_NAME(msg->src), error->message);
    g_error_free(error);
  }
  return TRUE;
}

static gboolean sends(Direction d) { return d == SEND || d == BOTH; }

/* The media (`audio`, `video`) of a transceiver: marked when created, else its
 * kind (of a transceiver created for a media of the peer) */
static const char *transceiver_media(GstWebRTCRTPTransceiver *t) {
  const char *media = g_object_get_data(G_OBJECT(t), "media");
  if (media != NULL)
    return media;
  GstWebRTCKind kind;
  g_object_get(t, "kind", &kind, NULL);
  return kind == GST_WEBRTC_KIND_AUDIO   ? "audio"
         : kind == GST_WEBRTC_KIND_VIDEO ? "video"
                                         : NULL;
}

/* Marks the transceiver of a sink pad with the media of the linked branch */
static gboolean mark_transceiver(GstElement *element, GstPad *pad,
                                 gpointer data) {
  GstCaps *caps = gst_pad_peer_query_caps(pad, NULL);
  const char *media =
      gst_caps_is_empty(caps)
          ? NULL
          : gst_structure_get_string(gst_caps_get_structure(caps, 0), "media");
  GstWebRTCRTPTransceiver *t = NULL;
  g_object_get(pad, "transceiver", &t, NULL);
  if (t != NULL && media != NULL)
    g_object_set_data(G_OBJECT(t), "media",
                      g_strcmp0(media, "audio") == 0 ? "audio" : "video");
  gst_clear_object(&t);
  gst_caps_unref(caps);
  return TRUE;
}

/* A transceiver only receiving `media`, with the codec to offer */
static void add_transceiver(const char *media, const char *codec) {
  GstCaps *caps = gst_caps_from_string(codec);
  GstWebRTCRTPTransceiver *t = NULL;
  g_signal_emit_by_name(webrtc, "add-transceiver",
                        GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_RECVONLY, caps, &t);
  if (t != NULL)
    g_object_set_data(G_OBJECT(t), "media", (gpointer)media);
  gst_clear_object(&t);
  gst_caps_unref(caps);
}

/* Sets the direction of each transceiver from the options: before the offer,
 * and before the answer (also of transceivers created for the offer) */
static void set_directions(void) {
  GArray *transceivers = NULL;
  g_signal_emit_by_name(webrtc, "get-transceivers", &transceivers);
  for (guint i = 0; i < transceivers->len; i++) {
    GstWebRTCRTPTransceiver *t =
        g_array_index(transceivers, GstWebRTCRTPTransceiver *, i);
    const char *media = transceiver_media(t);
    if (media == NULL)
      continue;
    const Direction d = (strcmp(media, "audio") == 0) ? audio : video;
    const GstWebRTCRTPTransceiverDirection directions[] = {
        GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_INACTIVE,
        GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_SENDONLY,
        GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_RECVONLY,
        GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_SENDRECV};
    g_object_set(t, "direction", directions[d], NULL);
  }
  g_array_unref(transceivers);
}

/* Stops sending media which the negotiation doesn't allow to send (webrtcbin
 * would send it anyway), e.g. the peer only receives or declined video */
static void update_sending(void) {
  GArray *transceivers = NULL;
  g_signal_emit_by_name(webrtc, "get-transceivers", &transceivers);
  for (guint i = 0; i < transceivers->len; i++) {
    GstWebRTCRTPTransceiver *t =
        g_array_index(transceivers, GstWebRTCRTPTransceiver *, i);
    const char *media = transceiver_media(t);
    gchar *name = g_strdup_printf("%s-send", media ? media : "");
    GstElement *valve = gst_bin_get_by_name(GST_BIN(pipeline), name);
    g_free(name);
    if (valve == NULL)
      continue;
    GstWebRTCRTPTransceiverDirection d;
    g_object_get(t, "current-direction", &d, NULL);
    g_object_set(valve, "drop",
                 d != GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_SENDRECV &&
                     d != GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_SENDONLY,
                 NULL);
    gst_object_unref(valve);
  }
  g_array_unref(transceivers);
}

/* The pipeline: the own audio (and video) into webrtcbin, Opus (payload 111)
 * and VP8 (96) as browsers use them */
/* The audio source playing `audio_file`: at the speed it plays (a file is read
 * as fast as possible), its path quoted for the pipeline description */
static gchar *file_source(void) {
  GString *path = g_string_new(NULL);
  for (const char *c = audio_file; *c; c++) {
    if (*c == '"' || *c == '\\')
      g_string_append_c(path, '\\');
    g_string_append_c(path, *c);
  }
  gchar *source = g_strdup_printf("filesrc location=\"%s\" ! decodebin ! "
                                  "audioconvert ! identity sync=true",
                                  path->str);
  g_string_free(path, TRUE);
  return source;
}

static gboolean start(void) {
  if (audio == NONE && video == NONE) {
    fail("no media (--audio none without --video)");
    return FALSE;
  }
  gchar *file = (audio_file != NULL) ? file_source() : NULL;
  GString *desc =
      g_string_new(bundle ? "webrtcbin name=webrtc bundle-policy=max-bundle "
                          : "webrtcbin name=webrtc bundle-policy=none ");
  if (sends(audio))
    g_string_append_printf(
      desc,
      "%s ! queue ! audioconvert ! audioresample ! volume name=audio-mute ! "
      "valve name=audio-send ! opusenc ! rtpopuspay pt=111 "
      "! application/x-rtp,media=audio,encoding-name=OPUS,payload=111,encoding-params=(string)2 ! "
      "webrtc. ",
      file           ? file
      : test         ? "audiotestsrc is-live=true wave=sine volume=0.2"
      : audio_source ? audio_source
                     : "autoaudiosrc");
  g_free(file);
  if (sends(video))
    g_string_append_printf(
        desc,
        "%s ! queue ! videoconvert ! valve name=video-mute ! valve name=video-send ! "
        "vp8enc deadline=1 "
        "keyframe-max-dist=60 ! rtpvp8pay pt=96 "
        "! application/x-rtp,media=video,encoding-name=VP8,payload=96 ! "
        "webrtc. ",
        test ? "videotestsrc is-live=true pattern=ball ! "
               "video/x-raw,width=320,height=240"
        : video_source ? video_source
                       : "autovideosrc");
  GError *error = NULL;
  GstElement *parsed = gst_parse_launch(desc->str, &error);
  g_string_free(desc, TRUE);
  // also an error for a missing element, with a pipeline without it
  if (error != NULL) {
    fail("cannot create the media: %s", error->message);
    g_error_free(error);
    gst_clear_object(&parsed);
    return FALSE;
  }
  // only webrtcbin (nothing sent) is no pipeline
  if (GST_IS_PIPELINE(parsed))
    pipeline = parsed;
  else {
    pipeline = gst_pipeline_new(NULL);
    gst_bin_add(GST_BIN(pipeline), parsed);
  }
  webrtc = gst_bin_get_by_name(GST_BIN(pipeline), "webrtc");
  if (stun != NULL)
    g_object_set(webrtc, "stun-server", stun, NULL);
  for (gchar **t = turn; t != NULL && *t != NULL; t++) {
    gboolean added = FALSE;
    g_signal_emit_by_name(webrtc, "add-turn-server", *t, &added);
    if (!added)
      g_printerr("norc-rtc: invalid TURN server: %s\n", *t);
  }
  g_signal_connect(webrtc, "on-ice-candidate", G_CALLBACK(on_ice_candidate),
                   NULL);
  g_signal_connect(webrtc, "notify::ice-gathering-state",
                   G_CALLBACK(on_gathering_state), NULL);
  g_signal_connect(webrtc, "notify::connection-state",
                   G_CALLBACK(on_connection_state), NULL);
  g_signal_connect(webrtc, "pad-added", G_CALLBACK(on_incoming), NULL);
  // the media of the transceivers of the sent media, and those only receiving
  gst_element_foreach_sink_pad(webrtc, mark_transceiver, NULL);
  if (audio == RECEIVE)
    add_transceiver("audio", "application/x-rtp,media=audio,encoding-name=OPUS,"
                             "payload=111,clock-rate=48000,encoding-params=(string)2");
  if (video == RECEIVE)
    add_transceiver("video", "application/x-rtp,media=video,encoding-name=VP8,"
                             "payload=96,clock-rate=90000");
  set_directions();
  GstBus *bus = gst_pipeline_get_bus(GST_PIPELINE(pipeline));
  gst_bus_add_watch(bus, on_bus_message, NULL);
  gst_object_unref(bus);
  if (gst_element_set_state(pipeline, GST_STATE_PLAYING) ==
      GST_STATE_CHANGE_FAILURE) {
    fail("cannot start the media (audio or video device?)");
    return FALSE;
  }
  write_message(message("ready"));
  return TRUE;
}

/* --- Input
 * ---------------------------------------------------------------------------------------------------
 */

/* A line of input (on the main loop) */
static gboolean handle(gpointer data) {
  gchar *line = data;
  JsonParser *parser = json_parser_new();
  JsonObject *msg = NULL;
  if (json_parser_load_from_data(parser, line, -1, NULL) &&
      JSON_NODE_HOLDS_OBJECT(json_parser_get_root(parser)))
    msg = json_node_get_object(json_parser_get_root(parser));
  const char *type =
      msg ? json_object_get_string_member_with_default(msg, "type", "") : NULL;
  if (type == NULL)
    g_printerr("norc-rtc: invalid input: %s\n", line);
  else if (strcmp(type, "offer") == 0)
    create("offer");
  else if (strcmp(type, "sdp") == 0)
    set_remote(
        json_object_get_string_member_with_default(msg, "sdp_type", NULL),
        json_object_get_string_member_with_default(msg, "sdp", NULL));
  else if (strcmp(type, "candidate") == 0)
    g_signal_emit_by_name(
        webrtc, "add-ice-candidate",
        (guint)json_object_get_int_member_with_default(msg, "mline", 0),
        json_object_get_string_member_with_default(msg, "candidate", ""));
  else if (strcmp(type, "mute") == 0)
    mute(json_object_get_string_member_with_default(msg, "media", ""),
         json_object_get_boolean_member_with_default(msg, "muted", TRUE));
  else if (strcmp(type, "hangup") == 0)
    g_main_loop_quit(loop);
  else
    g_printerr("norc-rtc: unknown message: %s\n", type);
  g_object_unref(parser);
  g_free(line);
  return G_SOURCE_REMOVE;
}

static gboolean end_of_input(gpointer data) {
  g_main_loop_quit(loop);
  return G_SOURCE_REMOVE;
}

/*
        Reads stdin line by line, passing the lines to the main loop (portable,
   unlike watching stdin). Not with stdio: the lock of stdin, held while
   reading, would block the exit.
*/
static gpointer read_input(gpointer data) {
  GString *line = g_string_new(NULL);
  char buffer[4096];
  int n;
  while ((n = read(0, buffer, sizeof buffer)) > 0)
    for (int i = 0; i < n; i++) {
      if (buffer[i] != '\n') {
        g_string_append_c(line, buffer[i]);
        continue;
      }
      if (line->len > 0)
        g_main_context_invoke(NULL, handle, g_strdup(line->str));
      g_string_truncate(line, 0);
    }
  g_string_free(line, TRUE);
  g_main_context_invoke(NULL, end_of_input, NULL);
  return NULL;
}

int main(int argc, char *argv[]) {
  GOptionContext *context =
      g_option_context_new("- the media of a norc call, controlled with JSON "
                           "lines (see protocol.md)");
  g_option_context_add_main_entries(context, options, NULL);
  g_option_context_add_group(context, gst_init_get_option_group());
  GError *error = NULL;
  if (!g_option_context_parse(context, &argc, &argv, &error)) {
    g_printerr("norc-rtc: %s\n", error->message);
    return 2;
  }
  g_option_context_free(context);
  loop = g_main_loop_new(NULL, FALSE);
  if (start()) {
    g_thread_unref(g_thread_new("input", read_input, NULL));
    g_main_loop_run(loop);
  }
  if (pipeline != NULL) {
    gst_element_set_state(pipeline, GST_STATE_NULL);
    send_value("state", "state", "closed");
    gst_clear_object(&webrtc);
    gst_object_unref(pipeline);
  }
  g_main_loop_unref(loop);
  return exit_code;
}

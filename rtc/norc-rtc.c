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
#include <signal.h>
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
static gboolean test = FALSE, bundle = TRUE, echo_cancel = FALSE,
                list_devices = FALSE;
static gchar *microphone = NULL, *speaker = NULL, *camera = NULL,
             *video_size = NULL;
static gint video_fps = 0, video_bitrate = 0, audio_bitrate = 0;
static gchar *record_option = NULL;

static gboolean sends(Direction d);
static GstElement *device_element(const char *klass, const char *name,
                                  const char *what);
static void set_directions(void);
static void update_sending(void);
static const char *transceiver_media(GstWebRTCRTPTransceiver *t);
static gchar *stun = NULL, **turn = NULL;
static gchar *audio_source = NULL, *audio_sink = NULL, *video_source = NULL,
             *video_sink = NULL, *audio_file = NULL;
static void request_recording(const char *path);
static void stop_recording(const char *error);
static GstPad *tap(const char *name, GstPad *pad);
static gboolean on_connected(gpointer data);
static gboolean on_late_audio(gpointer data);

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
    {"file", 0, 0, G_OPTION_ARG_FILENAME, &audio_file,
     "Play a file (any format GStreamer decodes, also a named pipe) instead of the microphone, and of the "
     "camera if it has video",
     "PATH"},
    {"audio-file", 0, G_OPTION_FLAG_HIDDEN, G_OPTION_ARG_FILENAME, &audio_file, "Same as --file", "PATH"},
    {"audio-sink", 0, 0, G_OPTION_ARG_STRING, &audio_sink,
     "Audio sink (default autoaudiosink)", "PIPELINE"},
    {"video-source", 0, 0, G_OPTION_ARG_STRING, &video_source,
     "Video source (default autovideosrc)", "PIPELINE"},
    {"video-sink", 0, 0, G_OPTION_ARG_STRING, &video_sink,
     "Video sink (default autovideosink)", "PIPELINE"},
    {"microphone", 0, 0, G_OPTION_ARG_STRING, &microphone,
     "Microphone: its name or a part of it (see --list-devices)", "NAME"},
    {"speaker", 0, 0, G_OPTION_ARG_STRING, &speaker,
     "Speaker: its name or a part of it", "NAME"},
    {"camera", 0, 0, G_OPTION_ARG_STRING, &camera,
     "Camera: its name or a part of it", "NAME"},
    {"list-devices", 0, 0, G_OPTION_ARG_NONE, &list_devices,
     "List the microphones, speakers and cameras, then exit", NULL},
    {"video-size", 0, 0, G_OPTION_ARG_STRING, &video_size,
     "Size of the sent video, e.g. 1280x720 (default: of the camera)", "WxH"},
    {"video-fps", 0, 0, G_OPTION_ARG_INT, &video_fps,
     "Frames per second of the sent video (default: of the camera)", "N"},
    {"video-bitrate", 0, 0, G_OPTION_ARG_INT, &video_bitrate,
     "Bitrate of the sent video in kbit/s (default: VP8's 256)", "KBPS"},
    {"audio-bitrate", 0, 0, G_OPTION_ARG_INT, &audio_bitrate,
     "Bitrate of the sent audio in kbit/s (default: Opus' choice)", "KBPS"},
    {"echo-cancel", 0, 0, G_OPTION_ARG_NONE, &echo_cancel,
     "Echo cancellation and noise suppression of the microphone", NULL},
    {"no-bundle", 0, G_OPTION_FLAG_REVERSE, G_OPTION_ARG_NONE, &bundle,
     "A connection for each media (the peer doesn't support BUNDLE)", NULL},
    {"test", 0, 0, G_OPTION_ARG_NONE, &test,
     "Test signals as sources, discard received media", NULL},
    {"record", 0, 0, G_OPTION_ARG_FILENAME, &record_option,
     "Record the call into a file (WebM) once connected", "PATH"},
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
  if (state == GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTED)
    g_main_context_invoke(NULL, on_connected, NULL);
}

/* --- Media
 * ---------------------------------------------------------------------------------------------------
 */

/* A decoded stream of the peer: played (or discarded with --test) */
static void on_decoded(GstElement *decodebin, GstPad *pad, gpointer user_data) {
  GstCaps *caps = gst_pad_get_current_caps(pad);
  const GstStructure *s = gst_caps_get_structure(caps, 0);
  const char *name = gst_structure_get_name(s);
  const gboolean audio = g_str_has_prefix(name, "audio/");
  int width = 0, height = 0;
  gst_structure_get_int(s, "width", &width);
  gst_structure_get_int(s, "height", &height);
  gst_caps_unref(caps);
  if (!audio && !g_str_has_prefix(name, "video/"))
    return;
  // the audio to the echo probe (played after it), or to the speaker device
  GstElement *probe =
      audio ? gst_bin_get_by_name(GST_BIN(pipeline), "echo-probe") : NULL;
  GstPad *probe_pad =
      (probe != NULL) ? gst_element_get_static_pad(probe, "sink") : NULL;
  const gboolean to_probe = probe_pad != NULL && !gst_pad_is_linked(probe_pad);
  const gboolean to_device = audio && !to_probe && speaker != NULL && !test;
  gchar *desc =
      (to_probe || to_device) ? g_strdup("queue ! audioconvert ! audioresample")
      : test                  ? g_strdup("queue ! fakesink")
      : audio ? g_strdup_printf("queue ! audioconvert ! audioresample ! %s",
                                audio_sink ? audio_sink : "autoaudiosink")
              : g_strdup_printf("queue ! videoconvert ! %s",
                                video_sink ? video_sink : "autovideosink");
  GError *error = NULL;
  GstElement *sink = gst_parse_bin_from_description(desc, TRUE, &error);
  g_free(desc);
  GstElement *device =
      (sink != NULL && to_device) ? device_element("Audio/Sink", speaker, "speaker") : NULL;
  if (sink == NULL || (to_device && device == NULL)) {
    if (error != NULL) {
      fail("cannot play the %s: %s", audio ? "audio" : "video", error->message);
      g_error_free(error);
    }
    gst_clear_object(&probe_pad);
    gst_clear_object(&probe);
    return;
  }
  gst_bin_add(GST_BIN(pipeline), sink);
  if (device != NULL) {
    gst_bin_add(GST_BIN(pipeline), device);
    gst_element_link(sink, device);
    gst_element_sync_state_with_parent(device);
  }
  if (to_probe) {
    GstPad *src = gst_element_get_static_pad(sink, "src");
    gst_pad_link(src, probe_pad);
    gst_object_unref(src);
  }
  gst_element_sync_state_with_parent(sink);
  GstPad *sinkpad = gst_element_get_static_pad(sink, "sink");
  // the audio through a tap for recordings, maybe one already running
  GstPad *from = audio ? tap("tap-peer-audio", pad) : gst_object_ref(pad);
  gst_pad_link(from, sinkpad);
  gst_object_unref(from);
  gst_object_unref(sinkpad);
  if (audio)
    g_main_context_invoke(NULL, on_late_audio, NULL);
  gst_clear_object(&probe_pad);
  gst_clear_object(&probe);
  JsonBuilder *b = message("media");
  member(b, "media", audio ? "audio" : "video");
  if (!audio && width > 0) {
    json_builder_set_member_name(b, "width");
    json_builder_add_int_value(b, width);
    json_builder_set_member_name(b, "height");
    json_builder_add_int_value(b, height);
  }
  write_message(b);
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
  // the video as received (RTP) through a tap for recordings, the audio is tapped decoded
  GstPad *from = (g_strcmp0(media, "video") == 0) ? tap("tap-peer-video", pad) : gst_object_ref(pad);
  gst_pad_link(from, sinkpad);
  gst_object_unref(from);
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

/* Reports the error message `msg` of the pipeline: the element and the error, with a hint for a device in use */
static void fail_with(GstMessage *msg) {
  GError *error = NULL;
  gst_message_parse_error(msg, &error, NULL);
  // PipeWire reports a device in use as a stream error with EBUSY
  const gboolean busy = (error->domain == GST_RESOURCE_ERROR && error->code == GST_RESOURCE_ERROR_BUSY) ||
                        strstr(error->message, "busy") != NULL;
  fail("%s: %s%s", GST_OBJECT_NAME(msg->src), error->message,
       busy ? " (the device is used by another program? a PipeWire source, e.g. pipewiresrc, can be shared)" : "");
  g_error_free(error);
}

static gboolean on_bus_message(GstBus *bus, GstMessage *msg,
                               gpointer user_data) {
  if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR)
    fail_with(msg);
  return TRUE;
}

/* The recording, see below */
static GstElement *recorder = NULL;
static GMutex record_lock;
static gint record_closing = 0;
static gboolean on_record_error(gpointer data);

/* An error of the recording (in the thread of the element): its taps drop the streams at once (an error flowing
 * back would stop them), it is stopped on the main loop; the call goes on */
static GstBusSyncReply on_bus_sync(GstBus *bus, GstMessage *msg, gpointer user_data) {
  if (GST_MESSAGE_TYPE(msg) != GST_MESSAGE_ERROR)
    return GST_BUS_PASS;
  g_mutex_lock(&record_lock);
  const gboolean recording = recorder != NULL && gst_object_has_as_ancestor(GST_MESSAGE_SRC(msg), GST_OBJECT(recorder));
  g_mutex_unlock(&record_lock);
  if (!recording)
    return GST_BUS_PASS;
  g_atomic_int_set(&record_closing, 1);
  GError *error = NULL;
  gst_message_parse_error(msg, &error, NULL);
  g_main_context_invoke(NULL, on_record_error, g_strdup_printf("%s: %s", GST_OBJECT_NAME(GST_MESSAGE_SRC(msg)), error->message));
  g_error_free(error);
  return GST_BUS_DROP;
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

/* --- Devices
 * ------------------------------------------------------------------------------------------------- */

/* The device of `klass` (e.g. Audio/Source): its name contains `name` (case
 * insensitive), or a property is `name` (e.g. node.name, a device path) */
static GstDevice *find_device(const char *klass, const char *name) {
  GstDeviceMonitor *monitor = gst_device_monitor_new();
  gst_device_monitor_add_filter(monitor, klass, NULL);
  GList *devices = gst_device_monitor_get_devices(monitor);
  gchar *wanted = g_utf8_casefold(name, -1);
  GstDevice *found = NULL;
  for (GList *d = devices; d != NULL && found == NULL; d = d->next) {
    GstDevice *device = d->data;
    gchar *display = gst_device_get_display_name(device);
    gchar *folded = g_utf8_casefold(display, -1);
    gboolean match = strstr(folded, wanted) != NULL;
    GstStructure *props = gst_device_get_properties(device);
    for (int i = 0; props != NULL && !match && i < gst_structure_n_fields(props); i++) {
      const gchar *value = gst_structure_get_string(props, gst_structure_nth_field_name(props, i));
      match = g_strcmp0(value, name) == 0;
    }
    if (props != NULL)
      gst_structure_free(props);
    if (match)
      found = gst_object_ref(device);
    g_free(folded);
    g_free(display);
  }
  g_list_free_full(devices, gst_object_unref);
  gst_object_unref(monitor);
  g_free(wanted);
  return found;
}

/* An element of the device `name` of `klass`, else NULL after an error */
static GstElement *device_element(const char *klass, const char *name,
                                  const char *what) {
  GstDevice *device = find_device(klass, name);
  if (device == NULL) {
    fail("no %s %s (norc-rtc --list-devices)", what, name);
    return NULL;
  }
  GstElement *element = gst_device_create_element(device, NULL);
  gst_object_unref(device);
  if (element == NULL)
    fail("cannot use the %s %s", what, name);
  return element;
}

/* Links the device `name` to (a source) or from (a sink) the element `slot` of
 * the pipeline, if it exists */
static gboolean link_device(const char *slot, gboolean source,
                            const char *klass, const char *name,
                            const char *what) {
  GstElement *element = gst_bin_get_by_name(GST_BIN(pipeline), slot);
  if (element == NULL)
    return TRUE;
  GstElement *device = device_element(klass, name, what);
  gboolean ok = device != NULL;
  if (ok) {
    gst_bin_add(GST_BIN(GST_ELEMENT_PARENT(element)), device);
    ok = source ? gst_element_link(device, element)
                : gst_element_link(element, device);
    if (!ok)
      fail("cannot use the %s %s", what, name);
  }
  gst_object_unref(element);
  return ok;
}

static void print_devices(void) {
  const char *kinds[][2] = {{"Audio/Source", "microphone"},
                            {"Audio/Sink", "speaker"},
                            {"Video/Source", "camera"}};
  for (int k = 0; k < 3; k++) {
    GstDeviceMonitor *monitor = gst_device_monitor_new();
    gst_device_monitor_add_filter(monitor, kinds[k][0], NULL);
    GList *devices = gst_device_monitor_get_devices(monitor);
    // the same devices of several providers (PipeWire, PulseAudio, ALSA) once
    GHashTable *seen = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    for (GList *d = devices; d != NULL; d = d->next) {
      gchar *name = gst_device_get_display_name(d->data);
      if (g_hash_table_add(seen, name))
        g_print("%-11s %s\n", kinds[k][1], name);
    }
    g_hash_table_destroy(seen);
    g_list_free_full(devices, gst_object_unref);
    gst_object_unref(monitor);
  }
}

/* The pipeline: the own audio (and video) into webrtcbin, Opus (payload 111)
 * and VP8 (96) as browsers use them */
/* The source of `slot` (file-audio, file-video) without media of the file: the microphone or camera */
static void file_fallback(const char *slot) {
  GstElement *element = gst_bin_get_by_name(GST_BIN(pipeline), slot);
  if (element == NULL)
    return;
  GstPad *sinkpad = gst_element_get_static_pad(element, "sink");
  const gboolean linked = gst_pad_is_linked(sinkpad);
  gst_object_unref(sinkpad);
  if (linked) {
    gst_object_unref(element);
    return;
  }
  const gboolean is_audio = g_str_equal(slot, "file-audio");
  const char *device = is_audio ? microphone : camera;
  GstElement *source = NULL;
  if (device != NULL && !test)
    source = device_element(is_audio ? "Audio/Source" : "Video/Source", device, is_audio ? "microphone" : "camera");
  else {
    const char *desc = is_audio ? (test ? "audiotestsrc is-live=true wave=sine volume=0.2"
                                        : audio_source ? audio_source : "autoaudiosrc")
                                : (test ? "videotestsrc is-live=true pattern=ball ! video/x-raw,width=320,height=240"
                                        : video_source ? video_source : "autovideosrc");
    GError *error = NULL;
    // a bin can't end in caps (video/x-raw,…)
    gchar *bin = g_strdup_printf("%s ! identity", desc);
    source = gst_parse_bin_from_description(bin, TRUE, &error);
    g_free(bin);
    if (error != NULL) {
      fail("cannot create the %s: %s", is_audio ? "audio source" : "video source", error->message);
      g_error_free(error);
      gst_clear_object(&source);
    }
  }
  if (source != NULL) {
    gst_bin_add(GST_BIN(pipeline), source);
    if (gst_element_link(source, element))
      gst_element_sync_state_with_parent(source);
    else
      fail("cannot use the %s", is_audio ? "microphone" : "camera");
  }
  gst_object_unref(element);
}

/* All streams of the file decoded: the media sent and not in the file from the microphone or camera */
static gboolean on_file_complete(gpointer user_data) {
  file_fallback("file-audio");
  file_fallback("file-video");
  write_message(message("ready"));
  return G_SOURCE_REMOVE;
}

static void on_file_pads(GstElement *decodebin, gpointer user_data) {
  g_main_context_invoke(NULL, on_file_complete, NULL);
}

/* A decoded stream of the file: to the sent audio or video, else discarded (e.g. a second audio track) */
static void on_file_decoded(GstElement *decodebin, GstPad *pad, gpointer user_data) {
  GstCaps *caps = gst_pad_get_current_caps(pad);
  if (caps == NULL)
    caps = gst_pad_query_caps(pad, NULL);
  const char *name = gst_structure_get_name(gst_caps_get_structure(caps, 0));
  const char *slot = g_str_has_prefix(name, "audio/") ? "file-audio" : g_str_has_prefix(name, "video/") ? "file-video" : NULL;
  gst_caps_unref(caps);
  GstElement *element = (slot != NULL) ? gst_bin_get_by_name(GST_BIN(pipeline), slot) : NULL;
  GstPad *sinkpad = (element != NULL) ? gst_element_get_static_pad(element, "sink") : NULL;
  if (sinkpad != NULL && !gst_pad_is_linked(sinkpad) && gst_pad_link(pad, sinkpad) == GST_PAD_LINK_OK) {
    gst_object_unref(sinkpad);
    gst_object_unref(element);
    return;
  }
  gst_clear_object(&sinkpad);
  gst_clear_object(&element);
  GstElement *sink = gst_element_factory_make("fakesink", NULL);
  gst_bin_add(GST_BIN(pipeline), sink);
  gst_element_sync_state_with_parent(sink);
  GstPad *fake = gst_element_get_static_pad(sink, "sink");
  gst_pad_link(pad, fake);
  gst_object_unref(fake);
}

/* The file `audio_file` decoded into the sent audio and video (`file-audio`, `file-video` of the pipeline) */
static void add_file(void) {
  GstElement *src = gst_element_factory_make("filesrc", NULL);
  GstElement *decodebin = gst_element_factory_make("decodebin", NULL);
  g_object_set(src, "location", audio_file, NULL);
  g_signal_connect(decodebin, "pad-added", G_CALLBACK(on_file_decoded), NULL);
  g_signal_connect(decodebin, "no-more-pads", G_CALLBACK(on_file_pads), NULL);
  gst_bin_add_many(GST_BIN(pipeline), src, decodebin, NULL);
  gst_element_link(src, decodebin);
}

/* GStreamer has the element `name` */
static gboolean has_element(const char *name) {
  GstElementFactory *factory = gst_element_factory_find(name);
  if (factory == NULL)
    return FALSE;
  gst_object_unref(factory);
  return TRUE;
}

static gboolean start(void) {
  if (audio == NONE && video == NONE) {
    fail("no media (--audio none without --video)");
    return FALSE;
  }
  // a file: decoded into these (add_file), at the speed it plays (a file is read as fast as possible)
  const char *file_audio = audio_file ? "identity name=file-audio ! audioconvert ! identity sync=true" : NULL;
  const char *file_video = audio_file ? "identity name=file-video ! videoconvert ! identity sync=true" : NULL;
  // echo cancellation: of the sent audio, with the received audio played; without it if GStreamer has no webrtcdsp
  // (gst-plugins-bad built without webrtc-audio-processing, e.g. on macOS)
  if (echo_cancel && sends(audio) && !has_element("webrtcdsp")) {
    g_printerr("norc-rtc: no echo cancellation: GStreamer has no webrtcdsp (call_echo_cancel = 0 hides this)\n");
    echo_cancel = FALSE;
  }
  const gboolean echo = echo_cancel && sends(audio) && (audio == BOTH) && has_element("webrtcechoprobe");
  gchar *dsp = (echo_cancel && sends(audio))
                   ? g_strdup_printf("webrtcdsp probe=echo-probe echo-cancel=%s ! "
                                     "audioconvert ! ",
                                     echo ? "true" : "false")
                   : NULL;
  gchar *opus = (audio_bitrate > 0) ? g_strdup_printf("bitrate=%d", audio_bitrate * 1000) : g_strdup("");
  // the size and rate of the sent video, and its bitrate
  int width = 0, height = 0;
  if (video_size != NULL && (sscanf(video_size, "%dx%d", &width, &height) != 2 || width <= 0 || height <= 0)) {
    fail("invalid video size: %s (e.g. 1280x720)", video_size);
    g_free(opus);
    g_free(dsp);
    return FALSE;
  }
  GString *scale = g_string_new("");
  if (width > 0 || video_fps > 0) {
    g_string_append(scale, (width > 0) ? "videoscale ! " : "");
    g_string_append(scale, (video_fps > 0) ? "videorate ! " : "");
    g_string_append(scale, "video/x-raw");
    if (width > 0)
      g_string_append_printf(scale, ",width=%d,height=%d", width, height);
    if (video_fps > 0)
      g_string_append_printf(scale, ",framerate=%d/1", video_fps);
    g_string_append(scale, " ! ");
  }
  gchar *vp8 = (video_bitrate > 0) ? g_strdup_printf("target-bitrate=%d", video_bitrate * 1000) : g_strdup("");
  GString *desc =
      g_string_new(bundle ? "webrtcbin name=webrtc bundle-policy=max-bundle "
                          : "webrtcbin name=webrtc bundle-policy=none ");
  if (sends(audio))
    g_string_append_printf(
      desc,
      "%s ! queue ! audioconvert ! audioresample ! %s volume name=audio-mute ! "
      "valve name=audio-send ! tee name=tap-own-audio allow-not-linked=true ! opusenc %s ! rtpopuspay pt=111 "
      "! application/x-rtp,media=audio,encoding-name=OPUS,payload=111,encoding-params=(string)2 ! "
      "webrtc. ",
      file_audio     ? file_audio
      : test         ? "audiotestsrc is-live=true wave=sine volume=0.2"
      : microphone   ? "identity name=microphone"
      : audio_source ? audio_source
                     : "autoaudiosrc",
      dsp ? dsp : "", opus);
  g_free(opus);
  g_free(dsp);
  // the played audio for the echo cancellation, the received audio is linked to it
  if (echo)
    g_string_append_printf(
        desc, "webrtcechoprobe name=echo-probe ! audioconvert ! audioresample ! %s ",
        test        ? "fakesink"
        : speaker   ? "identity name=speaker"
        : audio_sink ? audio_sink
                     : "autoaudiosink");
  if (sends(video))
    g_string_append_printf(
        desc,
        "%s ! queue ! videoconvert ! %svalve name=video-mute ! valve name=video-send ! "
        "vp8enc deadline=1 %s "
        "keyframe-max-dist=60 ! tee name=tap-own-video allow-not-linked=true ! rtpvp8pay pt=96 "
        "! application/x-rtp,media=video,encoding-name=VP8,payload=96 ! "
        "webrtc. ",
        file_video ? file_video
        : test ? "videotestsrc is-live=true pattern=ball ! "
               "video/x-raw,width=320,height=240"
        : camera       ? "identity name=camera"
        : video_source ? video_source
                       : "autovideosrc",
        scale->str, vp8);
  g_string_free(scale, TRUE);
  g_free(vp8);
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
  if (audio_file != NULL)
    add_file();
  if (!test &&
      !((microphone == NULL ||
         link_device("microphone", TRUE, "Audio/Source", microphone, "microphone")) &&
        (camera == NULL || link_device("camera", TRUE, "Video/Source", camera, "camera")) &&
        (speaker == NULL || link_device("speaker", FALSE, "Audio/Sink", speaker, "speaker"))))
    return FALSE;
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
  gst_bus_set_sync_handler(bus, on_bus_sync, NULL, NULL);
  gst_bus_add_watch(bus, on_bus_message, NULL);
  gst_object_unref(bus);
  if (gst_element_set_state(pipeline, GST_STATE_PLAYING) ==
      GST_STATE_CHANGE_FAILURE) {
    // the error of the element failing, posted before the bus watch runs
    GstBus *errors = gst_pipeline_get_bus(GST_PIPELINE(pipeline));
    GstMessage *msg = gst_bus_pop_filtered(errors, GST_MESSAGE_ERROR);
    gst_object_unref(errors);
    if (msg != NULL) {
      fail_with(msg);
      gst_message_unref(msg);
    } else
      fail("cannot start the media (audio or video device?)");
    return FALSE;
  }
  // with a file: once its streams are linked (on_file_complete), the offer describes them
  if (audio_file == NULL)
    write_message(message("ready"));
  if (record_option != NULL)
    request_recording(record_option);
  return TRUE;
}


/* --- Recording
 * ------------------------------------------------------------------------------------------------
 * The streams are tapped with tees: the own audio before encoding (tap-own-audio), the own video after it
 * (tap-own-video, VP8), the audio of the peer decoded (tap-peer-audio), its video as received (tap-peer-video, RTP).
 * A recording is a bin linked to the taps flowing when it starts, a moment after the connection (the streams of the
 * peer start): both voices mixed into one Opus track (players play one audio track), the videos as they are (the
 * peer's first, players show the first), in WebM. Videos can't be added later (the header of the file is written),
 * voices can (to the mixer). It is stopped with an EOS through its own elements: the file gets its index.
 */

/* Seconds after the connection until a recording starts, for the streams of the peer to start */
#define RECORD_DELAY 2

/* Seconds to wait for a stopped recording to be written */
#define RECORD_STOP_TIMEOUT 3

typedef struct {
  GstElement *tee;
  GstPad *tap;   /* the request pad of the tee */
  GstPad *input; /* the ghost pad of the recorder */
} Branch;

static GstElement *mixer = NULL, *muxer = NULL;
static GPtrArray *branches = NULL;
static gchar *record_path = NULL, *record_error = NULL;
static gboolean record_stopping = FALSE, quit_after_recording = FALSE;
static gint64 connected_at = 0;
static guint record_timer = 0;

/* The own message of the recording: `started` (with its tracks), `stopped`, `failed` (with the message) */
static void send_recording(const char *state, const char *error, GPtrArray *tracks) {
  JsonBuilder *b = message("recording");
  member(b, "state", state);
  if (record_path != NULL)
    member(b, "file", record_path);
  if (error != NULL)
    member(b, "message", error);
  if (tracks != NULL) {
    json_builder_set_member_name(b, "tracks");
    json_builder_begin_array(b);
    for (guint i = 0; i < tracks->len; i++)
      json_builder_add_string_value(b, g_ptr_array_index(tracks, i));
    json_builder_end_array(b);
  }
  write_message(b);
}

/* A tee tapping the stream of `pad` for recordings: returns its pad to link the stream on. The first of `name`
 * (later ones, e.g. after a renegotiation, are not recorded) */
static GstPad *tap(const char *name, GstPad *pad) {
  GstElement *existing = gst_bin_get_by_name(GST_BIN(pipeline), name);
  GstElement *tee = gst_element_factory_make("tee", existing == NULL ? name : NULL);
  gst_clear_object(&existing);
  g_object_set(tee, "allow-not-linked", TRUE, NULL);
  gst_bin_add(GST_BIN(pipeline), tee);
  gst_element_sync_state_with_parent(tee);
  GstPad *sink = gst_element_get_static_pad(tee, "sink");
  gst_pad_link(pad, sink);
  gst_object_unref(sink);
  return gst_element_request_pad_simple(tee, "src_%u");
}

/* The tap `name` if its stream flows (its caps are known), with its caps (`caps` may be NULL) */
static GstElement *flowing(const char *name, GstCaps **caps) {
  GstElement *tee = gst_bin_get_by_name(GST_BIN(pipeline), name);
  if (tee == NULL)
    return NULL;
  GstPad *sink = gst_element_get_static_pad(tee, "sink");
  GstCaps *current = gst_pad_get_current_caps(sink);
  gst_object_unref(sink);
  if (current == NULL) {
    gst_object_unref(tee);
    return NULL;
  }
  if (caps != NULL)
    *caps = current;
  else
    gst_caps_unref(current);
  return tee;
}

/* Drops the buffers of a tap while the recording closes (or failed): nothing flows back to the call */
static GstPadProbeReturn guard(GstPad *pad, GstPadProbeInfo *info, gpointer data) {
  return g_atomic_int_get(&record_closing) ? GST_PAD_PROBE_DROP : GST_PAD_PROBE_OK;
}

/* Drops the video until a keyframe: a recording starts with one */
static GstPadProbeReturn until_keyframe(GstPad *pad, GstPadProbeInfo *info, gpointer data) {
  GstBuffer *buffer = GST_PAD_PROBE_INFO_BUFFER(info);
  if (GST_BUFFER_FLAG_IS_SET(buffer, GST_BUFFER_FLAG_DELTA_UNIT))
    return GST_PAD_PROBE_DROP;
  return GST_PAD_PROBE_REMOVE;
}

/* Links the tap `tee` to a new branch of the recorder, the elements `desc` ending at `dest` (a pad of the mixer or
 * the muxer); returns the pad leaving the branch (unref), NULL after an error */
static GstPad *add_branch(GstElement *tee, const char *desc, GstPad *dest) {
  GError *error = NULL;
  GstElement *bin = gst_parse_bin_from_description(desc, TRUE, &error);
  if (bin == NULL) {
    g_printerr("norc-rtc: cannot record: %s\n", error->message);
    g_error_free(error);
    return NULL;
  }
  gst_bin_add(GST_BIN(recorder), bin);
  GstPad *src = gst_element_get_static_pad(bin, "src");
  if (gst_pad_link(src, dest) != GST_PAD_LINK_OK) {
    g_printerr("norc-rtc: cannot record: the branch %s can't be linked\n", desc);
    gst_object_unref(src);
    gst_bin_remove(GST_BIN(recorder), bin);
    return NULL;
  }
  gst_element_sync_state_with_parent(bin);
  GstPad *sink = gst_element_get_static_pad(bin, "sink");
  GstPad *input = gst_ghost_pad_new(NULL, sink);
  gst_object_unref(sink);
  gst_pad_set_active(input, TRUE);
  gst_element_add_pad(recorder, input);
  GstPad *pad = gst_element_request_pad_simple(tee, "src_%u");
  gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER | GST_PAD_PROBE_TYPE_BUFFER_LIST, guard, NULL, NULL);
  gst_pad_link(pad, input);
  Branch *b = g_new(Branch, 1);
  b->tee = gst_object_ref(tee);
  b->tap = pad;
  b->input = input;
  g_ptr_array_add(branches, b);
  return src;
}

/* A voice into the mixer of the recording */
static gboolean add_voice(GstElement *tee) {
  GstPad *dest = gst_element_request_pad_simple(mixer, "sink_%u");
  GstPad *src = add_branch(tee, "queue ! audioconvert ! audioresample ! capsfilter caps=audio/x-raw,rate=48000,channels=2", dest);
  gst_object_unref(dest);
  if (src == NULL)
    return FALSE;
  gst_object_unref(src);
  return TRUE;
}

static gboolean has_branch(GstElement *tee) {
  for (guint i = 0; branches != NULL && i < branches->len; i++)
    if (((Branch *)g_ptr_array_index(branches, i))->tee == tee)
      return TRUE;
  return FALSE;
}

/* The audio of the peer started: into a running recording (with a mixer) */
static gboolean on_late_audio(gpointer data) {
  if (recorder == NULL || mixer == NULL || record_stopping)
    return G_SOURCE_REMOVE;
  GstElement *tee = flowing("tap-peer-audio", NULL);
  if (tee == NULL)
    tee = gst_bin_get_by_name(GST_BIN(pipeline), "tap-peer-audio");
  if (tee != NULL && !has_branch(tee))
    add_voice(tee);
  gst_clear_object(&tee);
  return G_SOURCE_REMOVE;
}

/* The recording was written (EOS at the file), or the time to wait for it is over */
static gboolean finish_recording(gpointer data) {
  if (GPOINTER_TO_INT(data) == 1)
    record_timer = 0;
  if (recorder == NULL || !record_stopping)
    return G_SOURCE_REMOVE;
  if (record_timer != 0) {
    g_source_remove(record_timer);
    record_timer = 0;
  }
  g_atomic_int_set(&record_closing, 1);
  for (guint i = 0; i < branches->len; i++) {
    Branch *b = g_ptr_array_index(branches, i);
    if (gst_pad_is_linked(b->tap))
      gst_pad_unlink(b->tap, b->input);
    gst_element_release_request_pad(b->tee, b->tap);
    gst_object_unref(b->tap);
    gst_object_unref(b->tee);
    g_free(b);
  }
  g_ptr_array_unref(branches);
  branches = NULL;
  g_mutex_lock(&record_lock);
  GstElement *r = recorder;
  recorder = NULL;
  g_mutex_unlock(&record_lock);
  gst_element_set_state(r, GST_STATE_NULL);
  gst_bin_remove(GST_BIN(pipeline), r);
  mixer = muxer = NULL;
  record_stopping = FALSE;
  send_recording(record_error != NULL ? "failed" : "stopped", record_error, NULL);
  g_clear_pointer(&record_path, g_free);
  g_clear_pointer(&record_error, g_free);
  if (quit_after_recording)
    g_main_loop_quit(loop);
  return G_SOURCE_REMOVE;
}

/* The end of the stream reached the file: written */
static GstPadProbeReturn on_written(GstPad *pad, GstPadProbeInfo *info, gpointer data) {
  if (GST_EVENT_TYPE(GST_PAD_PROBE_INFO_EVENT(info)) == GST_EVENT_EOS)
    g_main_context_invoke(NULL, finish_recording, NULL);
  return GST_PAD_PROBE_OK;
}

/* Stops the recording: the taps are unlinked, an EOS through the recorder writes the end of the file. `error`: it
 * failed */
static void stop_recording(const char *error) {
  if (recorder == NULL) {
    // not started yet
    if (record_path != NULL && error == NULL && !record_stopping) {
      if (record_timer != 0) {
        g_source_remove(record_timer);
        record_timer = 0;
      }
      g_clear_pointer(&record_path, g_free);
    }
    return;
  }
  if (record_stopping)
    return;
  record_stopping = TRUE;
  if (error != NULL)
    record_error = g_strdup(error);
  g_atomic_int_set(&record_closing, 1);
  for (guint i = 0; i < branches->len; i++) {
    Branch *b = g_ptr_array_index(branches, i);
    gst_pad_unlink(b->tap, b->input);
    gst_pad_send_event(b->input, gst_event_new_eos());
  }
  record_timer = g_timeout_add_seconds(RECORD_STOP_TIMEOUT, finish_recording, GINT_TO_POINTER(1));
}

static gboolean on_record_error(gpointer data) {
  gchar *text = data;
  stop_recording(text);
  g_free(text);
  return G_SOURCE_REMOVE;
}

/* Starts the requested recording with the streams flowing */
static gboolean begin_recording(gpointer data) {
  record_timer = 0;
  if (record_path == NULL || recorder != NULL)
    return G_SOURCE_REMOVE;
  GstCaps *caps = NULL;
  GstElement *own_audio = flowing("tap-own-audio", NULL), *peer_audio = flowing("tap-peer-audio", NULL),
             *peer_video = flowing("tap-peer-video", &caps), *own_video = flowing("tap-own-video", NULL);
  // the video of the peer: VP8, the only codec offered
  if (peer_video != NULL &&
      g_strcmp0(gst_structure_get_string(gst_caps_get_structure(caps, 0), "encoding-name"), "VP8") != 0)
    gst_clear_object(&peer_video);
  gst_clear_caps(&caps);
  if (own_audio == NULL && peer_audio == NULL && peer_video == NULL && own_video == NULL) {
    send_recording("failed", "nothing to record: no media flows", NULL);
    g_clear_pointer(&record_path, g_free);
    return G_SOURCE_REMOVE;
  }
  GstElement *r = gst_bin_new("recorder");
  muxer = gst_element_factory_make("webmmux", NULL);
  GstElement *file = gst_element_factory_make("filesink", NULL);
  g_object_set(muxer, "offset-to-zero", TRUE, NULL);
  g_object_set(file, "location", record_path, NULL);
  gst_bin_add_many(GST_BIN(r), muxer, file, NULL);
  gst_element_link(muxer, file);
  GstPad *written = gst_element_get_static_pad(file, "sink");
  gst_pad_add_probe(written, GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, on_written, NULL, NULL);
  gst_object_unref(written);
  branches = g_ptr_array_new();
  GPtrArray *tracks = g_ptr_array_new();
  g_atomic_int_set(&record_closing, 0);
  g_mutex_lock(&record_lock);
  recorder = r;
  g_mutex_unlock(&record_lock);
  gst_bin_add(GST_BIN(pipeline), r);
  // an error (e.g. the file can't be written) stops it at once, from this thread
  gboolean ok = gst_element_sync_state_with_parent(r) && !record_stopping;
  // the voices mixed, then the videos
  if (ok && (own_audio != NULL || peer_audio != NULL)) {
    // in the recorder itself: the voices are linked to the mixer (no ghost pads)
    mixer = gst_element_factory_make("audiomixer", NULL);
    GstElement *convert = gst_element_factory_make("audioconvert", NULL),
               *encode = gst_element_factory_make("opusenc", NULL), *queue = gst_element_factory_make("queue", NULL);
    // from the first voice (not with silence from the start of the call)
    g_object_set(mixer, "start-time-selection", 1, NULL);
    gst_bin_add_many(GST_BIN(r), mixer, convert, encode, queue, NULL);
    GstPad *src = gst_element_get_static_pad(queue, "src");
    GstPad *dest = gst_element_request_pad_simple(muxer, "audio_%u");
    ok = gst_element_link_many(mixer, convert, encode, queue, NULL) && gst_pad_link(src, dest) == GST_PAD_LINK_OK;
    gst_object_unref(src);
    gst_object_unref(dest);
    for (GstElement **e = (GstElement *[]){queue, encode, convert, mixer, NULL}; ok && *e != NULL; e++)
      gst_element_sync_state_with_parent(*e);
    if (ok && (own_audio == NULL || add_voice(own_audio)) && (peer_audio == NULL || add_voice(peer_audio)))
      g_ptr_array_add(tracks, "audio");
  }
  if (ok && peer_video != NULL) {
    GstPad *dest = gst_element_request_pad_simple(muxer, "video_%u");
    GstPad *src = add_branch(peer_video, "queue ! rtpvp8depay wait-for-keyframe=true request-keyframe=true", dest);
    gst_object_unref(dest);
    if (src != NULL)
      g_ptr_array_add(tracks, "video");
    gst_clear_object(&src);
  }
  if (ok && own_video != NULL) {
    GstPad *dest = gst_element_request_pad_simple(muxer, "video_%u");
    GstPad *src = add_branch(own_video, "queue", dest);
    gst_object_unref(dest);
    if (src != NULL) {
      gst_pad_add_probe(src, GST_PAD_PROBE_TYPE_BUFFER, until_keyframe, NULL, NULL);
      gst_object_unref(src);
      // a keyframe now (else within the keyframe distance)
      Branch *b = g_ptr_array_index(branches, branches->len - 1);
      gst_pad_send_event(b->tap, gst_event_new_custom(GST_EVENT_CUSTOM_UPSTREAM,
                                                      gst_structure_new("GstForceKeyUnit", "all-headers",
                                                                        G_TYPE_BOOLEAN, TRUE, NULL)));
      g_ptr_array_add(tracks, "own-video");
    }
  }
  gst_clear_object(&own_audio);
  gst_clear_object(&peer_audio);
  gst_clear_object(&peer_video);
  gst_clear_object(&own_video);
  if (!ok || record_stopping || branches->len == 0) {
    g_ptr_array_unref(tracks);
    if (!record_stopping) {
      record_stopping = TRUE;
      record_error = g_strdup("cannot record");
    }
    finish_recording(NULL);
    return G_SOURCE_REMOVE;
  }
  send_recording("started", NULL, tracks);
  g_ptr_array_unref(tracks);
  return G_SOURCE_REMOVE;
}

/* Records into `path` once connected (a moment after it), else at once */
static void request_recording(const char *path) {
  if (record_path != NULL) {
    send_value("recording", "state", "failed");
    g_printerr("norc-rtc: already recording into %s\n", record_path);
    return;
  }
  record_path = g_strdup(path);
  if (connected_at == 0)
    return;
  const gint64 left = connected_at + RECORD_DELAY * G_USEC_PER_SEC - g_get_monotonic_time();
  if (left <= 0)
    begin_recording(NULL);
  else
    record_timer = g_timeout_add(left / 1000, begin_recording, NULL);
}

/* Connected: a requested recording starts a moment later */
static gboolean on_connected(gpointer data) {
  if (connected_at != 0)
    return G_SOURCE_REMOVE;
  connected_at = g_get_monotonic_time();
  if (record_path != NULL && recorder == NULL && record_timer == 0)
    record_timer = g_timeout_add_seconds(RECORD_DELAY, begin_recording, NULL);
  return G_SOURCE_REMOVE;
}

/* Ends the call: a recording is written first */
static void quit(void) {
  if (recorder != NULL) {
    quit_after_recording = TRUE;
    stop_recording(NULL);
  } else
    g_main_loop_quit(loop);
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
  else if (strcmp(type, "record") == 0) {
    const char *file = json_object_get_string_member_with_default(msg, "file", NULL);
    if (file != NULL)
      request_recording(file);
    else
      stop_recording(NULL);
  } else if (strcmp(type, "hangup") == 0)
    quit();
  else
    g_printerr("norc-rtc: unknown message: %s\n", type);
  g_object_unref(parser);
  g_free(line);
  return G_SOURCE_REMOVE;
}

static gboolean end_of_input(gpointer data) {
  quit();
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

static int run(int argc, char *argv[]) {
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
  if (list_devices) {
    print_devices();
    return 0;
  }
#ifndef _WIN32
  // norc quit: a recording is still written (messages to it are lost)
  signal(SIGPIPE, SIG_IGN);
#endif
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

/* On macOS windows (of the received video) need the Cocoa event loop on the main thread: gst_macos_main runs
 * it there, and `run` in a thread */
static int run_main(int argc, char **argv, gpointer data) {
  (void)data;
  return run(argc, argv);
}

int main(int argc, char *argv[]) {
#if defined(__APPLE__) && GST_CHECK_VERSION(1, 22, 0)
  return gst_macos_main(run_main, argc, argv, NULL);
#else
  return run_main(argc, argv, NULL);
#endif
}

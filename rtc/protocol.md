# norc-rtc protocol

`norc-rtc` runs the media of one call: audio (and video) over WebRTC (ICE, DTLS-SRTP, RTP), with GStreamer's
`webrtcbin`. It does no XMPP: norc (or any other program) passes the session descriptions and ICE candidates
between it and the peer.

```
norc-rtc [--audio=DIRECTION] [--video[=DIRECTION]] [--stun URI] [--turn URI ...] [--audio-source PIPELINE] [--audio-file PATH] [--audio-sink PIPELINE]
         [--video-source PIPELINE] [--video-sink PIPELINE] [--no-bundle] [--record PATH] [--test]
```

| Option | |
|---|---|
| `--audio=DIRECTION` | audio (Opus): `both` (default), `send`, `receive` or `none` |
| `--video[=DIRECTION]` | video too (VP8): without value `both`, or `send`, `receive`, `none` (default) |
| `--stun stun://host:port` | STUN server |
| `--turn turn://user:password@host:port` | TURN server, repeatable (`turns://` for TLS) |
| `--audio-source`, `--audio-sink` | GStreamer elements, default `autoaudiosrc`, `autoaudiosink` |
| `--microphone`, `--speaker`, `--camera NAME` | a device by its name or a part of it (`--list-devices`), instead of the source and sink elements |
| `--video-size WxH`, `--video-fps N` | size and frame rate of the sent video (default: of the camera) |
| `--video-bitrate`, `--audio-bitrate KBPS` | bitrates of the sent video (VP8, default 256) and audio (Opus, default: its choice) |
| `--list-devices` | list the microphones, speakers and cameras, then exit |
| `--echo-cancel` | echo cancellation (of the played audio) and noise suppression of the microphone (`webrtcdsp`; without it if GStreamer has none, as on some macOS installs) |
| `--audio-file PATH` | play a file instead of the audio source (any format GStreamer decodes, at its speed; silence after its end) |
| `--video-source`, `--video-sink` | default `autovideosrc`, `autovideosink` |
| `--self-view` | a small window with the own video as sent (mirrored, at 320 pixels wide), in the video sink; it stands still while the video is muted |
| `--no-bundle` | a connection for each media, for peers without BUNDLE (e.g. Dino); by default all media share one |
| `--record PATH` | record the call into a file (WebM), see [Recording](#recording) |
| `--test` | test signals as sources (a tone, a test picture), received media is discarded |

The directions apply to the offer, and limit the answer to an offer (e.g. `--video=none` answers a video call without
video). Only what was negotiated is sent, media of the peer which isn't received is discarded.

Messages are JSON objects, one per line, with a `type`. norc-rtc reads them on stdin and writes them on stdout;
diagnostics go to stderr. It exits at the end of its input or after `hangup` (a recording is written first): exit code 0,
or 1 after an `error`.

## To norc-rtc

| Message | |
|---|---|
| `{"type": "offer"}` | start the call: create an offer (answered with `sdp`) |
| `{"type": "sdp", "sdp_type": "offer", "sdp": "v=0…"}` | the peer's offer: answered with `sdp` (the answer) |
| `{"type": "sdp", "sdp_type": "answer", "sdp": "v=0…"}` | the peer's answer to the own offer |
| `{"type": "candidate", "mline": 0, "candidate": "candidate:…"}` | an ICE candidate of the peer (trickle ICE) |
| `{"type": "mute", "media": "audio", "muted": true}` | mute or unmute the own audio or video |
| `{"type": "record", "file": "/path/call.webm"}` | start a recording (like `--record`) |
| `{"type": "record"}` | stop the recording |
| `{"type": "hangup"}` | end the call and exit |

## From norc-rtc

| Message | |
|---|---|
| `{"type": "ready"}` | the media are set up, waiting for `offer` or `sdp` |
| `{"type": "sdp", "sdp_type": "offer" \| "answer", "sdp": "v=0…"}` | the own session description, for the peer |
| `{"type": "candidate", "mline": 0, "candidate": "candidate:…"}` | an own ICE candidate, for the peer |
| `{"type": "gathering", "state": "complete"}` | all own candidates were sent |
| `{"type": "state", "state": "connecting" \| "connected" \| "disconnected" \| "failed" \| "closed"}` | the connection to the peer |
| `{"type": "media", "media": "audio" \| "video", "width": 640, "height": 360}` | media of the peer arrive (video with its size) |
| `{"type": "recording", "state": "started", "file": "…", "tracks": ["audio", "video", "own-video"]}` | a recording started, with its tracks |
| `{"type": "recording", "state": "stopped", "file": "…"}` | the recording is written |
| `{"type": "recording", "state": "failed", "file": "…", "message": "…"}` | the recording failed (e.g. the file can't be written), the call goes on |
| `{"type": "error", "message": "…"}` | an error, the call ends |

A call: the caller sends `offer`, passes the `sdp` it gets to the peer, and the peer's answer back as `sdp`; both
sides pass their `candidate` messages to the other. The callee gets the offer as `sdp` and answers with `sdp`.

## Recording

A recording (`--record`, or `record` during the call) starts two seconds after the connection, when the media of
the peer flow, with the media flowing then; requested later, at once. Its file (WebM) has these tracks:

- `audio`: both voices mixed (Opus, encoded again), as most players play only one audio track. A voice starting
  later is added.
- `video`: the video of the peer as received (VP8, not encoded again), from a keyframe.
- `own-video`: the own video as sent.

A video starting after the recording is not recorded (the tracks of a file are fixed at its start). Stopping it
(`record` without file, `hangup`, the end of the input) ends the file properly, with its duration and index; norc-rtc
waits for that at most 3 seconds.

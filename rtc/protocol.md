# norc-rtc protocol

`norc-rtc` runs the media of one call: audio (and video) over WebRTC (ICE, DTLS-SRTP, RTP), with GStreamer's
`webrtcbin`. It does no XMPP: norc (or any other program) passes the session descriptions and ICE candidates
between it and the peer.

```
norc-rtc [--video] [--stun URI] [--turn URI ...] [--audio-source PIPELINE] [--audio-sink PIPELINE]
         [--video-source PIPELINE] [--video-sink PIPELINE] [--test]
```

| Option | |
|---|---|
| `--video` | send and receive video too (VP8) |
| `--stun stun://host:port` | STUN server |
| `--turn turn://user:password@host:port` | TURN server, repeatable (`turns://` for TLS) |
| `--audio-source`, `--audio-sink` | GStreamer elements, default `autoaudiosrc`, `autoaudiosink` |
| `--video-source`, `--video-sink` | default `autovideosrc`, `autovideosink` |
| `--test` | test signals as sources (a tone, a test picture), received media is discarded |

Messages are JSON objects, one per line, with a `type`. norc-rtc reads them on stdin and writes them on stdout;
diagnostics go to stderr. It exits at the end of its input or after `hangup`: exit code 0, or 1 after an `error`.

## To norc-rtc

| Message | |
|---|---|
| `{"type": "offer"}` | start the call: create an offer (answered with `sdp`) |
| `{"type": "sdp", "sdp_type": "offer", "sdp": "v=0…"}` | the peer's offer: answered with `sdp` (the answer) |
| `{"type": "sdp", "sdp_type": "answer", "sdp": "v=0…"}` | the peer's answer to the own offer |
| `{"type": "candidate", "mline": 0, "candidate": "candidate:…"}` | an ICE candidate of the peer (trickle ICE) |
| `{"type": "mute", "media": "audio", "muted": true}` | mute or unmute the own audio or video |
| `{"type": "hangup"}` | end the call and exit |

## From norc-rtc

| Message | |
|---|---|
| `{"type": "ready"}` | the media are set up, waiting for `offer` or `sdp` |
| `{"type": "sdp", "sdp_type": "offer" \| "answer", "sdp": "v=0…"}` | the own session description, for the peer |
| `{"type": "candidate", "mline": 0, "candidate": "candidate:…"}` | an own ICE candidate, for the peer |
| `{"type": "gathering", "state": "complete"}` | all own candidates were sent |
| `{"type": "state", "state": "connecting" \| "connected" \| "disconnected" \| "failed" \| "closed"}` | the connection to the peer |
| `{"type": "media", "media": "audio" \| "video"}` | media of the peer arrive |
| `{"type": "error", "message": "…"}` | an error, the call ends |

A call: the caller sends `offer`, passes the `sdp` it gets to the peer, and the peer's answer back as `sdp`; both
sides pass their `candidate` messages to the other. The callee gets the offer as `sdp` and answers with `sdp`.

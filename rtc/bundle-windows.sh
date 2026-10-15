#!/bin/sh
#
# Bundles norc-rtc.exe (built with MSYS2 UCRT64) with the GStreamer plugins it uses and all DLLs they need into a
# folder that runs without MSYS2: rtc/bundle-windows.sh [OUT] (default dist/norc, the release adds norc.exe to bin)
#
#   OUT/bin/norc-rtc.exe and the DLLs
#   OUT/lib/gstreamer-1.0/ the plugins (GStreamer finds them relative to its DLL)
#
# Without gst-plugin-scanner.exe: GStreamer scans the few plugins in its own process.
set -e
out=${1:-dist/norc}
prefix=${MINGW_PREFIX:-/ucrt64}

# webrtcbin and its transport (ICE, DTLS, SRTP, RTP), the codecs, and the elements of the pipelines of norc-rtc:
# conversions, decodebin, automatic and Windows devices, test signals
plugins="coreelements webrtc nice dtls srtp rtp rtpmanager opus vpx audioconvert audioresample volume
	videoconvertscale playback typefindfunctions autodetect audiotestsrc videotestsrc
	wasapi wasapi2 directsound d3d11 mediafoundation"

rm -rf "$out"
mkdir -p "$out/bin" "$out/lib/gstreamer-1.0"
cp norc-rtc.exe "$out/bin/"
for p in $plugins; do
  f="$prefix/lib/gstreamer-1.0/libgst$p.dll"
  if [ -f "$f" ]; then cp "$f" "$out/lib/gstreamer-1.0/"; else echo "missing plugin: $p" >&2; fi
done

# the DLLs of the program and the plugins (ldd lists them transitively), only those of MSYS2
for f in "$out"/bin/norc-rtc.exe "$out"/lib/gstreamer-1.0/*.dll; do
  ldd "$f" | awk '{print $3}'
done | grep -i "^$prefix/bin/" | sort -u | while read -r dll; do
  cp "$dll" "$out/bin/"
done

echo "$out: $(find "$out" -type f | wc -l) files, $(du -sh "$out" | cut -f1)"

#!/bin/sh
# Regression test for the HDR start glitch: [HDR] used to set
# d3d11-output-csp/-format, which mpv reads only at VO creation, so applying
# the profile ~0.2 s into every HDR file rebuilt the VO and restarted the
# decoder mid-GOP (2 GPU context inits, HEVC "Could not find ref" errors).
# Works with Windows HDR on or off. Run from the repo root in Git Bash:
#   sh docs/tests/hdr_start_glitch_test.sh
set -e
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
w=$(cygpath -w "$tmp")

./ffmpeg.exe -v error -y -f lavfi -i "testsrc2=size=1280x720:rate=24" -t 5 \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le \
  -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:keyint=48:bframes=3" \
  "$tmp/pq.mkv"

timeout 40 ./mpv.exe --length=3 --keep-open=no --no-resume-playback \
  --save-position-on-quit=no --volume=0 \
  --script-opts-append=autoload-disabled=yes \
  --msg-level=all=v --log-file="$w\\run.log" "$w\\pq.mkv" >/dev/null 2>&1 || true

hdr=$(grep -ac "Applying auto profile: HDR" "$tmp/run.log" || true)
ctx=$(grep -ac "Initializing GPU context" "$tmp/run.log" || true)
err=$(grep -ac "Could not find ref\|Error constructing the frame RPS" "$tmp/run.log" || true)
echo "HDR profile applies: $hdr, GPU context inits: $ctx, HEVC ref errors: $err"
if [ "$hdr" -eq 0 ]; then echo "FAIL: [HDR] never applied, test is not exercising the bug"; exit 1; fi
if [ "$ctx" -ne 1 ] || [ "$err" -ne 0 ]; then echo "FAIL: VO rebuilt at HDR start"; exit 1; fi
echo PASS

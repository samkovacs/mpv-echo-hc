#!/bin/sh
# Regression test for hdr-mode.lua re-applying the whole HDR render target
# on every frame. hdr-compute-peak=yes ([HDR] profile) puts per-frame
# avg-pq-y/max-pq-y into video-out-params, which switch_hdr observes.
#
# Plays 5 s of a 24 fps PQ clip through the real config with the display
# plugin's hdr-status forced "on" (simulated Windows HDR; the real display
# is untouched) and counts target-peak writes. Broken: ~115 (one per
# frame). Fixed: a few at start. Run from the repo root in Git Bash:
#   sh docs/tests/hdr_mode_writes_test.sh
set -e
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
w=$(cygpath -w "$tmp")

./ffmpeg.exe -v error -y -f lavfi -i "testsrc2=size=1280x720:rate=24" -t 5 \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le \
  -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
  "$tmp/pq.mkv"

cat > "$tmp/fake_hdr_on.lua" <<'EOF'
local function on() mp.set_property_native("user-data/display-info/hdr-status", "on") end
on()
mp.add_periodic_timer(0.5, function()
    if mp.get_property_native("user-data/display-info/hdr-status") ~= "on" then on() end
end)
EOF

timeout 40 ./mpv.exe --length=5 --keep-open=no --no-resume-playback \
  --save-position-on-quit=no --volume=0 \
  --script-opts-append=autoload-disabled=yes --script="$w\\fake_hdr_on.lua" \
  --msg-level=all=v --log-file="$w\\run.log" "$w\\pq.mkv" >/dev/null 2>&1 || true

hdr=$(grep -ac 'Set property: target-trc="pq"' "$tmp/run.log" || true)
n=$(grep -ac 'Set property: target-peak=' "$tmp/run.log" || true)
echo "target-peak writes: $n (HDR target applied: $hdr)"
if [ "$hdr" -eq 0 ]; then echo "FAIL: HDR branch never ran, test is not exercising the bug"; exit 1; fi
if [ "$n" -gt 10 ]; then echo "FAIL: per-frame writes"; exit 1; fi
echo PASS

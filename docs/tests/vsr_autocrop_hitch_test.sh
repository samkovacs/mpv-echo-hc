#!/bin/sh
# Regression test for vsr_autocrop's crop-detection hitches: each retry used
# to insert and remove cropdetect with @vsr already in the chain, and every
# such filter change drops a frame ("dropping frame due to pin disconnect").
# A bar-less film pays that on every retry.
#
# 1. no bars, 25 s (first detection + first retry): expect 0 pin disconnects.
# 2. 6 s full-frame logo, then 2.39:1 letterbox: the retry must still find
#    the bars (cropdetect's reset keeps the logo from pinning the bounds),
#    with at most the one drop of @vsr being rebuilt at the cropped scale.
# Takes ~55 s. Run from the repo root in Git Bash:
#   sh docs/tests/vsr_autocrop_hitch_test.sh
set -e
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
w=$(cygpath -w "$tmp")
lb="gradients=s=1920x804:r=24000/1001:speed=0.02:c0=0x3070a0:c1=0xa04030,pad=1920:1080:0:138:black"

./ffmpeg.exe -v error -y -f lavfi -i "gradients=s=1920x1080:r=24000/1001:speed=0.02" -t 30 \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$tmp/nobars.mkv"
./ffmpeg.exe -v error -y -f lavfi -i "gradients=s=1920x1080:r=24000/1001:speed=0.05:c0=0x808080:c1=0xe0e0e0" \
  -f lavfi -i "$lb" -filter_complex "[0]trim=0:6,setpts=PTS-STARTPTS[a];[1]trim=0:24,setpts=PTS-STARTPTS[b];[a][b]concat=n=2" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$tmp/logo_then_bars.mkv"

run() {
  timeout 60 ./mpv.exe --length=25 --keep-open=no --volume=0 --no-resume-playback \
    --save-position-on-quit=no --script-opts-append=autoload-disabled=yes \
    --msg-level=all=v --log-file="$w\\$1.log" "$w\\$1.mkv" >/dev/null 2>&1 || true
}
run nobars
run logo_then_bars

fail=0
# drops before 24 s: end-of-file teardown at 25 s removes filters too
playing_drops() { awk -F"[][]" '/pin disconnect/ && $2+0 < 24 {n++} END {print n+0}' "$1"; }
d1=$(playing_drops "$tmp/nobars.log")
r1=$(grep -ac "re-running crop detection" "$tmp/nobars.log" || true)
echo "no bars: pin disconnects=$d1 (retries run: $r1)"
[ "$r1" -ge 1 ] || { echo "FAIL: no retry ran, test is not exercising the bug"; fail=1; }
[ "$d1" -eq 0 ] || { echo "FAIL: crop detection dropped frames"; fail=1; }

d2=$(playing_drops "$tmp/logo_then_bars.log")
crop=$(grep -a "Set property: file-local-options/video-crop=[0-9]" "$tmp/logo_then_bars.log" | tail -1 | sed 's/.*video-crop=//; s/ .*//')
echo "logo then 2.39:1: crop=$crop pin disconnects=$d2"
case "$crop" in *x*+0+*) ;; *) echo "FAIL: letterbox not cropped after the logo"; fail=1 ;; esac
[ "$d2" -le 1 ] || { echo "FAIL: more than the one @vsr rebuild drop"; fail=1; }

[ "$fail" -eq 0 ] && echo PASS || exit 1

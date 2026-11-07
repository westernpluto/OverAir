#!/usr/bin/env bash
# Generates broadcast-like test streams and artwork for the mock HDHomeRun.
set -euo pipefail
OUT=${1:-ci/media}
mkdir -p "$OUT"
ff() { ffmpeg -loglevel error -y "$@"; }
ff -f lavfi -i "testsrc2=size=1920x1080:rate=30000/1001" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 20 \
   -c:v mpeg2video -b:v 10M -maxrate 14M -bufsize 6M -vf setfield=tff -flags +ilme+ildct -bf 2 -g 15 \
   -c:a ac3 -b:a 384k -ac 6 -metadata:s:a:0 language=eng -f mpegts "$OUT/1080i.ts"
ff -f lavfi -i "smptehdbars=size=1280x720:rate=60000/1001" -f lavfi -i "sine=frequency=660:sample_rate=48000" -t 20 \
   -c:v mpeg2video -b:v 8M -bf 2 -g 30 -c:a ac3 -b:a 192k -ac 2 -f mpegts "$OUT/720p.ts"
ff -f lavfi -i "mandelbrot=size=704x480:rate=30000/1001" -f lavfi -i "sine=frequency=550:sample_rate=48000" -t 20 \
   -vf setfield=bff -c:v mpeg2video -b:v 3M -flags +ilme+ildct -aspect 16:9 -bf 2 -g 15 -c:a ac3 -b:a 192k -ac 2 -f mpegts "$OUT/480i.ts"
# An ATSC 3.0 capture (HEVC video, Dolby AC-4 audio) from FFmpeg's public sample archive.
curl -sSfL --retry 3 -o "$OUT/atsc3.ts" https://samples.ffmpeg.org/A-codecs/ac-4/KDAF.ts \
  || cp "$OUT/1080i.ts" "$OUT/atsc3.ts"
for i in 0 1 2 3 4 5; do
  ff -f lavfi -i "gradients=size=640x360:seed=$((i*7+3)):duration=1" -frames:v 1 "$OUT/art$i.jpg"
done
ff -f lavfi -i "color=c=0x2a6fdb:size=128x128" -frames:v 1 "$OUT/logo.png"
ls -la "$OUT"

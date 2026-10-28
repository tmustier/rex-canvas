#!/bin/sh
# Records a region of the screen and converts it to a GIF for the README.
# Usage: scripts/record-gif.sh SECONDS X,Y,WIDTH,HEIGHT [OUTPUT]
# The region is in screen points from the top left. Leave out the Rex sidebar so session names stay private.
set -eu
seconds=$1
region=$2
output=${3:-docs/demo.gif}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$output")"
echo "Recording $region for $seconds seconds..."
screencapture -x -k -v -V "$seconds" -R "$region" "$work/clip.mov"
ffmpeg -loglevel error -y -i "$work/clip.mov" \
  -vf "fps=15,scale=1100:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
  "$output"
echo "Wrote $output ($(du -h "$output" | cut -f1))"

#!/bin/zsh
# Runs every tool's headless processing test on fresh fixtures and checks outputs exist.
# Usage: scripts/test-tools.sh [path/to/Clementine binary]
set -u
cd "$(dirname "$0")/.."
BIN=${1:-.build/debug/Clementine}
W=$(mktemp -d /tmp/clementine-tools.XXXXXX)
echo "Working in $W"
ff() { ffmpeg -v error -y "$@"; }

ff -f lavfi -i testsrc2=size=1600x1000:rate=1 -frames:v 1 -q:v 1 $W/photo.jpg
ff -f lavfi -i testsrc2=size=900x1200:rate=1 -frames:v 1 $W/second.jpg
ff -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i "sine=frequency=330:duration=4" -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac $W/clip.mp4
cp $W/clip.mp4 $W/clip2.mp4
ff -f lavfi -i "anullsrc=r=44100:cl=stereo:d=1" -f lavfi -i "sine=frequency=440:duration=3" -f lavfi -i "anullsrc=r=44100:cl=stereo:d=1" \
   -filter_complex "[1]aformat=channel_layouts=stereo,volume=0.3[t];[0][t][2]concat=n=3:v=0:a=1" $W/voice.wav
printf 'Line one of a short note.\nLine two.\n' > $W/notes.txt
$BIN --convert $W/notes.txt pdf >/dev/null
$BIN --convert $W/photo.jpg pdf >/dev/null
mv $W/photo.pdf $W/photo-page.pdf
mkdir -p $W/pack && echo hi > $W/pack/a.txt && (cd $W/pack && zip -q -r $W/bundle.zip .)
QR=$($BIN --tool-test makeQR "text=https://example.com/clementine" 2>&1 | tail -1)

pass=0; fail=0
run() {
  local name=$1; shift
  local result
  result=$($BIN --tool-test $name "$@" 2>&1 | grep -v AttributeGraph)
  local last=$(print -r -- "$result" | tail -1)
  if [[ $last == error:* || $last == "no tool test"* ]]; then
    fail=$((fail+1)); echo "FAIL $name: $last"
  else
    pass=$((pass+1)); echo "ok   $name → ${last:t}"
  fi
}

run editImage $W/photo.jpg exposure=0.4
run annotateImage $W/photo.jpg
run frameImage $W/photo.jpg
run cropImage $W/photo.jpg aspect=square
run redactImage $W/photo.jpg
run createCollage $W/photo.jpg $W/second.jpg
run trimVideo $W/clip.mp4 start=0.5 end=2.5
run cropVideo $W/clip.mp4
run changeVideoSpeed $W/clip.mp4 speed=2
run splitVideo $W/clip.mp4
run videoSnapshots $W/clip.mp4
run redactVideo $W/clip.mp4 "boxes=100,100,300,200,0.5,2.5" style=blur
run joinVideos $W/clip.mp4 $W/clip2.mp4
run muteVideo $W/clip.mp4
run videoEditorMath
run trimAudio $W/voice.wav auto=1
run normalizeAudio $W/voice.wav
run audioChannels $W/voice.wav
run audioToVideo $W/voice.wav
run redactAudio $W/voice.wav ranges=1.2-1.8,2.5-3.0
run compress $W/photo.jpg strength=strong
run compress $W/clip.mp4
run removeMetadata $W/photo.jpg mode=all
run splitPDF $W/notes.pdf
run organizePDF $W/notes.pdf
run mergePDF $W/notes.pdf $W/photo-page.pdf
run createPDF $W/photo.jpg $W/second.jpg
run readQRCode $QR
run extractArchive $W/bundle.zip

echo "passed: $pass  failed: $fail"
[[ $fail == 0 ]]

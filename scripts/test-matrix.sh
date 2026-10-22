#!/bin/zsh
# Runs every conversion in the compatibility matrix and checks each output decodes.
# Usage: scripts/test-matrix.sh [path/to/Clementine binary]
set -u
cd "$(dirname "$0")/.."
BIN=${1:-.build/debug/Clementine}
WORK=$(mktemp -d /tmp/clementine-matrix.XXXXXX)
SRC=$WORK/src
mkdir -p $SRC
echo "Working in $WORK"

# --- Fixtures, one per source format ------------------------------------------
ff() { ffmpeg -v error -y "$@"; }
ff -f lavfi -i testsrc2=size=1200x800:rate=1 -frames:v 1 $SRC/sample.jpg
ff -f lavfi -i "color=c=orange@0.6:size=600x400,format=rgba" -frames:v 1 $SRC/sample.png
printf '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="200"><rect width="300" height="200" fill="#f60"/><circle cx="150" cy="100" r="70" fill="#fff"/></svg>' > $SRC/sample.svg
ff -f lavfi -i "sine=frequency=440:duration=2" -ac 2 $SRC/sample.wav
ff -f lavfi -i testsrc2=size=640x360:rate=25 -f lavfi -i "sine=frequency=330:duration=2" -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac $SRC/sample.mp4
printf 'First line of text.\nSecond line, a bit longer than the first.\n\nThird paragraph.\n' > $SRC/sample.txt
printf '1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n' > $SRC/sample.srt
mkdir -p $WORK/pack/dir && echo one > $WORK/pack/one.txt && echo two > $WORK/pack/dir/two.txt
(cd $WORK/pack && zip -q -r $SRC/sample.zip .)

convert() { $BIN --convert "$1" "$2" | tail -1; }
mv "$(convert $SRC/sample.jpg webp)" $SRC/sample.webp
mv "$(convert $SRC/sample.jpg heic)" $SRC/sample.heic
mv "$(convert $SRC/sample.jpg tiff)" $SRC/sample.tiff
mv "$(convert $SRC/sample.jpg avif)" $SRC/sample.avif
mv "$(convert $SRC/sample.jpg bmp)" $SRC/sample.bmp
mv "$(convert $SRC/sample.txt pdf)" $SRC/sample.pdf
for f in mp3 m4a flac ogg opus aiff wma; do mv "$(convert $SRC/sample.wav $f)" $SRC/sample.$f; done
for f in mov mkv avi wmv gif; do mv "$(convert $SRC/sample.mp4 $f)" $SRC/sample.$f; done
ff -i $SRC/sample.mp4 -c:v libvpx-vp9 -b:v 0 -crf 40 -c:a libopus $SRC/sample.webm
mv "$(convert $SRC/sample.srt vtt)" $SRC/sample.vtt
mv "$(convert $SRC/sample.zip tar)" $SRC/sample.tar
mv "$(convert $SRC/sample.zip gzip)" $SRC/sample.tar.gz
mv "$(convert $SRC/sample.zip rar)" $SRC/sample.rar

# --- Validation ---------------------------------------------------------------
check() {
  local out=$1 fmt=$2
  [[ -e $out ]] || return 1
  if [[ -d $out ]]; then ls $out/* >/dev/null 2>&1; return; fi
  [[ -s $out ]] || return 1
  case $fmt in
    jpg|png|webp|heic|tiff|avif|bmp) sips -g pixelWidth "$out" 2>/dev/null | grep -q pixelWidth ;;
    pdf) head -c 5 "$out" | grep -q '%PDF' ;;
    docx) unzip -tq "$out" >/dev/null 2>&1 && unzip -l "$out" | grep -q word/document.xml ;;
    txt|srt|vtt) [[ -s $out ]] ;;
    zip) unzip -tq "$out" >/dev/null 2>&1 ;;
    tar|gzip|rar) tar -tf "$out" >/dev/null 2>&1 ;;
    *) ffprobe -v error -show_entries format=duration -of csv=p=0 "$out" | grep -q '[0-9]' ;;
  esac
}

pass=0; fail=0; failures=()
for source in $SRC/sample.*; do
  ext=${source##*/sample.}
  case $ext in tar.gz) fmt=gzip ;; *) fmt=$ext ;; esac
  targets=$($BIN --matrix | grep "^${fmt:u} →" | sed 's/.*→ //' | tr 'A-Z' 'a-z')
  for target in ${=targets}; do
    dir=$WORK/out/$fmt-$target
    mkdir -p $dir
    cp $source $dir/
    input=$dir/${source:t}
    result=$($BIN --convert $input $target 2>&1 | tail -1)
    if [[ $result == error:* ]] || ! check "$result" $target; then
      fail=$((fail+1)); failures+=("$fmt → $target: $result")
    else
      pass=$((pass+1))
    fi
  done
done

echo "passed: $pass  failed: $fail"
for f in $failures; do echo "  FAIL $f"; done
[[ $fail == 0 ]]

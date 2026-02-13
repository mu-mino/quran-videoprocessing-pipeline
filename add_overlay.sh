#!/usr/bin/env bash
set -euo pipefail

OVERLAY_IMG="/home/muhammed-emin-eser/desk/din/backupOld.png"

# Ursprüngliche linke obere Ecke
X=313
Y=214

# Ursprüngliche rechte untere Ecke
X2=1034
Y2=284

# Skalierfaktor (>1 = größer, <1 = kleiner)
SCALE_FACTOR="1.5"

SIMILARITY="0.10"
BLEND="0.00"

V_CODEC="libx264"
V_PRESET="ultrafast"
V_CRF="0"
PIX_FMT="yuv420p"

usage() {
  echo "Usage:"
  echo "  $0 --video INPUT.mp4 --out OUTPUT.mp4"
  echo "  $0 --dir INPUT_DIR --out-dir OUTPUT_DIR"
  exit 1
}

require_tools() {
  command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg not found"; exit 1; }
  command -v ffprobe >/dev/null 2>&1 || { echo "ffprobe not found"; exit 1; }
}

img_size() {
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height \
    -of csv=p=0:s=x "$OVERLAY_IMG" | tr 'x' ' '
}

process_one() {
  local in_video="$1"
  local out_video="$2"

  local w h
  read -r w h < <(img_size)

  # Ursprüngliche Box
  local orig_w=$((X2 - X))
  local orig_h=$((Y2 - Y))

  # Mittelpunkt der Box
  local center_x=$((X + orig_w / 2))
  local center_y=$((Y + orig_h / 2))

  # Neue Breite/Höhe proportional skaliert
  local new_w=$(printf "%.0f" "$(echo "$orig_w * $SCALE_FACTOR" | bc -l)")
  local new_h=$(printf "%.0f" "$(echo "$orig_h * $SCALE_FACTOR" | bc -l)")

  # Neue linke obere Ecke so berechnet,
  # dass um den Mittelpunkt herum skaliert wird
  local new_x=$((center_x - new_w / 2))
  local new_y=$((center_y - new_h / 2))

  ffmpeg -nostdin -y -threads 16 \
    -i "$in_video" \
    -loop 1 -i "$OVERLAY_IMG" \
    -filter_complex "
      [1:v]format=rgba,chromakey=0x000000:${SIMILARITY}:${BLEND}[txt];
      [0:v]scale=${new_w}:${new_h}:force_original_aspect_ratio=decrease,
           pad=${new_w}:${new_h}:(ow-iw)/2:(oh-ih)/2:color=black@0,
           format=rgba[vidbox];
      color=c=black@1.0:s=${w}x${h}:r=30,format=rgba[base];
      [base][vidbox]overlay=${new_x}:${new_y}:shortest=1:eof_action=pass[withvid];
      [withvid][txt]overlay=0:0:shortest=1,
      scale=trunc(iw/2)*2:trunc(ih/2)*2[outv]
    " \
    -map "[outv]" -map 0:a? \
    -shortest \
    -c:v "${V_CODEC}" -preset "${V_PRESET}" -crf "${V_CRF}" -pix_fmt "${PIX_FMT}" \
    -c:a copy \
    "$out_video"
}

main() {
  require_tools

  [[ -f "$OVERLAY_IMG" ]] || { echo "Overlay image not found: $OVERLAY_IMG"; exit 1; }

  local mode=""
  local in_video=""
  local out_video=""
  local in_dir=""
  local out_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --video)   mode="single"; in_video="$2"; shift 2 ;;
      --out)     out_video="$2"; shift 2 ;;
      --dir)     mode="batch"; in_dir="$2"; shift 2 ;;
      --out-dir) out_dir="$2"; shift 2 ;;
      *) usage ;;
    esac
  done

  if [[ "$mode" == "single" ]]; then
    [[ -n "$in_video" && -n "$out_video" ]] || usage
    process_one "$in_video" "$out_video"
    exit 0
  fi

  if [[ "$mode" == "batch" ]]; then
    [[ -n "$in_dir" && -n "$out_dir" ]] || usage
    mkdir -p "$out_dir"
    shopt -s nullglob
    for f in "$in_dir"/*; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f")"
      name="${base%.*}"
      process_one "$f" "$out_dir/${name}.mp4"
    done
    exit 0
  fi

  usage
}

main "$@"

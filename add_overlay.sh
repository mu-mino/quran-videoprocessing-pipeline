#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Hard-coded overlay image (black background + white text)
# ------------------------------------------------------------------
OVERLAY_IMG="/home/muhammed-emin-eser/desk/din/backupOld.png"

# ------------------------------------------------------------------
# Target box inside overlay where video must fit (aspect ratio kept)
# ------------------------------------------------------------------
X=313
Y=214
BOX_W=$((1034-313))   # 721
BOX_H=$((284-214))    # 70

# ------------------------------------------------------------------
# Remove black background from overlay image
# ------------------------------------------------------------------
SIMILARITY="0.10"
BLEND="0.00"

# ------------------------------------------------------------------
# LOSSLESS encode (no quality loss)
# ------------------------------------------------------------------
V_CODEC="libx264"
V_PRESET="ultrafast"
V_CRF="0"
PIX_FMT="yuv420p"

# ------------------------------------------------------------------
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

  ffmpeg -nostdin -y -threads 16 \
    -i "$in_video" \
    -loop 1 -i "$OVERLAY_IMG" \
    -filter_complex "
      [1:v]format=rgba,chromakey=0x000000:${SIMILARITY}:${BLEND}[txt];

      [0:v]scale=${BOX_W}:${BOX_H}:force_original_aspect_ratio=decrease,
           pad=${BOX_W}:${BOX_H}:(ow-iw)/2:(oh-ih)/2:color=black@0,
           format=rgba[vidbox];

      color=c=black@1.0:s=${w}x${h}:r=30,format=rgba[base];

      [base][vidbox]overlay=${X}:${Y}:format=auto[withvid];
      [withvid][txt]overlay=0:0:format=auto,
      scale=trunc(iw/2)*2:trunc(ih/2)*2[outv]
    " \
    -map "[outv]" -map 0:a? \
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

#!/usr/bin/env bash
set -euo pipefail

# Pfad zum Hintergrundbild
OVERLAY_IMG="/home/muhammed-emin-eser/desk/din/finish.png"

# Koordinaten-Box, in der das Video platziert werden soll
X=313
Y=214
X2=1034
Y2=284

SCALE_FACTOR="1.3"

# Einstellungen für das Entfernen des schwarzen Hintergrunds
SIMILARITY="0.10"
BLEND="0.10"

V_CODEC="libx264"
V_PRESET="ultrafast"
V_CRF="18"
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

# Ermittelt Breite und Höhe des Hintergrundbildes
img_size() {
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height \
    -of csv=p=0:s=x "$OVERLAY_IMG" | tr 'x' ' '
}

process_one() {
  local in_video="$1"
  local out_video="$2"

  # 1. Maße des Hintergrundbildes lesen
  local w h
  read -r w h < <(img_size)

  # 2. Ziel-Box berechnen
  local orig_w=$((X2 - X))
  local orig_h=$((Y2 - Y))

  local center_x=$((X + orig_w / 2))
  local center_y=$((Y + orig_h / 2))

  # 3. Neue Skalierung für das Video berechnen
  local new_w
  new_w=$(awk -v a="$orig_w" -v b="$SCALE_FACTOR" 'BEGIN{printf "%d", a*b}')
  local new_h
  new_h=$(awk -v a="$orig_h" -v b="$SCALE_FACTOR" 'BEGIN{printf "%d", a*b}')

  # 4. Neue Position (Zentriert basierend auf Skalierung)
  local offset=160
  local new_x=$(( center_x - (new_w / 2) + offset ))
  local offset_y=10
  local new_y=$((center_y - (new_h / 2) - offset_y))

  echo "Processing: $in_video -> $out_video"
  echo "Target Geo: ${new_w}x${new_h} at $new_x,$new_y on Background ${w}x${h}"

  # 5. FFmpeg Verarbeitung
  # WICHTIG: "0:a?" muss in Anführungszeichen stehen, da shopt -s nullglob im Batch-Modus aktiv ist.
  # Ohne Quotes versucht Bash "0:a?" als Dateimuster aufzulösen, findet nichts und löscht das Argument.
ffmpeg -nostdin -y \
    -threads 0 -filter_threads 0 -filter_complex_threads 0 \
    -i "$in_video" \
    -loop 1 -i "$OVERLAY_IMG" \
    -filter_complex "
    [1:v]format=rgba[bg_raw];
    
    [0:v]scale=${new_w}:${new_h}:force_original_aspect_ratio=decrease, \
        format=rgba, \
        colorkey=0x000000:${SIMILARITY}:${BLEND}, \
        unsharp=5:5:0.6:5:5:0.0[fg];
        
    [bg_raw]scale='trunc(iw/2)*2':'trunc(ih/2)*2'[bg];
    
    [bg][fg]overlay=${new_x}:${new_y}:shortest=1:eof_action=pass, \
        format=yuv420p[outv]
    " \
    -map "[outv]" -map "0:a?" \
    -c:v "${V_CODEC}" -preset slow -crf "${V_CRF}" -pix_fmt "${PIX_FMT}" \
    -c:a copy \
    "$out_video"

}

main() {
  require_tools
  [[ -f "$OVERLAY_IMG" ]] || { echo "Overlay image not found at $OVERLAY_IMG"; exit 1; }

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
    process_one "$in_video" "$out_video"
    exit 0
  fi

  if [[ "$mode" == "batch" ]]; then
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
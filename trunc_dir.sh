#!/usr/bin/env bash
set -euo pipefail

INPUT_DIR="/home/muhammed-emin-eser/desk/din/quran/Quran_cropped/"
OUTPUT_DIR="/home/muhammed-emin-eser/desk/din/quran/truncated_FINAL_ALLL_cropped_sides/"

mkdir -p "$OUTPUT_DIR"

for file in "$INPUT_DIR"/*; do
    [ -f "$file" ] || continue

    echo "FILE = [$file]"

    filename="$(basename "$file")"
    name="${filename%.*}"
    out_file="$OUTPUT_DIR/$name.mp4"

    ffmpeg -nostdin -y -threads 16 -i "$file" \
        -vf "crop=iw-200:ih:100:0" \
        "$out_file"
done
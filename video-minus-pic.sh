#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage:"
  echo "  $0 <audio.(mp3|flac|wav)> <video.mp4>"
  echo "  $0 <video.mp4> <audio.(mp3|flac|wav)>"
  echo "  $0 <videos_dir> <audios_dir>"
  echo
  echo "Batch mode pairs files by shared ID '(n)' in filenames."
  echo "Environment overrides: JOBS, FFMPEG_THREADS, VP9_CPU_USED, OUT_EXT (mkv|webm)"
  exit 1
fi

ARG1="$1"
ARG2="$2"

BG="/home/muhammed-emin-eser/desk/din/image.png"
if [[ ! -f "$BG" ]]; then
  echo "External background image not found: $BG"
  exit 1
fi

lower_ext() {
  local path="$1"
  path="${path##*.}"
  printf '%s' "${path,,}"
}

audio_rank() {
  case "$1" in
    flac) printf '3\n' ;;
    wav) printf '2\n' ;;
    mp3) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

extract_id() {
  local name
  name="$(basename "$1")"
  if [[ "$name" =~ \(([0-9]+)\) ]]; then
    printf '(%s)\n' "${BASH_REMATCH[1]}"
  fi
}

process_pair() {
  local audio="$1"
  local video="$2"

  local dir base out_ext out
  dir="$(dirname "$video")"
  base="$(basename "$video")"
  base="${base%.*}"

  out_ext="${OUT_EXT:-mkv}"
  case "$out_ext" in
    mkv|webm) ;;
    *)
      echo "Invalid OUT_EXT='$out_ext' (expected mkv or webm)"
      return 2
      ;;
  esac

  out="$dir/$base.text_only.$out_ext"

  local threads cpu_used
  threads="${FFMPEG_THREADS:-0}"
  cpu_used="${VP9_CPU_USED:-6}"

  local audio_codec=()
  if [[ "$out_ext" == "webm" ]]; then
    audio_codec=(-c:a libopus)
  else
    audio_codec=(-c:a copy)
  fi

  echo "Processing:"
  echo "  Video: $video"
  echo "  Audio: $audio"
  echo "  Out:   $out"

  ffmpeg -hide_banner -nostdin -y \
    -threads "$threads" \
    -i "$video" \
    -i "$BG" \
    -i "$audio" \
    -filter_complex "
      [1:v][0:v]scale2ref[bg][vid];
      [vid][bg]blend=all_mode=difference,
      format=gray,
      geq=lum='if(gt(lum(X,Y),25),255,0)',
      format=yuva420p[vout]
    " \
    -map "[vout]" \
    -map 2:a:0 \
    -c:v libvpx-vp9 -pix_fmt yuva420p -lossless 1 -b:v 0 \
    -row-mt 1 -cpu-used "$cpu_used" \
    "${audio_codec[@]}" \
    -shortest \
    "$out"
}

run_batch() {
  local videos_dir="$1"
  local audios_dir="$2"

  if [[ ! -d "$videos_dir" ]]; then
    echo "Video directory not found: $videos_dir"
    return 2
  fi
  if [[ ! -d "$audios_dir" ]]; then
    echo "Audio directory not found: $audios_dir"
    return 2
  fi

  declare -A audio_by_id=()
  declare -A audio_rank_by_id=()
  while IFS= read -r -d '' audio; do
    local id
    id="$(extract_id "$audio" || true)"
    if [[ -z "${id:-}" ]]; then
      continue
    fi
    local ext rank prev_rank
    ext="$(lower_ext "$audio")"
    rank="$(audio_rank "$ext")"
    prev_rank="${audio_rank_by_id[$id]:-0}"

    if [[ -z "${audio_by_id[$id]+x}" || "$rank" -gt "$prev_rank" ]]; then
      audio_by_id["$id"]="$audio"
      audio_rank_by_id["$id"]="$rank"
    else
      echo "WARN: Duplicate audio ID $id (keeping higher-ranked audio): $audio"
    fi
  done < <(find "$audios_dir" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.wav' \) -print0)

  local jobs running failed
  jobs="${JOBS:-$(nproc)}"
  if [[ -z "${FFMPEG_THREADS:-}" ]]; then
    local cores threads_per_job
    cores="$(nproc)"
    threads_per_job=$(( cores / jobs ))
    if (( threads_per_job < 1 )); then
      threads_per_job=1
    fi
    export FFMPEG_THREADS="$threads_per_job"
  fi
  running=0
  failed=0

  while IFS= read -r -d '' video; do
    local id audio
    id="$(extract_id "$video" || true)"
    if [[ -z "${id:-}" ]]; then
      echo "WARN: No (n) ID found in video filename, skipping: $video"
      continue
    fi
    audio="${audio_by_id[$id]:-}"
    if [[ -z "$audio" ]]; then
      echo "WARN: No matching MP3 for ID $id, skipping video: $video"
      continue
    fi

    process_pair "$audio" "$video" &
    ((running++)) || true

    if (( running >= jobs )); then
      wait -n || failed=1
      ((running--)) || true
    fi
  done < <(find "$videos_dir" -maxdepth 1 -type f -iname '*.mp4' -print0)

  while (( running > 0 )); do
    wait -n || failed=1
    ((running--)) || true
  done

  if (( failed != 0 )); then
    echo "ERROR: One or more ffmpeg jobs failed."
    return 1
  fi
}

if [[ -d "$ARG1" && -d "$ARG2" ]]; then
  d1_mp4="$(find "$ARG1" -maxdepth 1 -type f -iname '*.mp4' -print -quit || true)"
  d1_aud="$(find "$ARG1" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.wav' \) -print -quit || true)"
  d2_mp4="$(find "$ARG2" -maxdepth 1 -type f -iname '*.mp4' -print -quit || true)"
  d2_aud="$(find "$ARG2" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.wav' \) -print -quit || true)"

  videos_dir="$ARG1"
  audios_dir="$ARG2"

  if [[ -z "$d1_mp4" && -n "$d1_aud" && -n "$d2_mp4" && -z "$d2_aud" ]]; then
    videos_dir="$ARG2"
    audios_dir="$ARG1"
  elif [[ -n "$d1_mp4" && -z "$d1_aud" && -z "$d2_mp4" && -n "$d2_aud" ]]; then
    : # ARG1 looks like videos, ARG2 looks like audios (expected order)
  elif [[ -z "$d1_mp4" && -z "$d2_mp4" ]]; then
    echo "WARN: Could not find any MP4s in either directory; assuming ARG1 is videos and ARG2 is audios."
  elif [[ -z "$d1_aud" && -z "$d2_aud" ]]; then
    echo "WARN: Could not find any audio files (mp3/flac/wav) in either directory; assuming ARG1 is videos and ARG2 is audios."
  else
    echo "WARN: Both directories contain MP4 and/or audio; assuming ARG1 is videos and ARG2 is audios."
  fi

  run_batch "$videos_dir" "$audios_dir"
  exit 0
fi

if [[ -f "$ARG1" && -f "$ARG2" ]]; then
  ext1="$(lower_ext "$ARG1")"
  ext2="$(lower_ext "$ARG2")"

  if [[ ( "$ext1" == "mp3" || "$ext1" == "flac" || "$ext1" == "wav" ) && "$ext2" == "mp4" ]]; then
    process_pair "$ARG1" "$ARG2"
    exit 0
  fi
  if [[ "$ext1" == "mp4" && ( "$ext2" == "mp3" || "$ext2" == "flac" || "$ext2" == "wav" ) ]]; then
    process_pair "$ARG2" "$ARG1"
    exit 0
  fi

  echo "Both arguments must be audio(mp3/flac/wav)+mp4 (any order), or both directories."
  exit 1
fi

echo "Arguments must be either two files or two directories."
exit 1

#!/usr/bin/env bash
# Convert recordings into clips the toy likes: mono, 22.05 kHz, 16-bit,
# with a short pad so the very end is not clipped by the I2S buffers.
#
#   tools/prepare_audio.sh sdcard/audio/en ~/recordings/*.m4a
#   tools/prepare_audio.sh --wav sdcard/audio/es bear.wav
#
# Uses ffmpeg when it is installed (better: loudness levelling, MP3 output).
# Falls back to macOS's built-in afconvert, which can only write WAV.
set -euo pipefail

format=mp3
if [[ "${1:-}" == "--wav" ]]; then
  format=wav
  shift
fi

if [[ $# -lt 2 ]]; then
  sed -n '2,9p' "$0"
  exit 1
fi

dest=$1
shift
mkdir -p "$dest"

if command -v ffmpeg >/dev/null 2>&1; then
  engine=ffmpeg
elif command -v afconvert >/dev/null 2>&1; then
  engine=afconvert
  if [[ $format == mp3 ]]; then
    echo "afconvert cannot write MP3. Either:"
    echo "  brew install ffmpeg        (then MP3 works, and clips get levelled)"
    echo "  $0 --wav $dest ...         (WAV plays fine, files are ~5x bigger)"
    exit 1
  fi
else
  echo "Need ffmpeg or afconvert." >&2
  exit 1
fi

for input in "$@"; do
  name=$(basename "${input%.*}")
  # lower case, spaces to dashes: FAT is happier and so are you
  name=$(echo "$name" | tr '[:upper:] ' '[:lower:]-')
  out="$dest/$name.$format"

  if [[ $engine == ffmpeg ]]; then
    if [[ $format == mp3 ]]; then
      codec=(-codec:a libmp3lame -b:a 64k)
    else
      codec=(-codec:a pcm_s16le)
    fi
    ffmpeg -loglevel error -y -i "$input" \
      -af "loudnorm=I=-16:TP=-1.5:LRA=11,apad=pad_dur=0.25" \
      -ac 1 -ar 22050 "${codec[@]}" "$out"
  else
    # LEI16 = little-endian signed 16-bit, the only PCM the decoder accepts
    afconvert -f WAVE -d LEI16@22050 -c 1 "$input" "$out"
  fi

  printf '%s (%s)\n' "$out" "$(du -h "$out" | cut -f1)"
done

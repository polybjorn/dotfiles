#!/bin/zsh
set -euo pipefail

IMPORT_DIR="$HOME/Vault/Camera"
PHOTOS_DIR="$HOME/Vault/Photos"
LOG_FILE="$HOME/Vault/Photos/.photo-sort.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE" }

for file in "$IMPORT_DIR"/*.(jpg|jpeg|png|gif|webp|mp4|mov|heic|heif|dng|raw)(N); do
  [[ "$(basename "$file")" == .syncthing.* ]] && continue

  # skip files modified in the last 60s (may still be syncing)
  file_age=$(( $(date +%s) - $(stat -f '%m' "$file") ))
  [[ "$file_age" -lt 60 ]] && continue

  year=""

  exif_date=$(exiftool -s3 -DateTimeOriginal "$file" 2>/dev/null)
  if [[ -n "$exif_date" ]]; then
    year="${exif_date:0:4}"
  fi

  if [[ -z "$year" ]]; then
    fname=$(basename "$file")
    if [[ "$fname" =~ ^IMG_([0-9]{4}) ]]; then
      year="${match[1]}"
    elif [[ "$fname" =~ ^([0-9]{4}) ]]; then
      year="${match[1]}"
    fi
  fi

  if [[ -z "$year" ]]; then
    mod_date=$(stat -f '%Sm' -t '%Y' "$file" 2>/dev/null)
    [[ -n "$mod_date" ]] && year="$mod_date"
  fi

  if [[ -z "$year" || "$year" -lt 2000 || "$year" -gt 2099 ]]; then
    log "SKIP no valid date: $file"
    continue
  fi

  dest_dir="$PHOTOS_DIR/$year"
  mkdir -p "$dest_dir"

  dest_file="$dest_dir/$(basename "$file")"

  if [[ -f "$dest_file" ]]; then
    src_hash=$(shasum -a 256 "$file" | awk '{print $1}')
    dst_hash=$(shasum -a 256 "$dest_file" | awk '{print $1}')
    if [[ "$src_hash" == "$dst_hash" ]]; then
      log "DEDUP removing duplicate: $(basename "$file")"
      rm "$file"
      continue
    else
      base="${dest_file:r}"
      ext="${dest_file:e}"
      i=1
      while [[ -f "${base}_${i}.${ext}" ]]; do ((i++)); done
      dest_file="${base}_${i}.${ext}"
      log "RENAME collision: $(basename "$file") -> $(basename "$dest_file")"
    fi
  fi

  mv "$file" "$dest_file"
  log "SORTED $(basename "$file") -> $year/"
done

#!/bin/zsh
set -euo pipefail

DOWNLOADS="$HOME/Downloads"
INBOX="$HOME/Vault/Inbox"
LOG="$HOME/Library/Logs/downloads-sort.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG" }

typeset -A ext_map
for ext in stl step stp 3mf f3d obj; do ext_map[$ext]="3D models"; done
for ext in pdf doc docx txt csv xlsx ods; do ext_map[$ext]="Documents"; done
for ext in png jpg jpeg gif webp svg tiff; do ext_map[$ext]="Images"; done

moved=0

for file in "$DOWNLOADS"/*(.N); do
  # skip files modified in the last 60s (may still be downloading)
  file_age=$(( $(date +%s) - $(stat -f '%m' "$file") ))
  [[ "$file_age" -lt 60 ]] && continue

  ext="${file:e:l}"

  # gcode.3mf → treat as 3D model
  if [[ "$file" == *.gcode.3mf ]]; then
    ext="3mf"
  fi

  dest="${ext_map[$ext]:-}"
  [[ -z "$dest" ]] && continue

  dest_dir="$INBOX/$dest"
  fname="$(basename "$file")"

  if [[ -f "$dest_dir/$fname" ]]; then
    log "SKIP (exists): $fname -> $dest"
    continue
  fi

  mv "$file" "$dest_dir/"
  log "MOVED: $fname -> $dest"
  (( moved++ )) || true
done

[[ "$moved" -gt 0 ]] && log "Total moved: $moved"

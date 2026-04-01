#!/bin/bash
set -euo pipefail

WATCH_DIR="/var/www/hiking-map/gpx"
SCRIPT="/usr/local/bin/gpx-manifest.sh"

"$SCRIPT"

inotifywait -m -r -e create,delete,modify,moved_to --include '\.gpx$' "$WATCH_DIR" |
  while read -r; do
    sleep 2
    "$SCRIPT"
  done

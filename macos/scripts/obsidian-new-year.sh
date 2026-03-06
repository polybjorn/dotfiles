#!/bin/zsh
set -euo pipefail

VAULT="$HOME/Vault/Obsidian"
PLUGIN_CONFIG="$VAULT/.obsidian/plugins/periodic-notes/data.json"
YEAR=$(date '+%Y')
YEAR_DIR="$VAULT/Calendar/$YEAR"
YEAR_NOTE="$YEAR_DIR/$YEAR.md"
LOG_FILE="/tmp/obsidian-new-year.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE" }

# Create year folder if needed
if [[ ! -d "$YEAR_DIR" ]]; then
  mkdir -p "$YEAR_DIR"
  log "Created folder: $YEAR_DIR"
else
  log "Folder already exists: $YEAR_DIR"
fi

# Create yearly note if it doesn't exist
if [[ ! -f "$YEAR_NOTE" ]]; then
  cat > "$YEAR_NOTE" << EOF
---
tags:
  - Calendar
hierarchy:
  - "[[Calendar]]"
cssclasses: []
description:
---

- Review
	1. [[$YEAR First quarter review|First quarter]]
	2. [[$YEAR Second quarter review|Second quarter]]
	3. [[$YEAR Third quarter review|Third quarter]]
	4. [[$YEAR Fourth quarter review|Fourth quarter]]

\`\`\`dataview
TABLE WITHOUT ID
  file.link AS "Dates"
FROM "Calendar/$YEAR"
SORT file.link ASC
\`\`\`
EOF
  log "Created yearly note: $YEAR_NOTE"
else
  log "Yearly note already exists: $YEAR_NOTE"
fi

# Update periodic-notes plugin config folders
if [[ -f "$PLUGIN_CONFIG" ]]; then
  # Replace any Calendar/NNNN folder references with current year
  sed -i '' -E "s|\"Calendar/[0-9]{4}\"|\"Calendar/$YEAR\"|g" "$PLUGIN_CONFIG"
  log "Updated periodic-notes config to Calendar/$YEAR"
else
  log "WARNING: Plugin config not found at $PLUGIN_CONFIG"
fi

log "New year rollover complete for $YEAR"

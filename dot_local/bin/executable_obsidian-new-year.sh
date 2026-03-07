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

# Quarterly activity dataviewjs block (shared by all quarterly notes)
read -r -d '' QUARTERLY_DV << 'DVBLOCK' || true
```dataviewjs
const name = dv.current().file.name;
const yearMatch = name.match(/^(\d{4})/);
const year = yearMatch ? parseInt(yearMatch[1]) : dv.date("today").year;

const quarterMap = { "First": [1,3], "Second": [4,6], "Third": [7,9], "Fourth": [10,12] };
let startMonth = 1, endMonth = 3;
for (const [q, [s, e]] of Object.entries(quarterMap)) {
  if (name.includes(q)) { startMonth = s; endMonth = e; break; }
}

const start = dv.date(`${year}-${String(startMonth).padStart(2,'0')}-01`);
const end = dv.date(`${year}-${String(endMonth).padStart(2,'0')}-${endMonth === 2 ? 28 : [4,6,9,11].includes(endMonth) ? 30 : 31}`);

const pages = dv.pages().where(p => p.file.cday >= start && p.file.cday <= end);
const byTag = {};
for (const p of pages) {
  for (const t of (p.tags || [])) {
    byTag[t] = (byTag[t] || 0) + 1;
  }
}
const sorted = Object.entries(byTag).sort((a,b) => b[1]-a[1]).slice(0, 15);
if (sorted.length > 0) {
  dv.paragraph(`**${pages.length} notes created** this quarter`);
  dv.table(["Tag", "Count"], sorted);
} else {
  dv.paragraph(`*No notes created in this period yet*`);
}
```
DVBLOCK

# Monthly activity dataviewjs block (shared by all monthly notes)
read -r -d '' MONTHLY_DV << 'DVBLOCK' || true
```dataviewjs
const name = dv.current().file.name;
const match = name.match(/^(\d{4})-(\d{2})$/);
const year = match ? parseInt(match[1]) : dv.date("today").year;
const month = match ? parseInt(match[2]) : dv.date("today").month;

const start = dv.date(`${year}-${String(month).padStart(2,'0')}-01`);
const end = start.plus({months: 1}).minus({days: 1});

const pages = dv.pages().where(p => p.file.cday >= start && p.file.cday <= end);
const byTag = {};
for (const p of pages) {
  for (const t of (p.tags || [])) {
    byTag[t] = (byTag[t] || 0) + 1;
  }
}
const sorted = Object.entries(byTag).sort((a,b) => b[1]-a[1]).slice(0, 10);
if (sorted.length > 0) {
  dv.paragraph(`**${pages.length} notes created** this month`);
  dv.table(["Tag", "Count"], sorted);
} else {
  dv.paragraph(`*No notes created this month yet*`);
}
```
DVBLOCK

# Create quarterly notes with monthly links
typeset -A QUARTER_MONTHS
QUARTER_MONTHS=(
  "First"  "01 02 03"
  "Second" "04 05 06"
  "Third"  "07 08 09"
  "Fourth" "10 11 12"
)

for QNAME in First Second Third Fourth; do
  QFILE="$YEAR_DIR/$YEAR ${QNAME} quarter review.md"
  if [[ ! -f "$QFILE" ]]; then
    MONTHS=(${=QUARTER_MONTHS[$QNAME]})
    MONTH_LINKS="[[$YEAR-${MONTHS[1]}]] · [[$YEAR-${MONTHS[2]}]] · [[$YEAR-${MONTHS[3]}]]"
    cat > "$QFILE" << QEOF
---
tags:
  - Calendar
hierarchy:
  - "[[$YEAR]]"
description:
---
↖ [[$YEAR]] 🗓️

## Monthly notes
$MONTH_LINKS

## Review


## Activity
$QUARTERLY_DV

## Goals
QEOF
    log "Created quarterly note: $YEAR ${QNAME} quarter review"
  else
    log "Quarterly note already exists: $YEAR ${QNAME} quarter review"
  fi
done

# Create monthly notes
for MONTH in $(seq -w 1 12); do
  MFILE="$YEAR_DIR/$YEAR-${MONTH}.md"
  if [[ ! -f "$MFILE" ]]; then
    cat > "$MFILE" << MEOF
---
tags:
  - Calendar
hierarchy:
  - "[[$YEAR]]"
cssclasses: []
description:
---
↖ [[$YEAR]] 🗓️

## Review


## Activity
$MONTHLY_DV
MEOF
    log "Created monthly note: $YEAR-${MONTH}"
  else
    log "Monthly note already exists: $YEAR-${MONTH}"
  fi
done

# Update periodic-notes plugin config folders
if [[ -f "$PLUGIN_CONFIG" ]]; then
  sed -i '' -E "s|\"Calendar/[0-9]{4}\"|\"Calendar/$YEAR\"|g" "$PLUGIN_CONFIG"
  log "Updated periodic-notes config to Calendar/$YEAR"
else
  log "WARNING: Plugin config not found at $PLUGIN_CONFIG"
fi

log "New year rollover complete for $YEAR"

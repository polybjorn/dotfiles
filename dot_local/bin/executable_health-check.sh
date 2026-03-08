#!/bin/bash
# Health check — alerts via ntfy only when something is wrong

[[ -f "$HOME/.config/dotfiles/env" ]] && source "$HOME/.config/dotfiles/env"

NTFY_URL="${NTFY_URL:-https://localhost:2587}/mac-alerts"
HOST=$(hostname -s)
PI_HOST="${PI_HOST:-admin@pi-server}"

alert() {
  local priority="$1" title="$2" tags="$3" body="$4"
  curl -s -o /dev/null \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    -d "$(echo -e "From: health-check (daily 08:00)\n\n$body")" \
    "$NTFY_URL"
}

# --- Disk space (Data volume) ---
DISK_PCT=$(df /System/Volumes/Data 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}')
if [ -n "$DISK_PCT" ] && [ "$DISK_PCT" -gt 85 ]; then
  alert "high" "Disk Space Low" "floppy_disk,warning" \
    "Data volume at ${DISK_PCT}% on $HOST"
fi

# --- Memory pressure ---
MEM_LEVEL=$(memory_pressure 2>/dev/null | grep "System-wide memory free percentage" | awk '{print $NF}' | tr -d '%')
if [ -n "$MEM_LEVEL" ] && [ "$MEM_LEVEL" -lt 15 ]; then
  alert "high" "Memory Pressure" "brain,warning" \
    "Only ${MEM_LEVEL}% memory free on $HOST"
fi

# --- Key services ---
DEAD_SERVICES=""

if ! pgrep -qi "docker" 2>/dev/null; then
  DEAD_SERVICES="${DEAD_SERVICES}- Docker\n"
fi

if ! pgrep -qif "syncthing" 2>/dev/null; then
  DEAD_SERVICES="${DEAD_SERVICES}- Syncthing\n"
fi

if ! pgrep -qi "tailscale" 2>/dev/null; then
  DEAD_SERVICES="${DEAD_SERVICES}- Tailscale\n"
fi

if [ -n "$DEAD_SERVICES" ]; then
  alert "high" "Service(s) Down" "skull,warning" \
    "$(echo -e "Dead services on $HOST:\n$DEAD_SERVICES")"
fi

# --- Brew outdated casks ---
OUTDATED=$(/opt/homebrew/bin/brew outdated --cask --quiet 2>/dev/null)
if [ -n "$OUTDATED" ]; then
  COUNT=$(echo "$OUTDATED" | wc -l | tr -d ' ')
  alert "default" "Brew Updates Available" "package,info" \
    "$(echo -e "${COUNT} outdated cask(s) on $HOST:\n$OUTDATED")"
fi

# --- LaunchAgent jobs ---
DEAD_JOBS=""
for label in \
  local.backup-claude \
  local.photo-sort \
  local.backup \
  local.health-check \
  local.stats-push \
  local.pkg-maintenance \
  local.backup-verify \
  local.obsidian-weekly-note \
  local.obsidian-new-year \
  ; do
  # Paused until vault cleanup is done:
  # local.vault-maintenance-weekly
  # local.vault-maintenance-monthly
  if ! launchctl list "$label" &>/dev/null; then
    DEAD_JOBS="${DEAD_JOBS}- $label\n"
  fi
done

if [ -n "$DEAD_JOBS" ]; then
  alert "high" "LaunchAgent(s) Not Loaded" "gear,warning" \
    "$(echo -e "Unloaded jobs on $HOST:\n$DEAD_JOBS")"
fi

# --- Git pre-commit hook ---
HOOK="$HOME/.config/git/hooks/pre-commit"
PII="$HOME/.config/git/pii-patterns"
if [ ! -x "$HOOK" ]; then
  alert "high" "Pre-commit Hook Missing" "lock,warning" \
    "Global pre-commit hook not found or not executable on $HOST"
elif [ ! -f "$PII" ]; then
  alert "default" "PII Patterns Missing" "lock,info" \
    "PII patterns file not found on $HOST — run chezmoi apply"
fi

# --- Mac backup freshness ---
BACKUP_DIR="$HOME/Vault/Backups/$HOST"
HOUR=$(date +%H)
if [ "$HOUR" -ge 4 ]; then
  EXPECTED_BACKUP="$BACKUP_DIR/$(date +%Y-%m-%d).tar.gz"
else
  EXPECTED_BACKUP="$BACKUP_DIR/$(date -v-1d +%Y-%m-%d).tar.gz"
fi
if [ ! -f "$EXPECTED_BACKUP" ]; then
  alert "high" "Mac Backup Missing" "file_folder,warning" \
    "Expected backup not found: $(basename "$EXPECTED_BACKUP") on $HOST"
elif [ "$(stat -f%z "$EXPECTED_BACKUP")" -lt 10240 ]; then
  alert "high" "Mac Backup Too Small" "file_folder,warning" \
    "Backup $(basename "$EXPECTED_BACKUP") is under 10KB on $HOST"
fi

# --- Syncthing folder health ---
ST_API="http://localhost:8384"
ST_CONFIG="$HOME/Library/Application Support/Syncthing/config.xml"
ST_KEY=$(sed -n 's/.*<apikey>\([^<]*\)<.*/\1/p' "$ST_CONFIG" 2>/dev/null)

if [ -n "$ST_KEY" ] && curl -s --max-time 3 "$ST_API/rest/system/status" -H "X-API-Key: $ST_KEY" >/dev/null 2>&1; then
  ST_PROBLEMS=""
  ST_WATCH=""
  while IFS='|' read -r folder_id folder_label; do
    STATUS=$(curl -s --max-time 5 -H "X-API-Key: $ST_KEY" \
      "$ST_API/rest/db/status?folder=$folder_id" 2>/dev/null)
    [ -z "$STATUS" ] && continue
    echo "$STATUS" | jq empty 2>/dev/null || continue
    _st=$(echo "$STATUS" | jq -r '.state // ""')
    _er=$(echo "$STATUS" | jq -r '.errors // 0')
    _pe=$(echo "$STATUS" | jq -r '.pullErrors // 0')
    _we=$(echo "$STATUS" | jq -r '.watchError // ""')
    _em=$(echo "$STATUS" | jq -r '.error // ""')
    if [ "$_st" = "error" ]; then
      ST_PROBLEMS="${ST_PROBLEMS}- $folder_label: ${_em:-error state}\n"
    fi
    [ "$_er" -gt 0 ] 2>/dev/null && \
      ST_PROBLEMS="${ST_PROBLEMS}- $folder_label: $_er sync error(s)\n"
    [ "$_pe" -gt 0 ] 2>/dev/null && \
      ST_PROBLEMS="${ST_PROBLEMS}- $folder_label: $_pe pull error(s)\n"
    [ -n "$_we" ] && \
      ST_WATCH="${ST_WATCH}- $folder_label: $_we\n"
  done < <(sed -n 's/.*folder id="\([^"]*\)".*label="\([^"]*\)".*/\1|\2/p' "$ST_CONFIG")
  if [ -n "$ST_PROBLEMS" ]; then
    alert "high" "Syncthing Folder Error" "arrows_counterclockwise,warning" \
      "$(echo -e "Syncthing issues on $HOST:\n$ST_PROBLEMS")"
  fi
  if [ -n "$ST_WATCH" ]; then
    alert "default" "Syncthing Watch Error" "arrows_counterclockwise,warning" \
      "$(echo -e "FS watch issues on $HOST:\n$ST_WATCH")"
  fi
fi

# --- Pi services (via SSH, skip if unreachable) ---
if ssh -o ConnectTimeout=5 -o BatchMode=yes "$PI_HOST" true 2>/dev/null; then
  PI_DOWN=""
  for svc in nginx ntfy syncthing@admin stats-api cloudflared tailscaled radicale mariadb; do
    STATUS=$(ssh "$PI_HOST" "systemctl is-active $svc 2>/dev/null" 2>/dev/null)
    if [ "$STATUS" != "active" ]; then
      PI_DOWN="${PI_DOWN}- $svc ($STATUS)\n"
    fi
  done

  if [ -n "$PI_DOWN" ]; then
    alert "high" "Pi Service(s) Down" "skull,warning" \
      "$(echo -e "Dead services on pi-server:\n$PI_DOWN")"
  fi

  # Check key Pi timers ran recently
  PI_STALE=""
  for timer in health-check backup freshrss-refresh; do
    LAST=$(ssh "$PI_HOST" "systemctl show ${timer}.timer -p LastTriggerUSec --value 2>/dev/null" 2>/dev/null)
    if [ -z "$LAST" ] || [ "$LAST" = "n/a" ]; then
      PI_STALE="${PI_STALE}- ${timer}.timer (never triggered)\n"
    fi
  done

  if [ -n "$PI_STALE" ]; then
    alert "default" "Pi Timer(s) Stale" "hourglass_flowing_sand,warning" \
      "$(echo -e "Timers with no recent trigger on pi-server:\n$PI_STALE")"
  fi
fi

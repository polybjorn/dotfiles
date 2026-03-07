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
    -d "$body" \
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
  com.bjanda.backup-claude \
  com.bjanda.photo-sort \
  com.bjanda.backup \
  com.bjanda.health-check \
  com.bjanda.stats-push \
  com.bjanda.pkg-maintenance \
  com.bjanda.obsidian-weekly-note \
  com.bjanda.obsidian-new-year; do
  if ! launchctl list "$label" &>/dev/null; then
    DEAD_JOBS="${DEAD_JOBS}- $label\n"
  fi
done

if [ -n "$DEAD_JOBS" ]; then
  alert "high" "LaunchAgent(s) Not Loaded" "gear,warning" \
    "$(echo -e "Unloaded jobs on $HOST:\n$DEAD_JOBS")"
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

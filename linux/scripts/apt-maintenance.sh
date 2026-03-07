#!/bin/bash
# Apt maintenance — update, upgrade, cleanup
# Runs weekly via systemd timer; sends ntfy summary

set -euo pipefail

NTFY_URL="http://localhost:2586/pi-alerts"
HOST=$(hostname)
LOG=""

notify() {
  local priority="$1" title="$2" tags="$3" body="$4"
  curl -s -o /dev/null     -H "Title: $title"     -H "Priority: $priority"     -H "Tags: $tags"     -d "$body"     "$NTFY_URL"
}

trap 'notify "high" "Apt Maintenance Failed" "rotating_light,warning" "apt-maintenance.sh failed on $HOST (line $LINENO)"' ERR

echo "=== Apt maintenance started: $(date) ==="

# --- Update package lists ---
echo "Updating package lists..."
apt-get update -qq

# --- Check for upgradable packages ---
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v '^Listing' || true)
if [ -n "$UPGRADABLE" ]; then
  echo "Upgrading packages..."
  apt-get upgrade -y -qq
  LOG="${LOG}Upgraded: $(echo "$UPGRADABLE" | wc -l | tr -d ' ') package(s)\n"
  LOG="${LOG}$(echo "$UPGRADABLE" | cut -d/ -f1 | tr '\n' ', ' | sed 's/, $//')\n"
fi

# --- Autoremove ---
AUTOREMOVE=$(apt-get autoremove --dry-run 2>/dev/null | grep '^Remv' || true)
if [ -n "$AUTOREMOVE" ]; then
  echo "Removing unused packages..."
  apt-get autoremove -y -qq
  LOG="${LOG}Autoremoved: $(echo "$AUTOREMOVE" | wc -l | tr -d ' ') package(s)\n"
fi

# --- Clean cache ---
apt-get clean -qq

# --- Summary ---
if [ -z "$LOG" ]; then
  LOG="Everything up to date."
fi

notify "default" "Apt Maintenance" "package,white_check_mark"   "$(echo -e "Maintenance complete on $HOST:\n$LOG")"

echo "=== Apt maintenance complete ==="

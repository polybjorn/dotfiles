#!/bin/bash
# Package maintenance — update, upgrade, cleanup
# Cross-platform: brew on macOS, pacman on Arch, apt on Debian
# Runs weekly via launchd/systemd; sends ntfy summary

set -euo pipefail

[[ -f "$HOME/.config/dotfiles/env" ]] && source "$HOME/.config/dotfiles/env"

HOST=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
LOG=""

if [[ "$OSTYPE" == darwin* ]]; then
  NTFY="${NTFY_URL:-https://localhost:2587}/mac-alerts"
else
  NTFY="${NTFY_URL:-http://localhost:2586}/pi-alerts"
fi

notify() {
  local priority="$1" title="$2" tags="$3" body="$4"
  curl -s -o /dev/null \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    -d "$body" \
    "$NTFY"
}

trap 'notify "high" "Package Maintenance Failed" "rotating_light,warning" "From: pkg-maintenance (weekly Sun 09:00)\n\npkg-maintenance.sh failed on $HOST (line $LINENO)"' ERR

echo "=== Package maintenance started: $(date) ==="

if [[ "$OSTYPE" == darwin* ]]; then
  BREW="/opt/homebrew/bin/brew"
  REPO_BREWFILE="$HOME/repositories/dotfiles/Brewfile"

  # --- Update ---
  echo "Updating brew..."
  $BREW update --quiet

  # --- Upgrade formulae ---
  OUTDATED_FORMULAE=$($BREW outdated --formula --quiet 2>/dev/null || true)
  if [ -n "$OUTDATED_FORMULAE" ]; then
    echo "Upgrading formulae..."
    $BREW upgrade --formula --quiet
    LOG="${LOG}Upgraded formulae: $(echo "$OUTDATED_FORMULAE" | tr '\n' ', ' | sed 's/, $//')\n"
  fi

  # --- Upgrade casks ---
  OUTDATED_CASKS=$($BREW outdated --cask --quiet 2>/dev/null || true)
  if [ -n "$OUTDATED_CASKS" ]; then
    echo "Upgrading casks..."
    $BREW upgrade --cask --quiet
    LOG="${LOG}Upgraded casks: $(echo "$OUTDATED_CASKS" | tr '\n' ', ' | sed 's/, $//')\n"
  fi

  # --- Cleanup ---
  echo "Cleaning up..."
  $BREW cleanup --prune=7 -s --quiet 2>/dev/null || true

  # --- Trim log files ---
  for logfile in "$HOME"/Library/Logs/{backup,backup-verify,health-check,pkg-maintenance,photo-sort,stats-push,obsidian-new-year,obsidian-weekly-note}.log; do
    if [ -f "$logfile" ] && [ "$(wc -l < "$logfile")" -gt 500 ]; then
      tail -200 "$logfile" > "$logfile.tmp" && mv "$logfile.tmp" "$logfile"
    fi
  done

  # --- Re-dump Brewfile ---
  echo "Updating Brewfile..."
  $BREW bundle dump --file="$REPO_BREWFILE" --force --quiet

elif command -v pacman &>/dev/null; then
  # --- Sync database + upgrade ---
  echo "Updating pacman database..."
  pacman -Sy --noconfirm --quiet

  OUTDATED=$(pacman -Qu 2>/dev/null || true)
  if [ -n "$OUTDATED" ]; then
    echo "Upgrading packages..."
    pacman -Su --noconfirm --quiet
    COUNT=$(echo "$OUTDATED" | wc -l | tr -d ' ')
    NAMES=$(echo "$OUTDATED" | awk '{print $1}' | tr '\n' ', ' | sed 's/, $//')
    LOG="${LOG}Upgraded: ${COUNT} package(s)\n${NAMES}\n"
  fi

  # --- Remove orphans ---
  ORPHANS=$(pacman -Qdtq 2>/dev/null || true)
  if [ -n "$ORPHANS" ]; then
    echo "Removing orphan packages..."
    pacman -Rns --noconfirm $ORPHANS
    LOG="${LOG}Removed orphans: $(echo "$ORPHANS" | tr '\n' ', ' | sed 's/, $//')\n"
  fi

  # --- Clean package cache (keep last 2 versions) ---
  if command -v paccache &>/dev/null; then
    echo "Cleaning package cache..."
    paccache -rk2 --quiet
  fi

else
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
fi

# --- Summary ---
if [ -z "$LOG" ]; then
  LOG="Everything up to date."
fi

notify "default" "Package Maintenance" "package,white_check_mark,calendar" \
  "$(echo -e "Scheduled: weekly (Sun 09:00)\n\nMaintenance complete on $HOST:\n$LOG")"

echo "=== Package maintenance complete ==="

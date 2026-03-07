#!/bin/bash
# Brew maintenance — update, upgrade, cleanup, re-dump Brewfile
# Runs weekly via launchd; sends ntfy summary

set -euo pipefail

[[ -f "$HOME/.config/dotfiles/env" ]] && source "$HOME/.config/dotfiles/env"

BREW="/opt/homebrew/bin/brew"
REPO_BREWFILE="$HOME/repositories/dotfiles/Brewfile"
NTFY_URL="${NTFY_URL:-https://localhost:2587}/mac-alerts"
HOST=$(hostname -s)
LOG=""

notify() {
  local priority="$1" title="$2" tags="$3" body="$4"
  curl -s -o /dev/null \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    -d "$body" \
    "$NTFY_URL"
}

trap 'notify "high" "Brew Maintenance Failed" "rotating_light,warning" "brew-maintenance.sh failed on $HOST (line $LINENO)"' ERR

echo "=== Brew maintenance started: $(date) ==="

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

# --- Re-dump Brewfile ---
echo "Updating Brewfile..."
$BREW bundle dump --file="$REPO_BREWFILE" --force --quiet

# --- Summary ---
if [ -z "$LOG" ]; then
  LOG="Everything up to date."
fi

notify "default" "Brew Maintenance" "beer,white_check_mark" \
  "$(echo -e "Maintenance complete on $HOST:\n$LOG")"

echo "=== Brew maintenance complete ==="

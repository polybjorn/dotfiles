#!/bin/bash
# Batched FreshRSS feed actualization
# Runs frequently via systemd timer, fetching a small batch each time.
# FreshRSS prioritizes the most stale feeds automatically.
set -euo pipefail

MAX_FEEDS="${1:-15}"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

sudo -u www-data php "$SCRIPT_DIR/freshrss-fetch.php" "$MAX_FEEDS"

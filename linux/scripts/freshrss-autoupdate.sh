#!/bin/bash
# Auto-update whitelisted services when FreshRSS detects a new release.
# Only acts on safe, git-based services. Tracks state to avoid re-running.
# Post-update patches are re-applied via freshrss-patch.sh.
set -euo pipefail

DB="/var/www/FreshRSS/data/users/freshrss/db.sqlite"
NTFY_URL="http://localhost:2586/pi-alerts"
STATE_DIR="/var/lib/freshrss-autoupdate"
STATE_FILE="$STATE_DIR/state"
PATCH_SCRIPT="$(dirname "$(readlink -f "$0")")/freshrss-patch.sh"

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

extract_version() {
  local ver
  ver=$(grep -oP '\d+\.\d+\.\d+' <<< "$1" | head -1)
  if [ -z "$ver" ]; then
    ver=$(grep -oP '\d{4}-\d{2}-\d{2}' <<< "$1" | head -1)
  fi
  echo "$ver"
}

get_local_version() {
  case "$1" in
    FreshRSS)    grep FRESHRSS_VERSION /var/www/FreshRSS/constants.php 2>/dev/null ;;
    RSS-Bridge)  git -C /var/www/rss-bridge describe --tags --abbrev=0 2>/dev/null ;;
  esac
}

get_latest_version() {
  sqlite3 "$DB" "
    SELECT e.title FROM entry e
    JOIN feed f ON e.id_feed = f.id
    WHERE f.name = '$1'
      AND f.category = (SELECT id FROM category WHERE name = 'Self-hosted')
      AND e.title NOT LIKE '%beta%' AND e.title NOT LIKE '%-rc.%'
      AND e.title NOT LIKE '%-exp.%' AND e.title NOT LIKE 'develop-%'
      AND e.title NOT LIKE 'Development release%' AND e.title NOT LIKE '%alpha%'
    ORDER BY e.date DESC LIMIT 1;
  " 2>/dev/null || true
}

update_service() {
  case "$1" in
    RSS-Bridge)
      cd /var/www/rss-bridge
      sudo -u www-data git fetch --tags --quiet
      local latest_tag
      latest_tag=$(git tag --sort=-v:refname | head -1)
      sudo -u www-data git checkout "$latest_tag" --quiet
      "$PATCH_SCRIPT"
      ;;
    FreshRSS)
      cd /var/www/FreshRSS
      sudo -u www-data git pull --quiet
      sudo -u www-data php cli/do-install.php > /dev/null 2>&1
      "$PATCH_SCRIPT"
      ;;
    *) return 1 ;;
  esac
}

updated=""
for service in "RSS-Bridge" "FreshRSS"; do
  local_raw=$(get_local_version "$service") || true
  [ -z "$local_raw" ] && continue
  local_ver=$(extract_version "$local_raw") || true
  [ -z "$local_ver" ] && continue

  latest_title=$(get_latest_version "$service")
  [ -z "$latest_title" ] && continue
  latest_ver=$(extract_version "$latest_title") || true
  [ -z "$latest_ver" ] && continue

  [ "$local_ver" = "$latest_ver" ] && continue

  prev=$(grep "^${service}=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2) || true
  [ "$prev" = "$latest_ver" ] && continue

  if update_service "$service"; then
    sed -i "/^${service}=/d" "$STATE_FILE"
    echo "${service}=${latest_ver}" >> "$STATE_FILE"
    updated+="• $service: $local_ver → $latest_ver"$'\n'
  fi
done

if [ -n "$updated" ]; then
  curl -s -o /dev/null \
    -H "Title: Services auto-updated" \
    -H "Tags: arrow_up,wrench" \
    -d "$(echo -e "From: freshrss-autoupdate\n\n$updated")" \
    "$NTFY_URL"
fi

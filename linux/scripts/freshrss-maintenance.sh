#!/bin/bash
# Nightly FreshRSS & RSS-Bridge maintenance:
#   1. Clean stale RSS-Bridge cache
#   2. Auto-update FreshRSS & RSS-Bridge if new release
#   3. Refresh YouTube channel avatars (1st of month only)
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
DB="/var/www/FreshRSS/data/users/freshrss/db.sqlite"
NTFY_URL="http://localhost:2586/pi-alerts"

# ── Clear stale feed errors ─────────────────────────────

cleared=$(sqlite3 "$DB" "UPDATE feed SET error = 0 WHERE error = 1; SELECT changes();")
if [ "$cleared" -gt 0 ]; then
  echo "Cleared error flag on $cleared feed(s)"
fi

# ── RSS-Bridge cache cleanup ─────────────────────────────

CACHE_DIR="/var/www/rss-bridge/cache"
if [ -d "$CACHE_DIR" ]; then
  count=$(find "$CACHE_DIR" -name '*.cache' -mmin +1440 | wc -l)
  find "$CACHE_DIR" -name '*.cache' -mmin +1440 -delete
  echo "Cache cleanup: removed $count stale files"
fi

# ── Auto-update whitelisted services ─────────────────────

STATE_DIR="/var/lib/freshrss-autoupdate"
STATE_FILE="$STATE_DIR/state"
PATCH_SCRIPT="$SCRIPT_DIR/freshrss-patch.sh"

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
  if ! printf '%s\n' "$local_ver" "$latest_ver" | sort -V | tail -1 | grep -qx "$latest_ver"; then
    continue
  fi

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
    -d "$(echo -e "From: freshrss-maintenance\n\n$updated")" \
    "$NTFY_URL"
fi

# ── YouTube favicons (1st of month only) ─────────────────

if [ "$(date +%d)" = "01" ]; then
  echo "1st of month — refreshing YouTube favicons"

  SALT=$(grep -oP "'salt'\s*=>\s*'\K[^']+" /var/www/FreshRSS/data/config.php)
  USERNAME="freshrss"
  FAVICONS_DIR="/var/www/FreshRSS/data/favicons"

  sqlite3 "$DB" "SELECT id, website FROM feed WHERE url LIKE '%YoutubeBridge%' OR (url LIKE '%FilterBridge%' AND url LIKE '%YoutubeBridge%');" | while IFS='|' read -r feed_id website; do
    hash=$(php -r "echo hash('crc32b', '${SALT}${feed_id}${USERNAME}');")
    ico_path="${FAVICONS_DIR}/${hash}.ico"

    [ -z "$website" ] && continue

    avatar_url=$(curl -sL --max-time 10 "$website" 2>/dev/null | grep -oP '"avatar":\{"thumbnails":\[\{"url":"\K[^"]+' | head -1) || true
    [ -z "$avatar_url" ] && continue

    if curl -sL --max-time 10 "$avatar_url" -o "$ico_path" 2>/dev/null; then
      sqlite3 "$DB" "UPDATE feed SET attributes = json_set(COALESCE(attributes, '{}'), '$.customFavicon', json('true')) WHERE id = $feed_id;"
    else
      rm -f "$ico_path"
    fi

    sleep 1
  done

  chown -R www-data:www-data "$FAVICONS_DIR"
  echo "YouTube favicon refresh complete"
fi

echo "Maintenance complete"

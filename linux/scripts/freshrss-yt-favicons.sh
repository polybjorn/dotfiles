#!/bin/bash
# Download YouTube channel avatars as FreshRSS custom favicons
# Runs monthly to catch avatar changes
set -euo pipefail

SALT=$(grep -oP "'salt'\s*=>\s*'\K[^']+" /var/www/FreshRSS/data/config.php)
USERNAME="freshrss"
DB="/var/www/FreshRSS/data/users/freshrss/db.sqlite"
FAVICONS_DIR="/var/www/FreshRSS/data/favicons"

ok=0
fail=0

sqlite3 "$DB" "SELECT id, website FROM feed WHERE url LIKE '%YoutubeBridge%' OR (url LIKE '%FilterBridge%' AND url LIKE '%YoutubeBridge%');" | while IFS='|' read -r feed_id website; do
    hash=$(php -r "echo hash('crc32b', '${SALT}${feed_id}${USERNAME}');")
    ico_path="${FAVICONS_DIR}/${hash}.ico"

    if [ -z "$website" ]; then
        continue
    fi

    avatar_url=$(curl -sL --max-time 10 "$website" 2>/dev/null | grep -oP '"avatar":\{"thumbnails":\[\{"url":"\K[^"]+' | head -1) || true

    if [ -z "$avatar_url" ]; then
        echo "FAIL $feed_id — no avatar found"
        continue
    fi

    if curl -sL --max-time 10 "$avatar_url" -o "$ico_path" 2>/dev/null; then
        sqlite3 "$DB" "UPDATE feed SET attributes = json_set(COALESCE(attributes, '{}'), '\$.customFavicon', json('true')) WHERE id = $feed_id;"
    else
        rm -f "$ico_path"
    fi

    sleep 1
done

chown -R www-data:www-data "$FAVICONS_DIR"
echo "YouTube favicon refresh complete"

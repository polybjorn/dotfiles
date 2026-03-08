#!/bin/bash
# Weekly FreshRSS digest:
#   1. New releases in Self-hosted category
#   2. Version check for locally installed services
#   3. Stale or erroring feeds
#   4. OPML drift detection (feeds vs repo)
# Sends summaries to ntfy

set -euo pipefail

DB="/var/www/FreshRSS/data/users/freshrss/db.sqlite"
NTFY_URL="http://localhost:2586/pi-alerts"
REPO_OPML="$(dirname "$(readlink -f "$0")")/../config/freshrss-feeds.opml"
SINCE=$(date -d '7 days ago' +%s)
STALE_DAYS=90
STALE_SINCE=$(date -d "$STALE_DAYS days ago" +%s)

# --- Self-hosted release digest ---

releases=$(sqlite3 "$DB" "
    SELECT f.name, e.title
    FROM entry e
    JOIN feed f ON e.id_feed = f.id
    WHERE f.category IN (SELECT id FROM category WHERE name IN ('Self-hosted', 'Desktop software'))
      AND e.date >= $SINCE
    ORDER BY f.name, e.date DESC;
") || true

if [ -n "$releases" ]; then
    grouped=$(sqlite3 "$DB" "
        SELECT f.name, COUNT(*) as cnt,
            (SELECT e2.title FROM entry e2 WHERE e2.id_feed = f.id AND e2.date >= $SINCE ORDER BY e2.date DESC LIMIT 1) as latest
        FROM entry e
        JOIN feed f ON e.id_feed = f.id
        WHERE f.category IN (SELECT id FROM category WHERE name IN ('Self-hosted', 'Desktop software'))
          AND e.date >= $SINCE
        GROUP BY f.name
        ORDER BY f.name;
    ")

    body=""
    total=0
    while IFS='|' read -r service count title; do
        total=$((total + 1))
        if [ "$count" -eq 1 ]; then
            body+="• $service: $title"$'\n'
        else
            body+="• $service ($count releases): $title"$'\n'
        fi
    done <<< "$grouped"

    body="${total} service(s) with new releases this week:"$'\n\n'"$body"

    curl -s -o /dev/null \
        -H "Title: Software release digest" \
        -H "Tags: package,calendar" \
        -d "$(echo -e "Scheduled: weekly (Mon 08:00)\n\n$body")" \
        "$NTFY_URL"
fi

# --- Version check for local services ---

extract_version() {
    local input="$1"
    # Try semver first, then date-based (YYYY-MM-DD)
    local ver
    ver=$(grep -oP '\d+\.\d+\.\d+' <<< "$input" | head -1)
    if [ -z "$ver" ]; then
        ver=$(grep -oP '\d{4}-\d{2}-\d{2}' <<< "$input" | head -1)
    fi
    echo "$ver"
}

get_local_version() {
    case "$1" in
        GoToSocial)    /opt/gotosocial/gotosocial --version 2>/dev/null ;;
        headscale)     headscale version 2>/dev/null ;;
        FreshRSS)      grep FRESHRSS_VERSION /var/www/FreshRSS/constants.php 2>/dev/null ;;
        Radicale)      /opt/radicale/bin/radicale --version 2>/dev/null ;;
        "Firefly III") grep "'version'" /var/www/firefly-iii/config/firefly.php 2>/dev/null ;;
        RSS-Bridge)    git -C /var/www/rss-bridge describe --tags --abbrev=0 2>/dev/null ;;
    esac
}

outdated=""
up_to_date=0
for service in "GoToSocial" "headscale" "FreshRSS" "Radicale" "Firefly III" "RSS-Bridge"; do
    local_raw=$(get_local_version "$service") || true
    [ -z "$local_raw" ] && continue
    local_ver=$(extract_version "$local_raw") || true
    [ -z "$local_ver" ] && continue

    latest_title=$(sqlite3 "$DB" "
        SELECT e.title FROM entry e
        JOIN feed f ON e.id_feed = f.id
        WHERE f.name = '$service'
          AND f.category = (SELECT id FROM category WHERE name = 'Self-hosted')
          AND e.title NOT LIKE '%beta%' AND e.title NOT LIKE '%-rc.%'
          AND e.title NOT LIKE '%-exp.%' AND e.title NOT LIKE 'develop-%'
          AND e.title NOT LIKE 'Development release%' AND e.title NOT LIKE '%alpha%'
          AND e.title NOT LIKE 'n8n@%'
        ORDER BY e.date DESC LIMIT 1;
    ") || true
    [ -z "$latest_title" ] && continue
    latest_ver=$(extract_version "$latest_title") || true
    [ -z "$latest_ver" ] && continue

    if [ "$local_ver" != "$latest_ver" ]; then
        outdated+="• $service: $local_ver → $latest_ver"$'\n'
    else
        up_to_date=$((up_to_date + 1))
    fi
done

if [ -n "$outdated" ]; then
    ver_body="Updates available:"$'\n\n'"$outdated"
    [ "$up_to_date" -gt 0 ] && ver_body+=$'\n'"$up_to_date service(s) up to date"
    curl -s -o /dev/null \
        -H "Title: Services behind latest release" \
        -H "Tags: arrow_up,calendar" \
        -d "$(echo -e "Scheduled: weekly (Mon 08:00)\n\n$ver_body")" \
        "$NTFY_URL"
fi

# --- Stale and erroring feeds ---

problems=$(sqlite3 "$DB" "
    SELECT f.name,
        CASE WHEN f.error = 1 THEN 'error' ELSE 'stale' END as status,
        CAST((strftime('%s','now') - f.lastUpdate) / 86400 AS INT) as days_ago
    FROM feed f
    WHERE f.error = 1 OR f.lastUpdate < $STALE_SINCE
    ORDER BY status, f.name;
") || true

if [ -n "$problems" ]; then
    msg=""
    while IFS='|' read -r name status days; do
        if [ "$status" = "error" ]; then
            msg+="• $name (fetch error)"$'\n'
        else
            msg+="• $name (no updates in ${days}d)"$'\n'
        fi
    done <<< "$problems"

    curl -s -o /dev/null \
        -H "Title: FreshRSS feed problems" \
        -H "Tags: warning,calendar" \
        -d "$(echo -e "Scheduled: weekly (Mon 08:00)\n\n$msg")" \
        "$NTFY_URL"
fi

# --- OPML drift detection ---

if [ -f "$REPO_OPML" ]; then
    extract_urls() { grep -oP 'xmlUrl="\K[^"]+' "$1" | sort; }
    LIVE_OPML=$(mktemp)
    sudo -u www-data php /var/www/FreshRSS/cli/export-opml-for-user.php --user freshrss > "$LIVE_OPML" 2>/dev/null
    added=$(comm -13 <(extract_urls "$REPO_OPML") <(extract_urls "$LIVE_OPML")) || true
    removed=$(comm -23 <(extract_urls "$REPO_OPML") <(extract_urls "$LIVE_OPML")) || true
    rm -f "$LIVE_OPML"

    if [ -n "$added" ] || [ -n "$removed" ]; then
        drift="FreshRSS feeds differ from repo OPML:"
        [ -n "$added" ] && drift+=$'\n\nAdded:\n'"$(echo "$added" | sed 's/^/+ /')"
        [ -n "$removed" ] && drift+=$'\n\nRemoved:\n'"$(echo "$removed" | sed 's/^/- /')"
        drift+=$'\n\nUpdate repo: cd ~/repositories/dotfiles && sudo -u www-data php /var/www/FreshRSS/cli/export-opml-for-user.php --user freshrss > linux/config/freshrss-feeds.opml'
        curl -s -o /dev/null \
            -H "Title: FreshRSS feed drift detected" \
            -H "Tags: warning,calendar" \
            -d "$(echo -e "Scheduled: weekly (Mon 08:00)\n\n$drift")" \
            "$NTFY_URL"
    fi
fi

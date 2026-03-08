#!/bin/bash
# Re-apply manual FreshRSS patches that get overwritten on update.
# Called by health-check; safe to run repeatedly (idempotent).
set -euo pipefail

NTFY_URL="http://localhost:2586/pi-alerts"
NORD_CSS="/var/www/FreshRSS/p/themes/Nord/nord.css"
NORD_RTL="/var/www/FreshRSS/p/themes/Nord/nord.rtl.css"
YT_BRIDGE="/var/www/rss-bridge/bridges/YoutubeBridge.php"

fixed=()

# --- Nord theme: remove favicon background, make circular ---
for css in "$NORD_CSS" "$NORD_RTL"; do
    [ -f "$css" ] || continue
    if grep -q 'img\.favicon' "$css" 2>/dev/null; then
        if grep -A1 'img\.favicon' "$css" | grep -q 'background: var(--text-accent)'; then
            sed -i '/img\.favicon/,/^}/{s/background: var(--text-accent);/background: none;/;s/border-radius: 4px;/border-radius: 50%;/}' "$css"
            fixed+=("$(basename "$css") favicon style")
        fi
    fi
done

# --- RSS-Bridge: increase YoutubeBridge cache TTL to 6 hours ---
if [ -f "$YT_BRIDGE" ] && grep -q 'CACHE_TIMEOUT = 60 \* 60 \* 3' "$YT_BRIDGE" 2>/dev/null; then
    sed -i "s/CACHE_TIMEOUT = 60 \* 60 \* 3;.*/CACHE_TIMEOUT = 60 * 60 * 6; \/\/ 6 hours/" "$YT_BRIDGE"
    fixed+=("YoutubeBridge cache TTL")
fi

if [ ${#fixed[@]} -gt 0 ]; then
    msg="Auto-patched after FreshRSS update: ${fixed[*]}"
    echo "$msg"
    curl -s -o /dev/null \
        -H "Title: FreshRSS patches reapplied" \
        -H "Tags: wrench" \
        -d "$(echo -e "From: freshrss-patch (on health-check)\n\n$msg")" \
        "$NTFY_URL"
fi

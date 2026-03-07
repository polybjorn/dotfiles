#!/bin/bash
# Re-apply manual FreshRSS patches that get overwritten on update.
# Called by health-check; safe to run repeatedly (idempotent).
set -euo pipefail

NTFY_URL="http://localhost:2586/pi-alerts"
MAIN_JS="/var/www/FreshRSS/p/scripts/main.js"
NORD_CSS="/var/www/FreshRSS/p/themes/Nord/nord.css"
NORD_RTL="/var/www/FreshRSS/p/themes/Nord/nord.rtl.css"
YT_BRIDGE="/var/www/rss-bridge/bridges/YoutubeBridge.php"

fixed=()

# --- Favicon: detect RFP (Resist Fingerprinting) and skip canvas replacement ---
# Browsers with RFP (LibreWolf, Firefox+arkenfox) corrupt canvas.toDataURL()
# output, producing a striped/garbled favicon. FreshRSS doesn't detect this and
# replaces the good static favicon with corrupted data. This patch adds a pixel
# verification check: draw a known color, read it back, and only proceed if it
# matches. If RFP is active, the read-back will be randomized and the static
# favicon is preserved.
if grep -q "link.href = canvas.toDataURL('image/png');" "$MAIN_JS" 2>/dev/null; then
    if ! grep -q "RFP canvas detection" "$MAIN_JS" 2>/dev/null; then
        sed -i "/link\.href = canvas\.toDataURL('image\/png');/i\\
\\t\\t\\t// RFP canvas detection: verify canvas data is not corrupted\\
\\t\\t\\tconst testCanvas = document.createElement('canvas');\\
\\t\\t\\ttestCanvas.width = testCanvas.height = 1;\\
\\t\\t\\tconst testCtx = testCanvas.getContext('2d');\\
\\t\\t\\ttestCtx.fillStyle = '#FF0000';\\
\\t\\t\\ttestCtx.fillRect(0, 0, 1, 1);\\
\\t\\t\\tconst p = testCtx.getImageData(0, 0, 1, 1).data;\\
\\t\\t\\tif (p[0] !== 255 || p[1] !== 0 || p[2] !== 0) return;" "$MAIN_JS"
        fixed+=("main.js RFP favicon detection")
    fi
fi

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
        -d "$msg" \
        "$NTFY_URL"
fi

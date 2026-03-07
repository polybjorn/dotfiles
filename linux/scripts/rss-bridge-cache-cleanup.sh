#!/bin/bash
# Clean RSS-Bridge cache files older than 24 hours
set -euo pipefail

CACHE_DIR="/var/www/rss-bridge/cache"

if [ ! -d "$CACHE_DIR" ]; then
    echo "Cache directory not found: $CACHE_DIR"
    exit 1
fi

count=$(find "$CACHE_DIR" -name '*.cache' -mmin +1440 | wc -l)
find "$CACHE_DIR" -name '*.cache' -mmin +1440 -delete
echo "Cleaned $count stale cache files"

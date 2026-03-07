#!/bin/bash
# nightmode.sh — Disable/enable nginx sites to save resources overnight.
# Usage: nightmode.sh on|off <site1> [site2] ...
#   on  = disable sites (enter night mode)
#   off = re-enable sites (exit night mode)
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: nightmode.sh on|off <site1> [site2] ..."
    exit 1
fi

ACTION="$1"; shift

case "$ACTION" in
    on)
        for site in "$@"; do
            rm -f "/etc/nginx/sites-enabled/$site"
        done
        systemctl reload nginx
        ;;
    off)
        for site in "$@"; do
            ln -sf "/etc/nginx/sites-available/$site" "/etc/nginx/sites-enabled/$site"
        done
        systemctl reload nginx
        ;;
    *)
        echo "Unknown action: $ACTION (use on or off)"
        exit 1
        ;;
esac

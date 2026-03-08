#!/bin/bash
# WiFi watchdog — reconnects WiFi if it drops and alerts via ntfy
# Designed to run frequently via systemd timer (every 2 min)
set -euo pipefail

NTFY_URL="http://localhost:2586/pi-alerts"
HOST=$(hostname)
IFACE="wlan0"

alert() {
    local priority="$1" title="$2" tags="$3" body="$4"
    curl -s -o /dev/null \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: $tags" \
        -d "$(echo -e "From: wifi-watchdog (every 2m)\n\n$body")" \
        "$NTFY_URL"
}

# Check if wlan0 has a working IP and can reach the gateway
WIFI_STATE=$(nmcli -t -f GENERAL.STATE device show "$IFACE" 2>/dev/null | cut -d: -f2 || echo "")

if [[ "$WIFI_STATE" == *"connected"* ]]; then
    # WiFi is connected, verify we can reach the gateway
    GW=$(ip route show dev "$IFACE" | awk '/default/{print $3}' | head -1)
    if [ -n "$GW" ] && ping -c 1 -W 3 -I "$IFACE" "$GW" >/dev/null 2>&1; then
        exit 0  # All good
    fi
fi

# WiFi is down or unreachable — attempt recovery
logger -t wifi-watchdog "WiFi down on $IFACE, attempting reconnect"

# Try the preferred 5GHz first, fall back to 2.4GHz
RECONNECTED=false
for CONN in "Amundsen 5" "Amundsen 2.4"; do
    if nmcli connection up "$CONN" 2>/dev/null; then
        sleep 5
        GW=$(ip route show dev "$IFACE" | awk '/default/{print $3}' | head -1)
        if [ -n "$GW" ] && ping -c 1 -W 3 -I "$IFACE" "$GW" >/dev/null 2>&1; then
            RECONNECTED=true
            logger -t wifi-watchdog "Reconnected via $CONN"
            alert "default" "WiFi Reconnected" "wifi,white_check_mark" \
                "WiFi recovered on $HOST via $CONN"
            break
        fi
    fi
done

if [ "$RECONNECTED" = false ]; then
    logger -t wifi-watchdog "WiFi recovery FAILED on $IFACE"
    alert "urgent" "WiFi Down — Cannot Recover" "wifi,skull" \
        "WiFi is unreachable on $HOST. All reconnect attempts failed. Physical access may be needed."
fi

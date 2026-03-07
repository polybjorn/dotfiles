#!/bin/bash
# Health check — alerts via ntfy only when something is wrong
# All checks are read-only and near-instant (<1s total)

NTFY_URL="http://localhost:2586/pi-alerts"
SCRIPT_OWNER="$(stat -c "%U" "$(readlink -f "$0")")"
USER_HOME="$(getent passwd "$SCRIPT_OWNER" | cut -d: -f6)"
HOST=$(hostname)

alert() {
    local priority="$1" title="$2" tags="$3" body="$4"
    curl -s -o /dev/null \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: $tags" \
        -d "$body" \
        "$NTFY_URL"
}

# --- Undervoltage / throttling (Pi-specific, most important) ---
THROTTLED=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
if [ -n "$THROTTLED" ] && [ "$THROTTLED" != "0x0" ]; then
    REASONS=""
    (( 0x$THROTTLED & 0x1 ))     && REASONS="${REASONS}- Under-voltage detected\n"
    (( 0x$THROTTLED & 0x2 ))     && REASONS="${REASONS}- ARM frequency capped\n"
    (( 0x$THROTTLED & 0x4 ))     && REASONS="${REASONS}- Currently throttled\n"
    (( 0x$THROTTLED & 0x8 ))     && REASONS="${REASONS}- Soft temperature limit\n"
    (( 0x$THROTTLED & 0x10000 )) && REASONS="${REASONS}- Under-voltage has occurred\n"
    (( 0x$THROTTLED & 0x20000 )) && REASONS="${REASONS}- ARM frequency capping has occurred\n"
    (( 0x$THROTTLED & 0x40000 )) && REASONS="${REASONS}- Throttling has occurred\n"
    (( 0x$THROTTLED & 0x80000 )) && REASONS="${REASONS}- Soft temperature limit has occurred\n"
    alert "urgent" "Power/Throttle Warning" "zap,warning" \
        "$(echo -e "Throttle flags: $THROTTLED on $HOST\n$REASONS")"
fi

# --- CPU temperature ---
CPU_TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9]+\.[0-9]+' | cut -d. -f1)
if [ -n "$CPU_TEMP" ] && [ "$CPU_TEMP" -gt 75 ]; then
    alert "high" "CPU Temperature High" "thermometer,warning" \
        "CPU at ${CPU_TEMP}C on $HOST"
fi

# --- Disk space (root partition) ---
DISK_PCT=$(df / 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}')
if [ -n "$DISK_PCT" ] && [ "$DISK_PCT" -gt 85 ]; then
    alert "high" "Disk Space Low" "floppy_disk,warning" \
        "Root filesystem at ${DISK_PCT}% on $HOST"
fi

# --- Memory ---
MEM_AVAIL_MB=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
if [ -n "$MEM_AVAIL_MB" ] && [ "$MEM_AVAIL_MB" -lt 200 ]; then
    alert "default" "Memory Low" "brain,warning" \
        "Only ${MEM_AVAIL_MB}MB available on $HOST"
fi

# --- Reboot required ---
if [ -f /var/run/reboot-required ]; then
    REBOOT_PKGS=""
    if [ -f /var/run/reboot-required.pkgs ]; then
        REBOOT_PKGS="\nPackages: $(cat /var/run/reboot-required.pkgs | tr "\n" ", " | sed "s/, $//")"
    fi
    alert "high" "Reboot Required" "arrows_counterclockwise,warning" \
        "$(echo -e "Reboot needed on $HOST$REBOOT_PKGS")"
fi

# --- Key services ---
DEAD_SERVICES=""
for svc in nginx mariadb cloudflared syncthing@admin ntfy tailscaled; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        : # running, fine
    elif systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
        DEAD_SERVICES="${DEAD_SERVICES}- $svc\n"
    fi
done
if [ -n "$DEAD_SERVICES" ]; then
    alert "high" "Service(s) Down" "skull,warning" \
        "$(echo -e "Dead services on $HOST:\n$DEAD_SERVICES")"
fi

# --- SSD SMART ---
SMART_PROBLEMS=""
HEALTH=$(smartctl -H /dev/sda 2>&1 | grep "overall-health" | awk '{print $NF}')
if [ -z "$HEALTH" ]; then
    sleep 2
    HEALTH=$(smartctl -H /dev/sda 2>&1 | grep "overall-health" | awk '{print $NF}')
fi
if [ -z "$HEALTH" ]; then
    SMART_PROBLEMS="${SMART_PROBLEMS}- Cannot read SMART (drive missing?)\n"
elif [ "$HEALTH" != "PASSED" ]; then
    SMART_PROBLEMS="${SMART_PROBLEMS}- SMART health: $HEALTH\n"
fi

ATTRS=$(smartctl -A /dev/sda 2>&1)
LIFE_LEFT=$(echo "$ATTRS" | awk '/SSD_Life_Left/{print $NF}')
[ -n "$LIFE_LEFT" ] && [ "$LIFE_LEFT" -lt 20 ] 2>/dev/null && \
    SMART_PROBLEMS="${SMART_PROBLEMS}- SSD life: ${LIFE_LEFT}%\n"
REALLOC=$(echo "$ATTRS" | awk '/Reallocated_Event_Count/{print $NF}')
[ -n "$REALLOC" ] && [ "$REALLOC" -gt 0 ] 2>/dev/null && \
    SMART_PROBLEMS="${SMART_PROBLEMS}- Reallocated sectors: $REALLOC\n"
UNCORRECT=$(echo "$ATTRS" | awk '/Reported_Uncorrect/{print $NF}')
[ -n "$UNCORRECT" ] && [ "$UNCORRECT" -gt 0 ] 2>/dev/null && \
    SMART_PROBLEMS="${SMART_PROBLEMS}- Uncorrectable errors: $UNCORRECT\n"

if [ -n "$SMART_PROBLEMS" ]; then
    alert "high" "SSD Health Warning" "floppy_disk,warning" \
        "$(echo -e "SSD issues on $HOST:\n$SMART_PROBLEMS")"
fi

# --- Network connectivity ---
NET_PROBLEMS=""
# WiFi interface
WIFI_STATE=$(nmcli -t -f GENERAL.STATE device show wlan0 2>/dev/null | cut -d: -f2 || echo "")
if [[ ! "$WIFI_STATE" == *"connected"* ]]; then
    NET_PROBLEMS="${NET_PROBLEMS}- WiFi (wlan0) not connected\n"
fi
# DNS resolution (retry with fallback to avoid transient false positives)
dns_ok=false
for target in google.com cloudflare.com; do
    if getent hosts "$target" >/dev/null 2>&1; then
        dns_ok=true
        break
    fi
    sleep 2
done
if ! $dns_ok; then
    NET_PROBLEMS="${NET_PROBLEMS}- DNS resolution failed\n"
fi
# Tailscale
if ! tailscale status >/dev/null 2>&1; then
    NET_PROBLEMS="${NET_PROBLEMS}- Tailscale not running\n"
fi
if [ -n "$NET_PROBLEMS" ]; then
    alert "high" "Network Issue" "globe_with_meridians,warning" \
        "$(echo -e "Network issues on $HOST:\n$NET_PROBLEMS")"
fi

# --- Backup freshness ---
BACKUP_DIR="$USER_HOME/backups/$HOST"
HOUR=$(date +%H)
if [ "$HOUR" -ge 3 ]; then
    EXPECTED_BACKUP="$BACKUP_DIR/$(date +%Y-%m-%d).tar.gz"
else
    EXPECTED_BACKUP="$BACKUP_DIR/$(date -d yesterday +%Y-%m-%d).tar.gz"
fi
if [ ! -f "$EXPECTED_BACKUP" ]; then
    alert "high" "Backup Missing" "file_folder,warning" \
        "Expected backup not found: $(basename "$EXPECTED_BACKUP") on $HOST"
elif [ $(stat -c%s "$EXPECTED_BACKUP") -lt 1048576 ]; then
    alert "high" "Backup Too Small" "file_folder,warning" \
        "Backup $(basename "$EXPECTED_BACKUP") is under 1MB on $HOST"
fi

# --- CLAUDE.md backup staleness ---
CLAUDE_BACKUP="$USER_HOME/Vault/Backups/mac-claude/CLAUDE.md"
if [ -f "$CLAUDE_BACKUP" ]; then
    CLAUDE_AGE_DAYS=$(( ($(date +%s) - $(stat -c%Y "$CLAUDE_BACKUP")) / 86400 ))
    if [ "$CLAUDE_AGE_DAYS" -gt 7 ]; then
        alert "default" "CLAUDE.md Backup Stale" "memo,warning" \
            "CLAUDE.md backup is ${CLAUDE_AGE_DAYS} days old on $HOST (Mac not syncing?)"
    fi
elif [ -d "$USER_HOME/Vault/Backups/mac-claude" ]; then
    alert "default" "CLAUDE.md Backup Missing" "memo,warning" \
        "CLAUDE.md backup file not found in mac-claude/ on $HOST"
fi

# --- Syncthing folder health ---
ST_API="http://localhost:8384"
ST_KEY=$(grep -oP '(?<=<apikey>)[^<]+' $USER_HOME/.local/state/syncthing/config.xml 2>/dev/null)
if [ -n "$ST_KEY" ] && curl -s --max-time 3 "$ST_API/rest/system/status" -H "X-API-Key: $ST_KEY" >/dev/null 2>&1; then
    ST_PROBLEMS=""
    ST_WATCH=""
    while IFS='|' read -r folder_id folder_label; do
        STATUS=$(curl -s --max-time 5 -H "X-API-Key: $ST_KEY" \
            "$ST_API/rest/db/status?folder=$folder_id" 2>/dev/null)
        [ -z "$STATUS" ] && continue
        eval "$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
# shell-safe: single-quote values, escape inner quotes
def q(v): return str(v).replace(\"'\",\"'\\\"'\\\"'\")
print(f\"_st='{q(d.get('state',''))}'\")
print(f\"_er={d.get('errors',0)}\")
print(f\"_pe={d.get('pullErrors',0)}\")
print(f\"_we='{q(d.get('watchError',''))}'\")
print(f\"_em='{q(d.get('error',''))}'\")
" <<< "$STATUS" 2>/dev/null)"
        if [ "$_st" = "error" ]; then
            ST_PROBLEMS="${ST_PROBLEMS}- $folder_label: ${_em:-error state}\n"
        fi
        [ "${_er:-0}" -gt 0 ] 2>/dev/null && \
            ST_PROBLEMS="${ST_PROBLEMS}- $folder_label: $_er sync error(s)\n"
        [ "${_pe:-0}" -gt 0 ] 2>/dev/null && \
            ST_PROBLEMS="${ST_PROBLEMS}- $folder_label: $_pe pull error(s)\n"
        [ -n "$_we" ] && \
            ST_WATCH="${ST_WATCH}- $folder_label: $_we\n"
    done < <(grep -oP 'folder id="\K[^"]+\"\s+label="[^"]+' \
        $USER_HOME/.local/state/syncthing/config.xml \
        | sed 's/" *label="/|/')
    if [ -n "$ST_PROBLEMS" ]; then
        alert "high" "Syncthing Folder Error" "arrows_counterclockwise,warning" \
            "$(echo -e "Syncthing issues on $HOST:\n$ST_PROBLEMS")"
    fi
    if [ -n "$ST_WATCH" ]; then
        alert "default" "Syncthing Watch Error" "arrows_counterclockwise,warning" \
            "$(echo -e "FS watch issues on $HOST:\n$ST_WATCH")"
    fi
fi

# --- FreshRSS patches (auto-fix if overwritten by update) ---
/usr/local/bin/freshrss-patch.sh 2>/dev/null || true

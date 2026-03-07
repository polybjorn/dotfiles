#!/bin/bash
# Collect stats and push to Pi dashboard

[[ -f "$HOME/.config/dotfiles/env" ]] && source "$HOME/.config/dotfiles/env"

PI_HOST="${PI_HOST:-admin@pi-server}"
PI_PATH="/var/www/pi-dashboard/mac-stats.json"
TMP="/tmp/mac-stats.json"
HOST=$(hostname -s)

# --- Disk (full APFS container, reported as marketed 512 GB) ---
DISK_USED_B=$(diskutil apfs list 2>/dev/null | awk '/Capacity In Use By Volumes/{for(i=1;i<=NF;i++) if($i~/^[0-9]+$/ && $(i+1)=="B") {print $i; exit}}')
DISK_TOTAL=512
DISK_USED_B=${DISK_USED_B:-0}
DISK_USED=$((DISK_USED_B / 1073741824))
DISK_PCT=$((DISK_USED * 100 / DISK_TOTAL))

# --- Memory ---
PAGE_SIZE=$(sysctl -n hw.pagesize)
MEM_TOTAL=$(sysctl -n hw.memsize)
MEM_TOTAL_MB=$((MEM_TOTAL / 1048576))
VM=$(vm_stat 2>/dev/null)
PAGES_FREE=$(echo "$VM" | awk '/Pages free/{gsub(/\./,""); print $3}')
PAGES_INACTIVE=$(echo "$VM" | awk '/Pages inactive/{gsub(/\./,""); print $3}')
PAGES_SPECULATIVE=$(echo "$VM" | awk '/Pages speculative/{gsub(/\./,""); print $3}')
PAGES_PURGEABLE=$(echo "$VM" | awk '/Pages purgeable/{gsub(/\./,""); print $3}')
MEM_AVAIL=$(( (PAGES_FREE + PAGES_INACTIVE + PAGES_SPECULATIVE + PAGES_PURGEABLE) * PAGE_SIZE / 1048576 ))
MEM_USED=$((MEM_TOTAL_MB - MEM_AVAIL))

# --- Uptime ---
BOOT=$(sysctl -n kern.boottime | awk '{gsub(/[^0-9]/," "); print $1}')
NOW=$(date +%s)
UP_SEC=$((NOW - BOOT))
UP_DAYS=$((UP_SEC / 86400))
UP_HOURS=$(( (UP_SEC % 86400) / 3600 ))
UP_MIN=$(( (UP_SEC % 3600) / 60 ))
if [ "$UP_DAYS" -gt 0 ]; then
  UPTIME="${UP_DAYS}d ${UP_HOURS}h"
elif [ "$UP_HOURS" -gt 0 ]; then
  UPTIME="${UP_HOURS}h ${UP_MIN}m"
else
  UPTIME="${UP_MIN}m"
fi

# --- CPU ---
NCPU=$(sysctl -n hw.ncpu)
CPU_PCT=$(ps -A -o %cpu | awk -v n="$NCPU" '{s+=$1} END {printf "%.1f", s/n}')

# --- Services ---
pgrep -qi "docker" 2>/dev/null && SVC_DOCKER=true || SVC_DOCKER=false
pgrep -qif "syncthing" 2>/dev/null && SVC_SYNCTHING=true || SVC_SYNCTHING=false
pgrep -qi "tailscale" 2>/dev/null && SVC_TAILSCALE=true || SVC_TAILSCALE=false

# --- Backup ---
BACKUP_DIR="$HOME/Vault/Backups/$HOST"
BK_AGE=null
BK_SIZE=null
BK_COUNT=0
LATEST_BK=$(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1)
if [ -n "$LATEST_BK" ]; then
  BK_EPOCH=$(stat -f %m "$LATEST_BK")
  BK_AGE=$(( (NOW - BK_EPOCH) / 3600 ))
  BK_SIZE_BYTES=$(stat -f %z "$LATEST_BK")
  if [ "$BK_SIZE_BYTES" -ge 1048576 ]; then
    BK_SIZE="\"$(echo "$BK_SIZE_BYTES" | awk '{printf "%.0f MB", $1/1048576}')\""
  else
    BK_SIZE="\"$(echo "$BK_SIZE_BYTES" | awk '{printf "%.0f KB", $1/1024}')\""
  fi
  BK_COUNT=$(ls "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
fi

# --- Write JSON ---
cat > "$TMP" << EOF
{
  "hostname": "$HOST",
  "timestamp": $NOW,
  "cpu": $CPU_PCT,
  "disk": {"used": $DISK_USED, "total": $DISK_TOTAL, "pct": $DISK_PCT},
  "mem": {"used": $MEM_USED, "total": $MEM_TOTAL_MB},
  "uptime": "$UPTIME",
  "services": {
    "docker": $SVC_DOCKER,
    "syncthing": $SVC_SYNCTHING,
    "tailscale": $SVC_TAILSCALE
  },
  "backup": {"age_hours": $BK_AGE, "size": $BK_SIZE, "count": $BK_COUNT}
}
EOF

# --- Push to Pi ---
scp -q "$TMP" "$PI_HOST:$PI_PATH" 2>/dev/null

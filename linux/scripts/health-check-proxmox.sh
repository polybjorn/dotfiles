#!/bin/bash
# Health check for Proxmox host — alerts via ntfy only when something is wrong
# All checks are read-only and near-instant

set -euo pipefail

HOST=$(hostname)
USER_HOME="$(eval echo ~"$(whoami)")"

ENV_FILE="$USER_HOME/.config/dotfiles/env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi
NTFY_URL="${NTFY_URL:+$NTFY_URL/proxmox-alerts}"

alert() {
  local priority="$1" title="$2" tags="$3" body="$4"
  [ -z "$NTFY_URL" ] && return
  curl -s -o /dev/null \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    -d "$(echo -e "From: health-check-proxmox (every 4h)\n\n$body")" \
    "$NTFY_URL" || true
}

# --- Disk space ---
for mount in / /mnt/tank; do
  if mountpoint -q "$mount" 2>/dev/null || [ "$mount" = "/" ]; then
    DISK_PCT=$(df "$mount" 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}')
    if [ -n "$DISK_PCT" ] && [ "$DISK_PCT" -gt 85 ]; then
      alert "high" "Disk Space Low" "floppy_disk,warning" \
        "$mount at ${DISK_PCT}% on $HOST"
    fi
  fi
done

# --- ZFS pool health ---
if command -v zpool >/dev/null 2>&1; then
  POOL_STATE=$(zpool status tank 2>/dev/null | awk '/state:/{print $2}')
  if [ -n "$POOL_STATE" ] && [ "$POOL_STATE" != "ONLINE" ]; then
    alert "urgent" "ZFS Pool Degraded" "warning,rotating_light" \
      "ZFS pool 'tank' is $POOL_STATE on $HOST"
  fi
  POOL_ERRORS=$(zpool status tank 2>/dev/null | awk '/errors:/{$1=""; print}' | xargs)
  if [ -n "$POOL_ERRORS" ] && [ "$POOL_ERRORS" != "No known data errors" ]; then
    alert "high" "ZFS Pool Errors" "warning,floppy_disk" \
      "ZFS pool 'tank' errors on $HOST: $POOL_ERRORS"
  fi
fi

# --- Mount points ---
if ! mountpoint -q /mnt/tank 2>/dev/null; then
  alert "urgent" "Mount Point Missing" "file_folder,warning" \
    "/mnt/tank not mounted on $HOST"
fi

# --- Memory ---
MEM_AVAIL_MB=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
if [ -n "$MEM_AVAIL_MB" ] && [ "$MEM_AVAIL_MB" -lt 500 ]; then
  alert "high" "Memory Low" "brain,warning" \
    "Only ${MEM_AVAIL_MB}MB available on $HOST"
fi

# --- CPU temperature ---
TEMP_FILE=""
for f in /sys/class/thermal/thermal_zone*/temp; do
  [ -f "$f" ] && TEMP_FILE="$f" && break
done
if [ -n "$TEMP_FILE" ]; then
  CPU_TEMP=$(($(cat "$TEMP_FILE") / 1000))
  if [ "$CPU_TEMP" -gt 80 ]; then
    alert "high" "CPU Temperature High" "thermometer,warning" \
      "CPU at ${CPU_TEMP}°C on $HOST"
  fi
fi

# --- Key services ---
DEAD_SERVICES=""
for svc in pvedaemon pveproxy pvestatd tailscaled; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    :
  elif systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
    DEAD_SERVICES="${DEAD_SERVICES}- $svc\n"
  fi
done
if [ -n "$DEAD_SERVICES" ]; then
  alert "high" "Service(s) Down" "skull,warning" \
    "$(echo -e "Dead services on $HOST:\n$DEAD_SERVICES")"
fi

# --- LXC containers ---
LXC_DOWN=""
for ct in 102; do
  if command -v pct >/dev/null 2>&1; then
    STATUS=$(pct status "$ct" 2>/dev/null | awk '{print $2}')
    if [ -n "$STATUS" ] && [ "$STATUS" != "running" ]; then
      LXC_DOWN="${LXC_DOWN}- CT $ct ($STATUS)\n"
    fi
  fi
done
if [ -n "$LXC_DOWN" ]; then
  alert "high" "LXC Container(s) Down" "package,warning" \
    "$(echo -e "Stopped containers on $HOST:\n$LXC_DOWN")"
fi

# --- VM ---
if command -v qm >/dev/null 2>&1; then
  VM_STATUS=$(qm status 101 2>/dev/null | awk '{print $2}')
  if [ -n "$VM_STATUS" ] && [ "$VM_STATUS" != "running" ]; then
    alert "default" "VM Not Running" "desktop_computer,information_source" \
      "VM 101 is $VM_STATUS on $HOST"
  fi
fi

# --- Network ---
if ! tailscale status >/dev/null 2>&1; then
  alert "high" "Network Issue" "globe_with_meridians,warning" \
    "Tailscale not running on $HOST"
fi

WIFI_IF=""
for iface in wlo1 wlan0; do
  if [ -d "/sys/class/net/$iface" ]; then
    WIFI_IF="$iface"
    break
  fi
done
if [ -n "$WIFI_IF" ]; then
  WIFI_STATE=$(cat "/sys/class/net/$WIFI_IF/operstate" 2>/dev/null)
  if [ "$WIFI_STATE" != "up" ]; then
    alert "high" "WiFi Down" "globe_with_meridians,warning" \
      "WiFi interface $WIFI_IF is $WIFI_STATE on $HOST"
  fi
fi

# --- Failed SSH logins (last 4h) ---
FAILED_LOGINS=$(journalctl _SYSTEMD_UNIT=sshd.service _SYSTEMD_UNIT=ssh.service \
  --since "4 hours ago" --no-pager -q 2>/dev/null \
  | grep -c "Failed password\|Invalid user\|authentication failure" || true)
if [ "${FAILED_LOGINS:-0}" -gt 10 ]; then
  alert "high" "SSH Login Attempts" "lock,warning" \
    "$FAILED_LOGINS failed SSH login attempts in last 4h on $HOST"
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
elif [ "$(stat -c%s "$EXPECTED_BACKUP")" -lt 1024 ]; then
  alert "high" "Backup Too Small" "file_folder,warning" \
    "Backup $(basename "$EXPECTED_BACKUP") is under 1KB on $HOST"
fi

#!/bin/bash
# Health check for arch-server (LXC) — alerts via ntfy only when something is wrong
# All checks are read-only and near-instant

set -euo pipefail

HOST=$(hostname)
SCRIPT_OWNER="$(stat -c "%U" "$(readlink -f "$0")")"
USER_HOME="$(getent passwd "$SCRIPT_OWNER" | cut -d: -f6)"

ENV_FILE="$USER_HOME/.config/dotfiles/env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi
NTFY_URL="${NTFY_URL:+$NTFY_URL/arch-server-alerts}"

alert() {
  local priority="$1" title="$2" tags="$3" body="$4"
  [ -z "$NTFY_URL" ] && return
  curl -s -o /dev/null \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    -d "$(echo -e "From: health-check-arch (every 4h)\n\n$body")" \
    "$NTFY_URL" || true
}

# --- Disk space ---
for mount in / /mnt/tank /mnt/seedbox; do
  if mountpoint -q "$mount" 2>/dev/null || [ "$mount" = "/" ]; then
    DISK_PCT=$(df "$mount" 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}')
    if [ -n "$DISK_PCT" ] && [ "$DISK_PCT" -gt 85 ]; then
      alert "high" "Disk Space Low" "floppy_disk,warning" \
        "$mount at ${DISK_PCT}% on $HOST"
    fi
  fi
done

# --- Mount points ---
MOUNT_PROBLEMS=""
for mount in /mnt/tank /mnt/seedbox; do
  if ! mountpoint -q "$mount" 2>/dev/null; then
    MOUNT_PROBLEMS="${MOUNT_PROBLEMS}- $mount not mounted\n"
  fi
done
if [ -n "$MOUNT_PROBLEMS" ]; then
  alert "urgent" "Mount Point Missing" "file_folder,warning" \
    "$(echo -e "Missing mounts on $HOST:\n$MOUNT_PROBLEMS")"
fi

# --- Memory ---
MEM_AVAIL_MB=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
if [ -n "$MEM_AVAIL_MB" ] && [ "$MEM_AVAIL_MB" -lt 500 ]; then
  alert "high" "Memory Low" "brain,warning" \
    "Only ${MEM_AVAIL_MB}MB available on $HOST"
fi

# --- Key services (always-on infra only, not scheduled services) ---
DEAD_SERVICES=""
for svc in tailscaled syncthing@admin postgresql docker navidrome; do
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

# --- Docker containers ---
if command -v docker >/dev/null 2>&1; then
  UNHEALTHY=$(docker ps --filter "health=unhealthy" --format "{{.Names}}" 2>/dev/null)
  if [ -n "$UNHEALTHY" ]; then
    alert "high" "Unhealthy Container(s)" "whale,warning" \
      "$(echo -e "Unhealthy Docker containers on $HOST:\n$UNHEALTHY")"
  fi
fi

# --- Network (Tailscale) ---
if ! tailscale status >/dev/null 2>&1; then
  alert "high" "Network Issue" "globe_with_meridians,warning" \
    "Tailscale not running on $HOST"
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
if [ "$HOUR" -ge 4 ]; then
  EXPECTED_BACKUP="$BACKUP_DIR/$(date +%Y-%m-%d).tar.gz"
else
  EXPECTED_BACKUP="$BACKUP_DIR/$(date -d yesterday +%Y-%m-%d).tar.gz"
fi
if [ ! -f "$EXPECTED_BACKUP" ]; then
  alert "high" "Backup Missing" "file_folder,warning" \
    "Expected backup not found: $(basename "$EXPECTED_BACKUP") on $HOST"
elif [ "$(stat -c%s "$EXPECTED_BACKUP")" -lt 1048576 ]; then
  alert "high" "Backup Too Small" "file_folder,warning" \
    "Backup $(basename "$EXPECTED_BACKUP") is under 1MB on $HOST"
fi

# --- Syncthing folder health ---
ST_API="http://localhost:8384"
ST_KEY=$(grep -oP '(?<=<apikey>)[^<]+' "$USER_HOME/.local/state/syncthing/config.xml" 2>/dev/null || true)
if [ -n "$ST_KEY" ] && curl -s --max-time 3 "$ST_API/rest/system/status" -H "X-API-Key: $ST_KEY" >/dev/null 2>&1; then
  ST_PROBLEMS=""
  while IFS='|' read -r folder_id folder_label; do
    STATUS=$(curl -s --max-time 5 -H "X-API-Key: $ST_KEY" \
      "$ST_API/rest/db/status?folder=$folder_id" 2>/dev/null)
    [ -z "$STATUS" ] && continue
    eval "$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
def q(v): return str(v).replace(\"'\",\"'\\\"'\\\"'\")
print(f\"_st='{q(d.get('state',''))}'\")
print(f\"_er={d.get('errors',0)}\")
print(f\"_pe={d.get('pullErrors',0)}\")
print(f\"_em='{q(d.get('error',''))}'\")
" <<< "$STATUS" 2>/dev/null)"
    if [ "$_st" = "error" ]; then
      ST_PROBLEMS="${ST_PROBLEMS}- $folder_label: ${_em:-error state}\n"
    fi
    [ "${_er:-0}" -gt 0 ] 2>/dev/null && \
      ST_PROBLEMS="${ST_PROBLEMS}- $folder_label: $_er sync error(s)\n"
    [ "${_pe:-0}" -gt 0 ] 2>/dev/null && \
      ST_PROBLEMS="${ST_PROBLEMS}- $folder_label: $_pe pull error(s)\n"
  done < <(grep -oP 'folder id="\K[^"]+"\s+label="[^"]+' \
    "$USER_HOME/.local/state/syncthing/config.xml" \
    | sed 's/" *label="/|/')
  if [ -n "$ST_PROBLEMS" ]; then
    alert "high" "Syncthing Folder Error" "arrows_counterclockwise,warning" \
      "$(echo -e "Syncthing issues on $HOST:\n$ST_PROBLEMS")"
  fi
fi

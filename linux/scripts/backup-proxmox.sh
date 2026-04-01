#!/bin/bash
# Proxmox host backup — copies configs + ZFS metadata into a dated tarball
# Stored locally + SCP to arch-server for Syncthing offsite sync
# Sends ntfy alert on failure only

set -euo pipefail

HOST=$(hostname)
USER_HOME="$(eval echo ~"$(whoami)")"
BACKUP_DIR="$USER_HOME/backups/$HOST"
RETENTION_DAYS=7
DATE=$(date +%F)
WORK_DIR="$BACKUP_DIR/$DATE"

ARCH_HOST="${ARCH_HOST:-admin@arch-server}"
SYNC_DIR_REMOTE="/home/admin/Vault/Backups/$HOST"

ENV_FILE="$USER_HOME/.config/dotfiles/env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi
NTFY_URL="${NTFY_URL:+$NTFY_URL/proxmox-alerts}"

alert_failure() {
  local msg="$1"
  if [ -n "$NTFY_URL" ]; then
    curl -s -o /dev/null \
      -H "Title: Backup Failed" \
      -H "Priority: high" \
      -H "Tags: rotating_light,warning" \
      -d "$(echo -e "From: backup-proxmox (daily 02:30)\n\nBackup failed on $HOST: $msg")" \
      "$NTFY_URL" || true
  fi
}

cleanup_on_failure() {
  alert_failure "${1:-unknown error}"
  rm -rf "$WORK_DIR"
  exit 1
}

trap 'cleanup_on_failure "unexpected error on line $LINENO"' ERR

echo "=== Proxmox backup started: $DATE ==="

mkdir -p "$WORK_DIR"/{configs,zfs-meta}

# --- Proxmox configs ---

echo "Copying Proxmox configs..."
if [ -d /etc/pve ]; then
  cp -a /etc/pve "$WORK_DIR/configs/pve"
fi

config_files=(
  /etc/network/interfaces
  /etc/iptables/rules.v4
  /etc/wpa_supplicant/wpa_supplicant-wlo1.conf
)
for f in "${config_files[@]}"; do
  if [ -f "$f" ]; then
    cp "$f" "$WORK_DIR/configs/"
  else
    echo "  Skipping $f (not found)"
  fi
done

# Custom systemd units (ZFS scrub, etc.)
echo "Copying custom systemd units..."
CUSTOM_UNITS_DIR="$WORK_DIR/configs/systemd"
mkdir -p "$CUSTOM_UNITS_DIR"
for unit in /etc/systemd/system/zfs-scrub*.{timer,service} \
            /etc/systemd/system/zfs-scrub-pause*.{timer,service} \
            /etc/systemd/system/backup-proxmox*.{timer,service} \
            /etc/systemd/system/health-check-proxmox*.{timer,service} \
            /etc/systemd/system/pkg-maintenance*.{timer,service}; do
  [ -f "$unit" ] && cp "$unit" "$CUSTOM_UNITS_DIR/" 2>/dev/null || true
done

# Crontab
crontab -l > "$WORK_DIR/configs/crontab-root" 2>/dev/null || true

# --- ZFS metadata (text reference for disaster recovery) ---

echo "Dumping ZFS metadata..."
zpool status tank > "$WORK_DIR/zfs-meta/zpool-status.txt" 2>/dev/null || true
zpool get all tank > "$WORK_DIR/zfs-meta/zpool-properties.txt" 2>/dev/null || true
zfs list -t all > "$WORK_DIR/zfs-meta/zfs-list.txt" 2>/dev/null || true
zfs get all tank > "$WORK_DIR/zfs-meta/zfs-properties.txt" 2>/dev/null || true

# --- Compress ---

echo "Compressing..."
TARBALL="$BACKUP_DIR/$DATE.tar.gz"
tar czf "$TARBALL" -C "$BACKUP_DIR" "$DATE"
rm -rf "$WORK_DIR"

# --- Verify ---

echo "Verifying backup..."
VERIFY_FAIL=""
if ! tar tzf "$TARBALL" >/dev/null 2>&1; then
  VERIFY_FAIL="Tarball is corrupt"
else
  TAR_LIST=$(tar tzf "$TARBALL")
  for key_file in configs/pve zfs-meta/zpool-status.txt; do
    if [[ "$TAR_LIST" != *"$key_file"* ]]; then
      VERIFY_FAIL="${VERIFY_FAIL}Missing: $key_file\n"
    fi
  done
fi
if [ -n "$VERIFY_FAIL" ]; then
  alert_failure "integrity check failed: $VERIFY_FAIL"
fi

# --- Copy to arch-server (Syncthing offsite sync) ---

echo "Copying to arch-server..."
ssh -o ConnectTimeout=10 -o BatchMode=yes "$ARCH_HOST" "mkdir -p '$SYNC_DIR_REMOTE'" 2>/dev/null || true
if ! scp -o ConnectTimeout=10 -o BatchMode=yes "$TARBALL" "$ARCH_HOST:$SYNC_DIR_REMOTE/" 2>/dev/null; then
  alert_failure "SCP to arch-server failed"
fi

# Remote cleanup
ssh -o ConnectTimeout=10 -o BatchMode=yes "$ARCH_HOST" \
  "find '$SYNC_DIR_REMOTE' -name '*.tar.gz' -mtime +$RETENTION_DAYS -delete" 2>/dev/null || true

# --- Cleanup ---

echo "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete

SIZE=$(du -h "$TARBALL" | cut -f1)
echo "=== Backup complete: $TARBALL ($SIZE) ==="

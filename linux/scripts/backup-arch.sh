#!/bin/bash
# Arch-server backup — dumps Postgres, configs, and app data into a dated tarball
# Stored locally + copied to Syncthing for off-device redundancy
# Sends ntfy alert on failure only

set -euo pipefail

HOST=$(hostname)
SCRIPT_OWNER="$(stat -c "%U" "$(readlink -f "$0")")"
USER_HOME="$(getent passwd "$SCRIPT_OWNER" | cut -d: -f6)"
BACKUP_DIR="$USER_HOME/backups/$HOST"
SYNC_DIR="$USER_HOME/Vault/Backups/$HOST"
RETENTION_DAYS=7
DATE=$(date +%F)
WORK_DIR="$BACKUP_DIR/$DATE"

# Source ntfy URL from env
ENV_FILE="$USER_HOME/.config/dotfiles/env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi
NTFY_URL="${NTFY_URL:-}"

alert_failure() {
  local msg="$1"
  if [ -n "$NTFY_URL" ]; then
    curl -s -o /dev/null \
      -H "Title: Backup Failed" \
      -H "Priority: high" \
      -H "Tags: rotating_light,warning" \
      -d "$(echo -e "From: backup-arch (daily 03:00)\n\nBackup failed on $HOST: $msg")" \
      "$NTFY_URL" || true
  fi
}

cleanup_on_failure() {
  alert_failure "${1:-unknown error}"
  rm -rf "$WORK_DIR"
  exit 1
}

trap 'cleanup_on_failure "unexpected error on line $LINENO"' ERR

echo "=== Arch-server backup started: $DATE ==="

mkdir -p "$WORK_DIR"/{databases,configs,app-data}
mkdir -p "$SYNC_DIR"

# --- Databases ---

echo "Dumping Postgres..."
sudo -u postgres pg_dumpall > "$WORK_DIR/databases/postgres-all.sql"

# --- Configs ---

echo "Copying configs..."
config_files=(
  /etc/sonarr/config.xml
  /etc/prowlarr/config.xml
  /etc/navidrome/navidrome.toml
  /etc/samba/smb.conf
  /etc/service-schedule.conf
  /etc/paperless.conf
)
for f in "${config_files[@]}"; do
  if [ -f "$f" ]; then
    cp "$f" "$WORK_DIR/configs/"
  else
    echo "  Skipping $f (not found)"
  fi
done

# SABnzbd config (different path)
if [ -f /var/lib/sabnzbd/sabnzbd.ini ]; then
  cp /var/lib/sabnzbd/sabnzbd.ini "$WORK_DIR/configs/"
fi

# qBittorrent config (user home)
QB_CONF="$USER_HOME/.config/qBittorrent/qBittorrent.conf"
if [ -f "$QB_CONF" ]; then
  cp "$QB_CONF" "$WORK_DIR/configs/"
fi

# Docker configs
if [ -d "$USER_HOME/docker" ]; then
  echo "Copying Docker configs..."
  cp -a "$USER_HOME/docker" "$WORK_DIR/configs/docker"
fi

# Crontabs
crontab -l -u admin > "$WORK_DIR/configs/crontab-admin" 2>/dev/null || true
crontab -l -u root > "$WORK_DIR/configs/crontab-root" 2>/dev/null || true

# --- App data (small, critical) ---

echo "Copying app data..."
for app in sonarr prowlarr bazarr; do
  backup_dir="/var/lib/$app/Backups"
  if [ -d "$backup_dir" ]; then
    mkdir -p "$WORK_DIR/app-data/$app"
    cp -a "$backup_dir" "$WORK_DIR/app-data/$app/"
  fi
done

# Audiobookshelf config + metadata
AB_DIR="$USER_HOME/docker/audiobookshelf"
if [ -d "$AB_DIR" ]; then
  mkdir -p "$WORK_DIR/app-data/audiobookshelf"
  cp -a "$AB_DIR/config" "$WORK_DIR/app-data/audiobookshelf/" 2>/dev/null || true
  cp -a "$AB_DIR/metadata" "$WORK_DIR/app-data/audiobookshelf/" 2>/dev/null || true
fi

# Navidrome database (sqlite3 .backup for consistency while service runs)
ND_DB="/var/lib/navidrome/navidrome.db"
if [ -f "$ND_DB" ]; then
  mkdir -p "$WORK_DIR/app-data/navidrome"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$ND_DB" ".backup '$WORK_DIR/app-data/navidrome/navidrome.db'"
  else
    cp "$ND_DB" "$WORK_DIR/app-data/navidrome/"
  fi
fi

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
  CONTENTS=$(tar tzf "$TARBALL")
  for key_file in databases/postgres-all.sql configs/smb.conf; do
    if ! echo "$CONTENTS" | grep -q "$key_file"; then
      VERIFY_FAIL="${VERIFY_FAIL}Missing: $key_file\n"
    fi
  done
fi
if [ -n "$VERIFY_FAIL" ]; then
  alert_failure "integrity check failed: $VERIFY_FAIL"
fi

# Copy to Syncthing
cp "$TARBALL" "$SYNC_DIR/"

# --- Cleanup ---

echo "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete
find "$SYNC_DIR" -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete

SIZE=$(du -h "$TARBALL" | cut -f1)
echo "=== Backup complete: $TARBALL ($SIZE) ==="

#!/bin/bash
# Server backup — dumps databases, configs, and app data into a dated tarball
# Stored in Syncthing Vault for off-device redundancy
# Sends ntfy alert on failure only

set -euo pipefail

HOST=$(hostname)
SCRIPT_OWNER="$(stat -c "%U" "$(readlink -f "$0")")"
USER_HOME="$(getent passwd "$SCRIPT_OWNER" | cut -d: -f6)"
BACKUP_DIR="$USER_HOME/Vault/Backups/$HOST"
NTFY_URL="http://localhost:2586/pi-alerts"
RETENTION_DAYS=7
DATE=$(date +%F)
WORK_DIR="$BACKUP_DIR/$DATE"

alert_failure() {
    local msg="$1"
    curl -s -o /dev/null \
        -H "Title: Backup Failed" \
        -H "Priority: high" \
        -H "Tags: rotating_light,warning" \
        -d "$(echo -e "From: backup (daily 02:30)\n\nBackup failed on $(hostname): $msg")" \
        "$NTFY_URL" || true
}

cleanup_on_failure() {
    alert_failure "${1:-unknown error}"
    rm -rf "$WORK_DIR"
    exit 1
}

trap 'cleanup_on_failure "unexpected error on line $LINENO"' ERR

echo "=== Pi backup started: $DATE ==="

# Create directory structure
mkdir -p "$WORK_DIR"/{databases,configs,app-data}

# --- Databases ---

echo "Dumping MariaDB..."
mariadb-dump --all-databases --single-transaction > "$WORK_DIR/databases/mariadb-all.sql"

echo "Backing up GoToSocial SQLite..."
sqlite3 /opt/gotosocial/data/sqlite.db ".backup '$WORK_DIR/databases/gotosocial.db'"

echo "Backing up FreshRSS SQLite..."
sqlite3 /var/www/FreshRSS/data/users/freshrss/db.sqlite ".backup '$WORK_DIR/databases/freshrss.db'"

echo "Exporting FreshRSS OPML..."
sudo -u www-data php /var/www/FreshRSS/cli/export-opml-for-user.php --user freshrss > "$WORK_DIR/configs/freshrss-feeds.opml"

# --- Configs ---

echo "Copying configs..."
cp /var/www/FreshRSS/data/config.php "$WORK_DIR/configs/freshrss-config.php"
cp /opt/gotosocial/config.yaml "$WORK_DIR/configs/gotosocial-config.yaml"
cp /var/www/firefly-iii/.env "$WORK_DIR/configs/firefly-iii.env"
cp /var/www/rss-bridge/config.ini.php "$WORK_DIR/configs/rss-bridge-config.ini.php"

# Crontabs
crontab -l -u admin > "$WORK_DIR/configs/crontab-admin" 2>/dev/null || true
crontab -l -u root > "$WORK_DIR/configs/crontab-root" 2>/dev/null || true

# --- App data ---

echo "Copying Radicale data..."
cp -a /var/lib/radicale/collections/ "$WORK_DIR/app-data/radicale-collections/"

echo "Copying GoToSocial media..."
if [ -d /opt/gotosocial/data/storage ]; then
    cp -a /opt/gotosocial/data/storage/ "$WORK_DIR/app-data/gotosocial-storage/"
fi

echo "Copying GPX trails..."
cp -a /var/www/hiking-map/gpx/ "$WORK_DIR/app-data/gpx-trails/"

# --- Compress ---

echo "Compressing..."
TARBALL="$BACKUP_DIR/$DATE.tar.gz"
tar czf "$TARBALL" -C "$BACKUP_DIR" "$DATE"
rm -rf "$WORK_DIR"

# --- Verify backup integrity ---

echo "Verifying backup..."
VERIFY_FAIL=""
# Test tarball isn't corrupt
if ! tar tzf "$TARBALL" >/dev/null 2>&1; then
    VERIFY_FAIL="Tarball is corrupt"
else
    # List tarball once, check key files against the listing
    TARBALL_LIST=$(tar tzf "$TARBALL")
    for key_file in databases/mariadb-all.sql databases/gotosocial.db configs/firefly-iii.env; do
        if ! echo "$TARBALL_LIST" | grep -q "$key_file"; then
            VERIFY_FAIL="${VERIFY_FAIL}Missing: $key_file\n"
        fi
    done
fi
if [ -n "$VERIFY_FAIL" ]; then
    cleanup_on_failure "integrity check failed: $VERIFY_FAIL"
fi

# --- Cleanup old backups ---

echo "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete

SIZE=$(du -h "$TARBALL" | cut -f1)
echo "=== Backup complete: $TARBALL ($SIZE) ==="

#!/bin/bash
# Deploy Pi server infrastructure from the dotfiles repo.
# Handles scripts, systemd units, nginx configs, and server configs.
# Run with sudo: sudo ./linux/install.sh
#
# Shell configs are handled separately by bootstrap.sh (no sudo needed).
# Dashboard is a separate repo (pi-dashboard).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES="$(cd "$SCRIPT_DIR/.." && pwd)"
USER_HOME="$(stat -c "%u" "$DOTFILES" | xargs getent passwd | cut -d: -f6)"
USER_NAME="$(stat -c "%U" "$DOTFILES")"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo ./linux/install.sh"
  exit 1
fi

echo ""
echo "Pi server install — from $SCRIPT_DIR"
echo "User: $USER_NAME, Home: $USER_HOME"
echo ""

# ── Scripts → /usr/local/bin/ ────────────────────────────
echo "Installing scripts..."
for script in "$SCRIPT_DIR"/scripts/*; do
  [ -f "$script" ] || continue
  name=$(basename "$script")
  chmod +x "$script"
  ln -sfn "$script" "/usr/local/bin/$name"
  echo "  [ok] $name → /usr/local/bin/$name"
done

# ── Systemd units → /etc/systemd/system/ ─────────────────
# Copies, not symlinks — systemctl disable deletes symlinks
echo "Installing systemd units..."
for unit in "$SCRIPT_DIR"/systemd/*; do
  [ -f "$unit" ] || continue
  name=$(basename "$unit")
  cp "$unit" "/etc/systemd/system/$name"
  echo "  [ok] $name → /etc/systemd/system/$name"
done

# ── Systemd drop-in overrides (OnFailure alerts) ─────────
for override in "$SCRIPT_DIR"/systemd/overrides/*.conf; do
  [ -f "$override" ] || continue
  svc=$(basename "$override" .conf)
  mkdir -p "/etc/systemd/system/${svc}.service.d"
  cp "$override" "/etc/systemd/system/${svc}.service.d/override.conf"
  echo "  [ok] ${svc} override → ${svc}.service.d/override.conf"
done

# ── Nginx sites ───────────────────────────────────────────
# Nginx configs are now Ansible templates (roles/nginx/templates/).
# Use: ansible-playbook linux/ansible/site.yml
echo "  [skip] nginx configs — use Ansible"

# ── Server configs ────────────────────────────────────────
echo "Installing server configs..."
CFG="$SCRIPT_DIR/config"

mkdir -p /usr/local/lib/pi-cron
ln -sfn "$CFG/cron-registry.json" "/usr/local/lib/pi-cron/cron-registry.json"
echo "  [ok] cron-registry.json"

# ntfy and cloudflared configs are now Ansible templates.
echo "  [skip] ntfy-server.yml — use Ansible"
echo "  [skip] cloudflared.yml — use Ansible"

ln -sfn "$CFG/50unattended-upgrades" "/etc/apt/apt.conf.d/50unattended-upgrades"
ln -sfn "$CFG/20auto-upgrades" "/etc/apt/apt.conf.d/20auto-upgrades"
echo "  [ok] apt unattended-upgrades"

mkdir -p /etc/needrestart/conf.d
ln -sfn "$CFG/needrestart.conf" "/etc/needrestart/conf.d/pi-server.conf"
echo "  [ok] needrestart.conf"

cp "$CFG/logrotate-pi-server" "/etc/logrotate.d/pi-server"
echo "  [ok] logrotate-pi-server (copy)"

if [ -d /var/www/rss-bridge ]; then
  cp "$CFG/rss-bridge.ini.php" "/var/www/rss-bridge/config.ini.php"
  chown www-data:www-data "/var/www/rss-bridge/config.ini.php"
  echo "  [ok] rss-bridge.ini.php (copy)"
  for bridge in "$CFG"/rss-bridge/*.php; do
    [ -f "$bridge" ] || continue
    cp "$bridge" "/var/www/rss-bridge/bridges/"
    chown www-data:www-data "/var/www/rss-bridge/bridges/$(basename "$bridge")"
    echo "  [ok] $(basename "$bridge") → bridges/ (copy)"
  done
fi

# ── Dashboard symlink ─────────────────────────────────────
DASHBOARD="$USER_HOME/repositories/pi-dashboard"
if [ -d "$DASHBOARD" ]; then
  ln -sfn "$DASHBOARD" "/var/www/pi-dashboard"
  echo "  [ok] dashboard → /var/www/pi-dashboard"
else
  echo "  [skip] pi-dashboard repo not found at $DASHBOARD"
fi

# ── Backup directories ───────────────────────────────────
mkdir -p "$USER_HOME/backups" "$USER_HOME/Vault/Backups"
chown "$USER_NAME:$USER_NAME" "$USER_HOME/backups" "$USER_HOME/Vault/Backups"

# ── Reload and enable timers ─────────────────────────────
TIMERS="backup-pi.timer health-check-pi.timer freshrss-digest.timer freshrss-maintenance.timer pkg-maintenance.timer wifi-watchdog.timer"
echo ""
echo "Reloading systemd and enabling timers..."
systemctl daemon-reload
for timer in $TIMERS; do
  systemctl enable --now "$timer" 2>/dev/null || true
done

echo ""
echo "Done. Active timers:"
systemctl list-timers --no-pager | head -15

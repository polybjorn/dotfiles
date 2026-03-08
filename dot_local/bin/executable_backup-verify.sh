#!/bin/bash
# Backup verification — Mac tarball, Pi tarball (via Syncthing), KeePassXC, database integrity
# Runs after backup (03:30), alerts via ntfy on failure only

set -euo pipefail

[[ -f "$HOME/.config/dotfiles/env" ]] && source "$HOME/.config/dotfiles/env"

HOST=$(hostname -s)
BACKUP_DIR="$HOME/Vault/Backups/$HOST"
NTFY_URL="${NTFY_URL:-https://localhost:2587}/mac-alerts"
VERIFY_TMP=$(mktemp -d)
PI_VERIFY_TMP=""
PROBLEMS=""

cleanup() { rm -rf "$VERIFY_TMP" ${PI_VERIFY_TMP:+"$PI_VERIFY_TMP"}; }
trap cleanup EXIT

alert_failure() {
  curl -s -o /dev/null \
    -H "Title: Backup Verification Error" \
    -H "Priority: high" \
    -H "Tags: rotating_light,warning" \
    -d "$(echo -e "From: backup-verify (daily 03:30)\n\nVerification script failed on $HOST: ${1:-unknown error}")" \
    "$NTFY_URL" || true
}
trap 'alert_failure "unexpected error on line $LINENO"' ERR

echo "=== Backup verification started: $(date +%F) ==="

# --- Find today's tarball ---
HOUR=$(date +%H)
if [ "$HOUR" -ge 3 ]; then
  TARBALL="$BACKUP_DIR/$(date +%Y-%m-%d).tar.gz"
else
  TARBALL="$BACKUP_DIR/$(date -v-1d +%Y-%m-%d).tar.gz"
fi

if [ ! -f "$TARBALL" ]; then
  PROBLEMS="${PROBLEMS}- Tarball not found: $(basename "$TARBALL")\n"
else
  # --- Tarball integrity ---
  echo "Checking tarball integrity..."
  if ! tar tzf "$TARBALL" >/dev/null 2>&1; then
    PROBLEMS="${PROBLEMS}- Tarball is corrupt\n"
  else
    # Check key files exist inside
    CONTENTS=$(tar tzf "$TARBALL")
    REQUIRED_FILES=(
      configs/.zshenv
      configs/CLAUDE.md
      configs/claude-settings.json
      configs/zsh/.zshrc
      configs/zsh/aliases.zsh
      configs/keepassxc.ini
      configs/syncthing-config.xml
      configs/Brewfile
      configs/brew-formulae.txt
      configs/brew-casks.txt
      scripts/
      launchd/
    )
    for key_file in "${REQUIRED_FILES[@]}"; do
      if ! grep -q "$key_file" <<< "$CONTENTS"; then
        PROBLEMS="${PROBLEMS}- Missing in tarball: $key_file\n"
      fi
    done
  fi

  # Check minimum size (10KB)
  TARBALL_SIZE=$(stat -f%z "$TARBALL")
  if [ "$TARBALL_SIZE" -lt 10240 ]; then
    PROBLEMS="${PROBLEMS}- Tarball suspiciously small: $(du -h "$TARBALL" | cut -f1)\n"
  fi

  # --- Restore test ---
  echo "Testing restore..."
  if tar xzf "$TARBALL" -C "$VERIFY_TMP" 2>/dev/null; then
    DATE_DIR=$(basename "$TARBALL" .tar.gz)
    RESTORE_CHECK_FILES=(
      configs/.zshenv
      configs/CLAUDE.md
      configs/claude-settings.json
      configs/zsh/.zshrc
      configs/keepassxc.ini
      configs/syncthing-config.xml
      configs/Brewfile
      scripts/ntfy
    )
    for check_file in "${RESTORE_CHECK_FILES[@]}"; do
      FULL_PATH="$VERIFY_TMP/$DATE_DIR/$check_file"
      if [ ! -s "$FULL_PATH" ]; then
        PROBLEMS="${PROBLEMS}- Restore check failed: $check_file missing or empty\n"
      fi
    done
  else
    PROBLEMS="${PROBLEMS}- Tarball extraction failed\n"
  fi
fi

# --- KeePassXC database integrity ---
echo "Checking KeePassXC database..."
KDBX="$HOME/Vault/Authentication/Passwords.kdbx"
if [ ! -f "$KDBX" ]; then
  PROBLEMS="${PROBLEMS}- KeePassXC database not found\n"
else
  # Magic bytes check (KDBX signature: 03d9a29a)
  MAGIC=$(xxd -l 4 -p "$KDBX" 2>/dev/null)
  if [ "$MAGIC" != "03d9a29a" ]; then
    PROBLEMS="${PROBLEMS}- KeePassXC database has invalid signature\n"
  fi

  # Size check (1KB - 10MB)
  KDBX_SIZE=$(stat -f%z "$KDBX")
  if [ "$KDBX_SIZE" -lt 1024 ]; then
    PROBLEMS="${PROBLEMS}- KeePassXC database suspiciously small: ${KDBX_SIZE} bytes\n"
  elif [ "$KDBX_SIZE" -gt 10485760 ]; then
    PROBLEMS="${PROBLEMS}- KeePassXC database suspiciously large: $(du -h "$KDBX" | cut -f1)\n"
  fi

  # Freshness check (modified within 30 days)
  KDBX_MOD=$(stat -f%m "$KDBX")
  KDBX_AGE=$(( ($(date +%s) - KDBX_MOD) / 86400 ))
  if [ "$KDBX_AGE" -gt 30 ]; then
    PROBLEMS="${PROBLEMS}- KeePassXC database not modified in ${KDBX_AGE} days\n"
  fi
fi

# --- Pi backup verification (cross-device via Syncthing) ---
echo "Checking Pi backup..."
PI_BACKUP_DIR="$HOME/Vault/Backups/pi-server"
if [ -d "$PI_BACKUP_DIR" ]; then
  # Allow 1 day lag for Syncthing sync
  PI_TARBALL="$PI_BACKUP_DIR/$(date +%Y-%m-%d).tar.gz"
  [ ! -f "$PI_TARBALL" ] && PI_TARBALL="$PI_BACKUP_DIR/$(date -v-1d +%Y-%m-%d).tar.gz"

  if [ ! -f "$PI_TARBALL" ]; then
    PROBLEMS="${PROBLEMS}- Pi backup not found (today or yesterday)\n"
  else
    # Integrity check
    if ! tar tzf "$PI_TARBALL" >/dev/null 2>&1; then
      PROBLEMS="${PROBLEMS}- Pi tarball is corrupt\n"
    else
      PI_CONTENTS=$(tar tzf "$PI_TARBALL")
      for pi_file in databases/mariadb-all.sql databases/gotosocial.db databases/freshrss.db configs/; do
        if ! grep -q "$pi_file" <<< "$PI_CONTENTS"; then
          PROBLEMS="${PROBLEMS}- Missing in Pi tarball: $pi_file\n"
        fi
      done
    fi

    # Size check (1MB minimum)
    PI_SIZE=$(stat -f%z "$PI_TARBALL")
    if [ "$PI_SIZE" -lt 1048576 ]; then
      PROBLEMS="${PROBLEMS}- Pi tarball suspiciously small: $(du -h "$PI_TARBALL" | cut -f1)\n"
    fi

    # Database integrity tests
    PI_VERIFY_TMP=$(mktemp -d)
    if tar xzf "$PI_TARBALL" -C "$PI_VERIFY_TMP" 2>/dev/null; then
      PI_DATE_DIR=$(basename "$PI_TARBALL" .tar.gz)

      # SQLite integrity checks
      for db in databases/gotosocial.db databases/freshrss.db; do
        DB_PATH="$PI_VERIFY_TMP/$PI_DATE_DIR/$db"
        if [ -f "$DB_PATH" ]; then
          RESULT=$(sqlite3 "$DB_PATH" 'PRAGMA integrity_check' 2>&1 || true)
          if [ "$RESULT" != "ok" ]; then
            PROBLEMS="${PROBLEMS}- Pi $(basename "$db") integrity check failed: $RESULT\n"
          fi
        fi
      done

      # MariaDB dump sanity check
      SQL_PATH="$PI_VERIFY_TMP/$PI_DATE_DIR/databases/mariadb-all.sql"
      if [ -f "$SQL_PATH" ]; then
        if ! grep -q 'CREATE TABLE' "$SQL_PATH" 2>/dev/null; then
          PROBLEMS="${PROBLEMS}- Pi MariaDB dump missing CREATE TABLE statements\n"
        fi
        if ! grep -q 'INSERT' "$SQL_PATH" 2>/dev/null; then
          PROBLEMS="${PROBLEMS}- Pi MariaDB dump missing INSERT statements\n"
        fi
      fi
    else
      PROBLEMS="${PROBLEMS}- Pi tarball extraction failed\n"
    fi
  fi
else
  PROBLEMS="${PROBLEMS}- Pi backup directory not found: $PI_BACKUP_DIR\n"
fi

# --- Alert on failure ---
if [ -n "$PROBLEMS" ]; then
  echo "PROBLEMS FOUND:"
  echo -e "$PROBLEMS"
  curl -s -o /dev/null \
    -H "Title: Backup Verification Failed" \
    -H "Priority: high" \
    -H "Tags: rotating_light,warning" \
    -d "$(echo -e "From: backup-verify (daily 03:30)\n\nVerification issues on $HOST:\n$PROBLEMS")" \
    "$NTFY_URL" || true
else
  echo "All checks passed."
fi

echo "=== Backup verification complete ==="

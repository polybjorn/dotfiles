#!/bin/bash
# Backup verification — tarball integrity, restore test, KeePassXC check
# Runs after backup (03:30), alerts via ntfy on failure only

set -euo pipefail

[[ -f "$HOME/.config/dotfiles/env" ]] && source "$HOME/.config/dotfiles/env"

HOST=$(hostname -s)
BACKUP_DIR="$HOME/Vault/Backups/$HOST"
NTFY_URL="${NTFY_URL:-https://localhost:2587}/mac-alerts"
VERIFY_TMP=$(mktemp -d)
PROBLEMS=""

cleanup() { rm -rf "$VERIFY_TMP"; }
trap cleanup EXIT

alert_failure() {
  curl -s -o /dev/null \
    -H "Title: Backup Verification Error" \
    -H "Priority: high" \
    -H "Tags: rotating_light,warning" \
    -d "Verification script failed on $HOST: ${1:-unknown error}" \
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
    for key_file in configs/.zshenv configs/CLAUDE.md scripts/; do
      if ! echo "$CONTENTS" | grep -q "$key_file"; then
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
    for check_file in configs/.zshenv configs/CLAUDE.md scripts/ntfy; do
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
KDBX="$HOME/Vault/Personal/Authentication/Passwords.kdbx"
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

# --- Alert on failure ---
if [ -n "$PROBLEMS" ]; then
  echo "PROBLEMS FOUND:"
  echo -e "$PROBLEMS"
  curl -s -o /dev/null \
    -H "Title: Backup Verification Failed" \
    -H "Priority: high" \
    -H "Tags: rotating_light,warning" \
    -d "$(echo -e "Verification issues on $HOST:\n$PROBLEMS")" \
    "$NTFY_URL" || true
else
  echo "All checks passed."
fi

echo "=== Backup verification complete ==="

#!/bin/bash
# Backup — configs, scripts, and package lists into a dated tarball
# Stored in Syncthing for off-device redundancy
# Sends ntfy alert on failure only

set -euo pipefail

[[ -f "$HOME/.config/dotfiles/env" ]] && source "$HOME/.config/dotfiles/env"

HOST=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
BACKUP_DIR="$HOME/Vault/Backups/$HOST"
NTFY_URL="${NTFY_URL:-https://localhost:2587}/mac-alerts"
RETENTION_DAYS=7
DATE=$(date +%F)
WORK_DIR="$BACKUP_DIR/$DATE"

alert_failure() {
  local msg="$1"
  curl -s -o /dev/null \
    -H "Title: Backup Failed" \
    -H "Priority: high" \
    -H "Tags: rotating_light,warning" \
    -d "$(echo -e "From: backup (daily 09:00)\n\nBackup failed on $HOST: $msg")" \
    "$NTFY_URL" || true
}

cleanup_on_failure() {
  alert_failure "${1:-unknown error}"
  rm -rf "$WORK_DIR"
  exit 1
}

trap 'cleanup_on_failure "unexpected error on line $LINENO"' ERR

echo "=== Mac backup started: $DATE ==="

mkdir -p "$WORK_DIR"/{configs,scripts,launchd}

# --- Shell configs ---
echo "Copying shell configs..."
cp "$HOME/.zprofile" "$WORK_DIR/configs/" 2>/dev/null || true
cp "$HOME/.zshenv" "$WORK_DIR/configs/" 2>/dev/null || true
cp "$HOME/.zshrc" "$WORK_DIR/configs/" 2>/dev/null || true
cp "$HOME/.gitconfig" "$WORK_DIR/configs/" 2>/dev/null || true

# --- ZSH configs (ZDOTDIR) ---
if [ -d "$HOME/.config/zsh" ]; then
  mkdir -p "$WORK_DIR/configs/zsh"
  cp "$HOME/.config/zsh/.zshrc" "$WORK_DIR/configs/zsh/" 2>/dev/null || true
  cp "$HOME/.config/zsh/aliases.zsh" "$WORK_DIR/configs/zsh/" 2>/dev/null || true
  cp "$HOME/.config/zsh/.p10k.zsh" "$WORK_DIR/configs/zsh/" 2>/dev/null || true
fi

# --- Claude config ---
echo "Copying Claude config..."
cp -a "$HOME/.claude/CLAUDE.md" "$WORK_DIR/configs/" 2>/dev/null || true
cp -a "$HOME/.claude/settings.json" "$WORK_DIR/configs/claude-settings.json" 2>/dev/null || true
cp -a "$HOME/.claude/settings.local.json" "$WORK_DIR/configs/claude-settings-local.json" 2>/dev/null || true
if [ -d "$HOME/.claude/memory" ]; then
  mkdir -p "$WORK_DIR/configs/claude-memory"
  cp -a "$HOME/.claude/memory/"* "$WORK_DIR/configs/claude-memory/" 2>/dev/null || true
fi

# --- SSH keys & config ---
cp "$HOME/.ssh/config" "$WORK_DIR/configs/ssh-config" 2>/dev/null || true
cp "$HOME/.ssh/id_ed25519" "$WORK_DIR/configs/ssh-key" 2>/dev/null || true
cp "$HOME/.ssh/id_ed25519.pub" "$WORK_DIR/configs/ssh-pubkey.pub" 2>/dev/null || true

# --- GitHub CLI ---
if [ -d "$HOME/.config/gh" ]; then
  mkdir -p "$WORK_DIR/configs/gh"
  cp -a "$HOME/.config/gh/"* "$WORK_DIR/configs/gh/" 2>/dev/null || true
fi

# --- Scripts ---
echo "Copying scripts..."
if [ -d "$HOME/.local/bin" ]; then
  mkdir -p "$WORK_DIR/scripts"
  for f in "$HOME/.local/bin/"*; do
    [ -f "$f" ] && cp "$f" "$WORK_DIR/scripts/" 2>/dev/null || true
  done
fi

# --- LaunchAgents ---
echo "Copying LaunchAgents..."
cp "$HOME/Library/LaunchAgents/local."*.plist "$WORK_DIR/launchd/" 2>/dev/null || true

# --- Syncthing config ---
echo "Copying Syncthing config..."
cp "$HOME/Library/Application Support/Syncthing/config.xml" "$WORK_DIR/configs/syncthing-config.xml" 2>/dev/null || true

# --- iTerm2 prefs ---
echo "Copying iTerm2 prefs..."
cp "$HOME/Library/Preferences/com.googlecode.iterm2.plist" "$WORK_DIR/configs/" 2>/dev/null || true

# --- Sublime Text user config ---
if [ -d "$HOME/Library/Application Support/Sublime Text/Packages/User" ]; then
  echo "Copying Sublime Text config..."
  mkdir -p "$WORK_DIR/configs/sublime"
  cp -a "$HOME/Library/Application Support/Sublime Text/Packages/User/"*.sublime-* "$WORK_DIR/configs/sublime/" 2>/dev/null || true
  cp -a "$HOME/Library/Application Support/Sublime Text/Packages/User/"*.json "$WORK_DIR/configs/sublime/" 2>/dev/null || true
fi

# --- KeePassXC config ---
cp "$HOME/Library/Application Support/keepassxc/keepassxc.ini" "$WORK_DIR/configs/keepassxc.ini" 2>/dev/null || true

# --- Hammerspoon ---
if [ -d "$HOME/.hammerspoon" ]; then
  echo "Copying Hammerspoon config..."
  mkdir -p "$WORK_DIR/configs/hammerspoon"
  cp -a "$HOME/.hammerspoon/init.lua" "$WORK_DIR/configs/hammerspoon/" 2>/dev/null || true
  cp -a "$HOME/.hammerspoon/Spoons" "$WORK_DIR/configs/hammerspoon/" 2>/dev/null || true
fi

# --- Brewfile ---
echo "Copying Brewfile..."
cp "$HOME/repositories/dotfiles/Brewfile" "$WORK_DIR/configs/Brewfile" 2>/dev/null || true

# --- Brew package lists ---
echo "Dumping brew package lists..."
/opt/homebrew/bin/brew list --formula -1 > "$WORK_DIR/configs/brew-formulae.txt" 2>/dev/null || true
/opt/homebrew/bin/brew list --cask -1 > "$WORK_DIR/configs/brew-casks.txt" 2>/dev/null || true

# --- Compress ---
echo "Compressing..."
TARBALL="$BACKUP_DIR/$DATE.tar.gz"
tar czf "$TARBALL" -C "$BACKUP_DIR" "$DATE"
rm -rf "$WORK_DIR"

# --- Cleanup old backups ---
echo "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete

SIZE=$(du -h "$TARBALL" | cut -f1)
echo "=== Backup complete: $TARBALL ($SIZE) ==="

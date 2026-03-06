#!/bin/bash
# Bootstrap dotfiles — detects OS, symlinks configs, deploys scripts
# Idempotent: safe to run multiple times

set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")" && pwd)"
OS="$(uname -s)"

info() { printf "  [ .. ] %s\n" "$1"; }
ok()   { printf "  [ ok ] %s\n" "$1"; }
fail() { printf "  [FAIL] %s\n" "$1"; }

link_file() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -d "$dst" ]; then
    mv "$dst" "${dst}.backup"
    info "Backed up $(basename "$dst") (dir)"
  elif [ -f "$dst" ]; then
    mv "$dst" "${dst}.backup"
    info "Backed up $(basename "$dst")"
  fi
  ln -s "$src" "$dst"
  ok "$(basename "$src") -> $dst"
}

copy_file() {
  local src="$1" dst="$2"
  cp "$src" "$dst"
  ok "$(basename "$src") -> $dst (copy)"
}

echo ""
echo "Dotfiles bootstrap — $OS detected"
echo "Source: $DOTFILES"
echo ""

# ── Shared configs ──────────────────────────────────────
info "Installing shared configs..."

mkdir -p "$HOME/.config/zsh"
mkdir -p "$HOME/.config/git"
mkdir -p "$HOME/.local/bin"

link_file "$DOTFILES/shared/shell/.zshenv" "$HOME/.zshenv"

for f in .zshrc aliases.zsh .p10k.zsh; do
  link_file "$DOTFILES/shared/shell/$f" "$HOME/.config/zsh/$f"
done

link_file "$DOTFILES/shared/git/.gitconfig" "$HOME/.gitconfig"
link_file "$DOTFILES/shared/git/ignore" "$HOME/.config/git/ignore"

# ── Cross-platform bin/ scripts ─────────────────────────
info "Installing bin/ scripts..."
for script in "$DOTFILES"/bin/*; do
  [ -f "$script" ] || continue
  name=$(basename "$script")
  chmod +x "$script"
  link_file "$script" "$HOME/.local/bin/$name"
done

# ── Private env file ────────────────────────────────────
if [ ! -f "$HOME/.config/dotfiles/env" ]; then
  mkdir -p "$HOME/.config/dotfiles"
  if [ -f "$DOTFILES/dotfiles.env.example" ]; then
    cp "$DOTFILES/dotfiles.env.example" "$HOME/.config/dotfiles/env"
    info "Created ~/.config/dotfiles/env from template — edit with your values"
  fi
fi

# ── Platform-specific ───────────────────────────────────
case "$OS" in
  Darwin)
    echo ""
    info "macOS setup..."

    # .zprofile
    link_file "$DOTFILES/macos/shell/.zprofile" "$HOME/.zprofile"

    # Hammerspoon
    mkdir -p "$HOME/.hammerspoon/Spoons"
    link_file "$DOTFILES/macos/hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua"
    for spoon in "$DOTFILES"/macos/hammerspoon/Spoons/*.spoon; do
      [ -d "$spoon" ] || continue
      link_file "$spoon" "$HOME/.hammerspoon/Spoons/$(basename "$spoon")"
    done

    # Scripts -> ~/.local/bin/
    info "Installing macOS scripts..."
    for script in "$DOTFILES"/macos/scripts/*; do
      [ -f "$script" ] || continue
      name=$(basename "$script")
      chmod +x "$script"
      link_file "$script" "$HOME/.local/bin/$name"
    done

    # LaunchAgents (copies, not symlinks — launchd removes symlinks on unload)
    info "Installing LaunchAgents..."
    mkdir -p "$HOME/Library/LaunchAgents"
    for plist in "$DOTFILES"/macos/launchd/*.plist; do
      [ -f "$plist" ] || continue
      name=$(basename "$plist")
      copy_file "$plist" "$HOME/Library/LaunchAgents/$name"
    done

    # Load LaunchAgents
    info "Loading LaunchAgents..."
    for plist in "$HOME/Library/LaunchAgents"/com.bjanda.*.plist; do
      [ -f "$plist" ] || continue
      name=$(basename "$plist")
      launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$plist"
      ok "Loaded $name"
    done

    # Platform-specific git config
    mkdir -p "$HOME/.config/git"
    cat > "$HOME/.config/git/local.gitconfig" << 'EOF'
[core]
  pager = bat --paging=always
[credential "https://github.com"]
  helper =
  helper = !/opt/homebrew/bin/gh auth git-credential
[credential "https://gist.github.com"]
  helper =
  helper = !/opt/homebrew/bin/gh auth git-credential
EOF
    ok "Generated macOS git config"

    # Homebrew packages
    if command -v brew &>/dev/null; then
      echo ""
      read -p "  Install Homebrew packages from Brewfile? [y/N] " install_brew
      if [[ "$install_brew" =~ ^[Yy]$ ]]; then
        brew bundle --file="$DOTFILES/Brewfile" --no-lock
        ok "Brewfile installed"
      fi
    fi

    # macOS defaults
    echo ""
    read -p "  Apply macOS defaults (Finder, Dock, keyboard, etc.)? [y/N] " apply_defaults
    if [[ "$apply_defaults" =~ ^[Yy]$ ]]; then
      bash "$DOTFILES/macos/defaults.sh"
      ok "macOS defaults applied"
    fi
    ;;

  Linux)
    echo ""
    info "Linux setup..."

    # .zprofile
    link_file "$DOTFILES/linux/shell/.zprofile" "$HOME/.zprofile"

    # Platform-specific git config
    mkdir -p "$HOME/.config/git"
    cat > "$HOME/.config/git/local.gitconfig" << 'EOF'
[core]
  pager = batcat --paging=always
EOF
    ok "Generated Linux git config"
    ;;

  *)
    fail "Unsupported OS: $OS"
    exit 1
    ;;
esac

echo ""
echo "Done. Restart your shell to pick up changes."

#!/bin/bash
# macOS defaults — idempotent, requires restart/logout for some changes
set -euo pipefail

echo "Applying macOS defaults..."

# ── Finder ──────────────────────────────────────────────
defaults write com.apple.finder AppleShowAllExtensions -bool true
defaults write com.apple.finder ShowPathbar -bool true
defaults write com.apple.finder ShowStatusBar -bool true
defaults write com.apple.finder _FXShowPosixPathInTitle -bool true
defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
defaults write NSGlobalDomain AppleShowAllExtensions -bool true

# ── Dock ────────────────────────────────────────────────
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock autohide-time-modifier -float 0.4
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.dock tilesize -int 48
defaults write com.apple.dock minimize-to-application -bool true

# ── Keyboard ──────────────────────────────────────────
defaults write NSGlobalDomain KeyRepeat -int 2
defaults write NSGlobalDomain InitialKeyRepeat -int 15
defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false

# ── Trackpad ──────────────────────────────────────────
defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true

# ── Screenshots ─────────────────────────────────────────
defaults write com.apple.screencapture location -string "$HOME/Vault/Photos/Screenshots"
defaults write com.apple.screencapture type -string "png"
defaults write com.apple.screencapture disable-shadow -bool true

# ── Safari / Privacy ──────────────────────────────────
defaults write com.apple.Safari AutoOpenSafeDownloads -bool false
defaults write com.apple.Safari ShowFullURLInSmartSearchField -bool true

# ── Activity Monitor ────────────────────────────────────
defaults write com.apple.ActivityMonitor ShowCategory -int 0

# ── Security (requires sudo) ──────────────────────────
if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
  echo "  [ok] Firewall enabled with stealth mode"
else
  echo "  [skip] Firewall — run with sudo or enter password to enable"
fi

# ── Restart affected apps ──────────────────────────────
for app in "Finder" "Dock" "SystemUIServer"; do
  killall "$app" &>/dev/null || true
done

echo "macOS defaults applied. Some changes may require logout."

# dotfiles

Cross-platform dotfiles for macOS and Linux (Raspberry Pi). Managed by
[chezmoi](https://www.chezmoi.io/) for user configs and
[Ansible](https://www.ansible.com/) for Pi server infrastructure.

## Quick start

### New machine

```sh
brew install chezmoi
chezmoi init polybjorn/dotfiles --apply
```

### Existing setup

```sh
ln -sfn ~/repositories/dotfiles ~/.local/share/chezmoi
chezmoi apply
```

### Pi server infrastructure (from Mac)

```sh
cd ~/repositories/dotfiles
ansible-playbook linux/ansible/site.yml
```

## What's included

### Shared (both platforms)
- Zsh with Powerlevel10k, ZDOTDIR at `~/.config/zsh/`
- Cross-platform aliases with `$OSTYPE` branching
- XDG Base Directory layout
- Utility scripts: ntfy, backup-status, syncthing-status

### macOS
- Hammerspoon window management
- LaunchAgent scheduled tasks (backup, health check, brew maintenance)
- Homebrew Brewfile (auto-installed via chezmoi)
- macOS system defaults (opt-in)
- Photo sorting, Obsidian automation

### Linux (Raspberry Pi)
- Server scripts (backup, health check, apt maintenance, FreshRSS, etc.)
- Systemd services and timers
- Nginx reverse proxy configs
- Server configs (ntfy, cloudflared, unattended-upgrades, radicale, etc.)

## Scheduled tasks

### macOS (LaunchAgents)

| Agent | Schedule | Purpose |
|---|---|---|
| backup-claude | On file change | CLAUDE.md backup to Vault |
| mac-backup | 03:00 daily | Config tarball to Vault |
| mac-health-check | 08:00 daily | System diagnostics, ntfy alerts |
| mac-stats-push | Every 5 min | Push stats to Pi dashboard |
| brew-maintenance | Sun 09:00 | Homebrew update/cleanup |
| obsidian-weekly-note | Mon 00:05 | Generate weekly planning note |

### Linux (systemd timers)

| Timer | Schedule | Purpose |
|---|---|---|
| health-check | Every 4h | System diagnostics, ntfy alerts |
| pi-backup | 02:30 daily | Full server backup |
| apt-maintenance | Sun 09:00 | apt update/upgrade/clean |
| nightmode | 01:00-07:00 | Disable/enable nginx sites |
| freshrss-refresh | */15 07-23h | FreshRSS feed refresh |
| freshrss-digest | Mon 08:00 | Weekly release/feed report |
| wifi-watchdog | Every 2 min | WiFi reconnection |

## Private config

chezmoi creates `~/.config/dotfiles/env` on first apply (never overwrites).
Edit with your private values (ntfy URL, Pi hostname).

age encryption is available for secrets committed to the repo
(key at `~/.config/chezmoi/key.txt`).

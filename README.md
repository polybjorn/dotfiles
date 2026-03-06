# dotfiles

Cross-platform dotfiles for macOS and Linux (Raspberry Pi). Shell configs,
scripts, and automation managed with a single bootstrap script.

## Quick start

```sh
git clone https://github.com/polybjorn/dotfiles.git ~/repositories/dotfiles
cd ~/repositories/dotfiles && ./bootstrap.sh
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
- Homebrew Brewfile
- macOS system defaults (opt-in)
- Photo sorting, Obsidian automation

### Linux
- Minimal .zprofile (no Homebrew)
- Same shell experience as macOS

## Structure

```
dotfiles/
├── shared/          # Cross-platform configs
│   ├── shell/       # .zshenv, .zshrc, aliases.zsh, .p10k.zsh
│   └── git/         # .gitconfig, ignore
├── macos/           # macOS overlays
│   ├── shell/       # .zprofile
│   ├── hammerspoon/ # Window management
│   ├── launchd/     # Scheduled tasks
│   ├── scripts/     # Automation scripts
│   └── defaults.sh  # System preferences
├── linux/           # Linux overlays
│   └── shell/       # .zprofile
├── bin/             # Cross-platform utility scripts
├── bootstrap.sh     # OS-detecting installer
└── Brewfile         # Homebrew packages (macOS)
```

## Deployment

Symlinks for configs and scripts. Copies for LaunchAgents (launchd
removes symlinked plists on unload).

Scripts deploy to `~/.local/bin/` (on `$PATH`).

## Scheduled tasks (macOS)

| Agent | Schedule | Purpose |
|---|---|---|
| backup-claude | On file change | CLAUDE.md backup to Vault |
| mac-backup | 03:00 daily | Config tarball to Vault |
| mac-health-check | 08:00 daily | System diagnostics, ntfy alerts |
| mac-stats-push | Every 5 min | Push stats to Pi dashboard |
| brew-maintenance | Sun 09:00 | Homebrew update/cleanup |
| obsidian-weekly-note | Mon 00:05 | Generate weekly planning note |

## Private config

Scripts that need private values (ntfy URL, Pi hostname) source from
`~/.config/dotfiles/env`. Copy `dotfiles.env.example` on first setup.

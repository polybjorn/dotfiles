# dotfiles

Cross-platform dotfiles managed by
[chezmoi](https://www.chezmoi.io/) for user configs and
[Ansible](https://www.ansible.com/) for server infrastructure.
Designed to scale across machines — new platforms are added via
chezmoi templates and Ansible inventory.

## Quick start

### New machine (chezmoi)

```sh
# macOS
brew install chezmoi
chezmoi init polybjorn/dotfiles --apply

# Linux
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply polybjorn/dotfiles
```

### Existing setup

```sh
ln -sfn ~/repositories/dotfiles ~/.local/share/chezmoi
chezmoi apply
```

### Server infrastructure (Ansible, from Mac)

```sh
cp linux/ansible/vars/private.yml.example linux/ansible/vars/private.yml
# Edit private.yml with your values
ansible-playbook linux/ansible/site.yml
```

## Architecture

```
chezmoi (all machines)            Ansible (servers, from Mac over SSH)
  ~/.zshenv                        /usr/local/bin/* (scripts)
  ~/.config/zsh/                   /etc/systemd/system/* (timers)
  ~/.config/git/                   /etc/nginx/sites-available/* (templates)
  ~/.local/bin/* (scripts)         /etc/ntfy/server.yml (template)
  ~/.hammerspoon/ (macOS)          /etc/cloudflared/config.yml (template)
  ~/Library/LaunchAgents/ (macOS)  /etc/default/stats-api (secrets)
```

chezmoi handles `$HOME` files on every machine, using templates and
`.chezmoiignore` for platform differences (`{{ if eq .chezmoi.os "darwin" }}`).
Ansible handles system-level server files, deploying from Mac via SSH.
Secrets are separated: chezmoi uses age encryption, Ansible uses a gitignored vars file.

## What's included

### Shared (all platforms)
- Zsh with Powerlevel10k, ZDOTDIR at `~/.config/zsh/`
- Cross-platform aliases with `$OSTYPE` branching
- Cross-platform scripts: pkg-maintenance, ntfy, backup-status, syncthing-status
- XDG Base Directory layout

### macOS
- Hammerspoon window management (MiroWindowsManager)
- LaunchAgent scheduled tasks
- Homebrew Brewfile (auto-installed via chezmoi `run_after_`)
- macOS system defaults (opt-in)
- Photo sorting, Obsidian automation

### Server infrastructure (Ansible-managed)
- Server scripts (backup, health check, FreshRSS, nightmode, etc.)
- Systemd services and timers
- Nginx reverse proxy configs (Ansible Jinja2 templates)
- Server configs (ntfy, cloudflared, unattended-upgrades, radicale, etc.)
- Dashboard stats API

## Scheduled tasks

### macOS (LaunchAgents)

| Agent | Schedule | Purpose |
|---|---|---|
| backup-claude | On file change | CLAUDE.md backup to Vault |
| backup | 03:00 daily | Config tarball to Vault |
| health-check | 08:00 daily | System diagnostics, ntfy alerts |
| stats-push | Every 5 min | Push stats to Pi dashboard |
| pkg-maintenance | Sun 09:00 | Package update/cleanup |
| obsidian-new-year | Jan 1 09:00 | Create yearly/quarterly/monthly note structure |
| obsidian-weekly-note | Mon 00:05 | Generate weekly planning note |
| vault-maintenance-weekly | Mon 01:00 | Orphan fixer + broken link check |
| vault-maintenance-monthly | 1st 02:00 | Frontmatter audit + tag scan |

### Linux (systemd timers)

| Timer | Schedule | Purpose |
|---|---|---|
| health-check | Every 4h | System diagnostics, ntfy alerts |
| backup | 02:30 daily | Full server backup |
| pkg-maintenance | Sun 09:00 | Package update/cleanup |
| nightmode | 01:00-07:00 | Disable/enable nginx sites |
| freshrss-refresh | */15 07-23h | FreshRSS feed refresh |
| freshrss-digest | Mon 08:00 | Weekly release/feed report |
| wifi-watchdog | Every 2 min | WiFi reconnection |

## Repo structure

```
dotfiles/                              # chezmoi source directory
├── dot_zshenv                         # → ~/.zshenv
├── dot_gitconfig                      # → ~/.gitconfig
├── dot_zprofile.tmpl                  # → ~/.zprofile (templated per platform)
├── private_dot_config/
│   ├── zsh/                           # shell config (ZDOTDIR)
│   ├── git/                           # git config + ignore
│   └── dotfiles/create_env            # private env (created once, never overwritten)
├── private_dot_hammerspoon/           # macOS only
├── dot_local/bin/                     # user scripts (chezmoi-managed)
│   ├── executable_pkg-maintenance.sh  # cross-platform (brew/apt)
│   ├── executable_backup.sh           # macOS backup
│   ├── executable_health-check.sh     # macOS health check
│   └── ...
├── run_after_*                        # chezmoi hooks (p10k, LaunchAgents, Brewfile)
├── macos/
│   ├── launchd/                       # LaunchAgent plists
│   └── defaults.sh                    # macOS system preferences
├── linux/
│   ├── scripts/                       # server scripts → /usr/local/bin/
│   ├── systemd/                       # systemd units + overrides
│   ├── config/                        # server configs (apt, logrotate, etc.)
│   └── ansible/
│       ├── site.yml                   # main playbook
│       ├── roles/
│       │   ├── scripts/               # symlink scripts
│       │   ├── systemd/               # copy units, enable timers
│       │   ├── nginx/templates/       # Jinja2 nginx configs
│       │   ├── configs/templates/     # Jinja2 ntfy + cloudflared configs
│       │   ├── dashboard/             # symlink pi-dashboard
│       │   └── sudoers/               # timer control permissions
│       └── vars/
│           ├── private.yml.example    # template for secrets
│           └── private.yml            # actual secrets (gitignored)
└── Brewfile                           # Homebrew packages
```

## Private config

**chezmoi** creates `~/.config/dotfiles/env` on first apply (never overwrites).
Edit with private values (ntfy URL, Pi hostname).

**Ansible** uses `linux/ansible/vars/private.yml` (gitignored) for server secrets
(Tailscale hostname, Syncthing API key, Cloudflare tunnel ID).
Copy `private.yml.example` and fill in your values.

**age encryption** is available for chezmoi-managed secrets
(key at `~/.config/chezmoi/key.txt`).

## Conventions

- chezmoi manages `$HOME` files; Ansible manages system files on servers
- Templates handle platform differences (`{{ if eq .chezmoi.os "darwin" }}`)
- New platforms: add OS-specific blocks to templates + entries in `.chezmoiignore`
- LaunchAgent plists and systemd units are copied, not symlinked
- Cross-platform scripts use `$OSTYPE` branching
- `set -euo pipefail` and 2-space indentation for bash scripts
- Private values never committed — sourced from env files or Ansible vars

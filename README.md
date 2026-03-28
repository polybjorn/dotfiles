# dotfiles

Cross-platform dotfiles managed by
[chezmoi](https://www.chezmoi.io/) for user configs and
[Ansible](https://www.ansible.com/) for server infrastructure.
Designed to scale across machines. New platforms are added via
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
cd linux/ansible && ansible-playbook site.yml
```

Ansible manages Pi, arch-server, and Proxmox from Mac over SSH. Three plays in `site.yml`:
- **Pi**: sshd, scripts, systemd, nginx, configs, dashboard, sudoers, fail2ban, authorized_keys
- **Arch-server**: sshd, scripts, systemd, fail2ban, authorized_keys, sudoers (NOPASSWD)
- **Proxmox**: sshd, scripts, systemd, authorized_keys (runs as root)

```sh
ansible-playbook site.yml --limit pi        # Pi only
ansible-playbook site.yml --limit arch      # arch-server only
ansible-playbook site.yml --tags systemd    # only deploy timers/services
ansible-playbook site.yml --check           # dry-run, no changes
```

## Architecture

```
chezmoi (all machines)            Ansible (servers, from Mac over SSH)
  ~/.zshenv                        /etc/ssh/sshd_config (template)
  ~/.ssh/config                    /usr/local/bin/* (scripts)
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
- SSH aliases: `pi`, `arch`, `prox`, `mac` (hop between machines from anywhere)
- Cross-platform scripts: pkg-maintenance, ntfy, backup-status, syncthing-status
- XDG Base Directory layout
- SSH config with key pinning, multiplexing (ControlMaster), keepalive
- Global git pre-commit hook: gitleaks secret scan + PII pattern scan

### macOS
- Hammerspoon window management (MiroWindowsManager)
- LaunchAgent scheduled tasks
- Homebrew Brewfile (auto-installed via chezmoi `run_after_`)
- macOS system defaults (opt-in) - includes firewall + stealth mode
- Photo sorting

### Pi server (Ansible-managed)
- sshd hardening (key-only auth, no root login, AllowUsers)
- fail2ban intrusion detection (SSH + nginx jails)
- Per-host SSH key management (authorized_keys)
- Server scripts (backup, health check, FreshRSS, nightmode, etc.)
- Systemd services and timers
- Nginx reverse proxy configs (Jinja2 templates)
- Server configs (ntfy, cloudflared, unattended-upgrades, radicale, etc.)
- Dashboard stats API

### Arch-server (Ansible-managed)
- sshd hardening (key-only auth, no root login, AllowUsers)
- fail2ban intrusion detection (SSH jail)
- Per-host SSH key management (authorized_keys)
- NOPASSWD sudo for admin
- Server scripts (backup, pkg-maintenance, video-cleanup, qbt-cleanup, music-cleanup)
- Systemd services and timers
- Postgres, Sonarr, Prowlarr, Bazarr, Navidrome, Paperless, SABnzbd, Jellyfin, Samba

### Proxmox (Ansible-managed)
- sshd hardening (key-only auth, root via key only, AllowUsers)
- Per-host SSH key management (authorized_keys)
- Server scripts (backup, health check, pkg-maintenance)
- Systemd services and timers

## Scheduled tasks

### macOS (LaunchAgents)

| Agent | Schedule | Purpose |
|---|---|---|
| backup-claude | On file change | CLAUDE.md backup to Vault |
| backup | 09:00 daily | Config tarball to Vault |
| backup-verify | 09:15 daily | Verify backup freshness |
| health-check | 09:10 daily | System diagnostics, ntfy alerts |
| stats-push | Every 5 min | Push stats to Pi dashboard |
| pkg-maintenance | Sun 10:00 | Package update/cleanup |
| obsidian-new-year | Jan 1 09:00 | Create yearly/quarterly/monthly note structure |
| obsidian-weekly-note | Mon 09:15 | Generate weekly planning note |
| photo-sort | Every 30 min | Sort photos by EXIF date |
| downloads-sort | Fri 09:00 | Sort downloads into Vault/Inbox |
| res-filters | On file change | Rebuild RES subreddit filter backup |
| vault-maintenance-weekly | Mon 09:30 | Orphan fixer + broken link check |
| vault-maintenance-monthly | 1st 09:45 | Frontmatter audit + tag scan |

### Pi (systemd timers)

| Timer | Schedule | Purpose |
|---|---|---|
| health-check | Every 4h | System diagnostics, ntfy alerts |
| backup | 02:30 daily | Full server backup |
| pkg-maintenance | Sun 09:00 | Package update/cleanup |
| nightmode | 01:00-07:00 | Disable/enable nginx sites |
| freshrss-refresh | */15 07-23h | FreshRSS feed refresh |
| freshrss-digest | Mon 08:00 | Weekly release/feed report |
| freshrss-autoupdate | 09:00 daily | Auto-update RSS-Bridge & FreshRSS |
| freshrss-yt-favicons | 1st 05:00 | YouTube favicon refresh |
| rss-bridge-cache-cleanup | 04:00 daily | RSS-Bridge cache cleanup |
| wifi-watchdog | Every 2 min | WiFi reconnection |

### Arch-server (systemd timers)

| Timer | Schedule | Purpose |
|---|---|---|
| backup-arch | 03:00 daily | Postgres, configs, app data backup |
| health-check-arch | Every 4h | System diagnostics, ntfy alerts |
| pkg-maintenance | Sun 09:00 | Package update/cleanup |
| video-cleanup | Monthly | Strip unwanted audio/subtitle tracks, remux legacy containers |
| qbt-cleanup | Daily | Clean up qBittorrent torrents |

### Proxmox (systemd timers)

| Timer | Schedule | Purpose |
|---|---|---|
| backup-proxmox | 02:00 daily | Host configs + ZFS metadata backup |
| health-check-proxmox | Every 4h | System diagnostics, ntfy alerts |
| pkg-maintenance | Sun 09:00 | Package update/cleanup |

## Repo structure

```
dotfiles/                              # chezmoi source directory
├── dot_zshenv                         # → ~/.zshenv
├── dot_gitconfig                      # → ~/.gitconfig
├── dot_zprofile.tmpl                  # → ~/.zprofile (templated per platform)
├── private_dot_ssh/
│   ├── config                         # → ~/.ssh/config (multiplexing, key pinning)
│   └── private_sockets/               # → ~/.ssh/sockets/ (ControlMaster)
├── private_dot_config/
│   ├── zsh/                           # shell config (ZDOTDIR)
│   ├── git/                           # git config + ignore
│   └── dotfiles/encrypted_env.age     # private env (age-encrypted)
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
│       │   ├── sshd/templates/        # sshd_config hardening (all hosts)
│       │   ├── fail2ban/templates/    # fail2ban jails (Pi + arch)
│       │   ├── authorized_keys/       # per-host SSH key management
│       │   ├── configs/templates/     # Jinja2 ntfy + cloudflared configs
│       │   ├── dashboard/             # symlink pi-dashboard
│       │   └── sudoers/               # timer control permissions
│       └── vars/
│           ├── private.yml.example    # template for secrets
│           ├── private.yml            # actual secrets (gitignored)
│           └── ssh_keys.yml           # SSH public keys per host
└── Brewfile                           # Homebrew packages
```

## Private config

**chezmoi** decrypts `encrypted_env.age` to `~/.config/dotfiles/env` on apply.
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
- Private values never committed, sourced from env files or Ansible vars

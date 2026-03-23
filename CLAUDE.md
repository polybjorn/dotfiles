# dotfiles

HEAD
Cross-platform dotfiles repo for macOS and Linux (Raspberry Pi, Proxmox, arch-server).
Managed by **chezmoi** (user configs) and **Ansible** (server infra).

## Repo structure

```
dotfiles/                              # chezmoi source directory
├── .chezmoi.toml.tmpl                 # chezmoi config (OS detection, age encryption)
├── .chezmoiignore                     # skip non-chezmoi files + platform filtering
├── dot_zshenv                         # → ~/.zshenv (ZDOTDIR + XDG)
├── dot_gitconfig                      # → ~/.gitconfig (includes local.gitconfig)
├── dot_zprofile.tmpl                  # → ~/.zprofile (templated: Homebrew on Mac)
├── private_dot_config/
│   ├── zsh/
│   │   ├── dot_zshrc                  # → ~/.config/zsh/.zshrc
│   │   └── aliases.zsh               # → ~/.config/zsh/aliases.zsh
│   ├── git/
│   │   ├── ignore                     # → ~/.config/git/ignore
│   │   ├── local.gitconfig.tmpl       # → ~/.config/git/local.gitconfig (bat/gh paths)
│   │   ├── pii-patterns.tmpl          # → ~/.config/git/pii-patterns (PII scan patterns)
│   │   └── hooks/
│   │       └── executable_pre-commit  # → ~/.config/git/hooks/pre-commit (gitleaks + PII)
│   └── dotfiles/
│       └── encrypted_env.age          # → ~/.config/dotfiles/env (age-encrypted)
├── private_dot_hammerspoon/           # macOS only (.chezmoiignore)
│   ├── init.lua
│   └── Spoons/MiroWindowsManager.spoon/
├── dot_local/bin/                     # → ~/.local/bin/*
│   ├── executable_ntfy                # cross-platform
│   ├── executable_backup-status       # cross-platform
│   ├── executable_syncthing-status    # cross-platform
│   ├── executable_pkg-maintenance.sh   # cross-platform (brew/pacman/apt)
│   ├── executable_backup.sh           # macOS only (.chezmoiignore)
│   ├── executable_health-check.sh     # macOS only
│   ├── executable_stats-push.sh       # macOS only
│   └── executable_photo-sort.sh       # macOS only
├── run_after_10-p10k.sh.tmpl         # deploy platform-specific p10k config
├── run_after_20-launchagents.sh.tmpl  # macOS: copy plists + load
├── run_after_30-brewfile.sh.tmpl      # macOS: brew bundle
├── p10k/                             # p10k configs (deployed by run_after)
│   ├── darwin.zsh
│   └── linux.zsh
├── macos/
│   ├── launchd/                       # LaunchAgent plists (copied by run_after)
│   └── defaults.sh                    # macOS system preferences (opt-in)
├── linux/
│   ├── scripts/                       # Server scripts → /usr/local/bin/
│   ├── systemd/                       # systemd units (copies) + overrides/
│   ├── config/                        # server configs (apt, logrotate, etc.)
│   ├── ansible/                       # Ansible playbook + roles
│   │   ├── roles/nginx/templates/     # nginx site configs (Jinja2)
│   │   ├── roles/configs/templates/   # ntfy + cloudflared configs (Jinja2)
│   │   ├── roles/sshd/               # SSH server hardening (all hosts)
│   │   ├── roles/fail2ban/            # intrusion detection (Pi + arch)
│   │   ├── roles/authorized_keys/     # per-host SSH key management
│   │   ├── vars/private.yml           # secrets (gitignored)
│   │   └── vars/ssh_keys.yml          # SSH public keys per host
│   └── install.sh                     # legacy fallback (no-dependency)
├── Brewfile                           # Homebrew packages
├── bootstrap.sh                       # legacy fallback (pre-chezmoi)
└── dotfiles.env.example               # Template for private config
```

## Deployment

### User configs (chezmoi)

```sh
# First time (fresh machine):
brew install chezmoi
chezmoi init polybjorn/dotfiles --apply

# Existing setup (repo at ~/repositories/dotfiles/):
ln -sfn ~/repositories/dotfiles ~/.local/share/chezmoi
chezmoi apply
```

chezmoi replaces symlinks with managed file copies. Templates handle
platform differences (`.zprofile`, `local.gitconfig`). `run_after_` scripts
handle LaunchAgents, p10k, and Brewfile.

### Server infrastructure (Ansible)

```sh
cd ~/repositories/dotfiles
ansible-playbook linux/ansible/site.yml              # all servers
ansible-playbook linux/ansible/site.yml --limit pi    # Pi only
ansible-playbook linux/ansible/site.yml --limit arch  # arch-server only
ansible-playbook linux/ansible/site.yml --limit proxmox  # Proxmox only
```

Runs from Mac over SSH. Pi and arch-server require `--ask-become-pass` (password-based sudo).
Pi play: sshd, scripts, systemd, nginx, configs, dashboard, sudoers, fail2ban, authorized_keys.
Arch play: sshd, scripts, systemd, fail2ban, authorized_keys, sudo (password required).
Proxmox play: sshd, scripts, systemd, authorized_keys (runs as root).
Dry-run: `ansible-playbook linux/ansible/site.yml --check --diff`

### Legacy fallbacks

- `bootstrap.sh` — pre-chezmoi user config deployer (kept for reference)
- `linux/install.sh` — pre-Ansible server deployer (kept as no-dependency fallback)

## Conventions

- chezmoi manages `$HOME` files with templates for platform branching
- Ansible manages system-level files (`/etc/`, `/usr/local/bin/`)
- LaunchAgent plists use `__HOME__` placeholder, substituted with `$HOME` at deploy time
- Global pre-commit hook: gitleaks (secrets) + PII scan (patterns from chezmoi template)
- Health-check validates hook and PII patterns file are deployed
- Never hardcode home paths in committed files — use `__HOME__`, `$HOME`, or chezmoi templates
- Systemd units: COPIED (systemctl disable deletes symlinks)
- Private values sourced from `~/.config/dotfiles/env`
- age encryption available for secrets (key at `~/.config/chezmoi/key.txt`)
- 2-space indentation, `set -euo pipefail` for bash scripts

## macOS LaunchAgents

| Agent | Schedule | Script |
|---|---|---|
| backup-claude | WatchPaths | /bin/cp (no script) |
| backup | 09:00 daily | backup.sh |
| backup-verify | 09:05 daily | backup-verify.sh |
| health-check | 09:10 daily | health-check.sh |
| stats-push | Every 5 min | stats-push.sh |
| pkg-maintenance | Sun 10:00 | pkg-maintenance.sh |
| obsidian-new-year | Jan 1 09:00 | obsidian-new-year.sh |
| obsidian-weekly-note | Mon 09:15 | obsidian-weekly-note.py |
| photo-sort | Every 30 min | photo-sort.sh |
| vault-maintenance-weekly | Mon 09:30 | vault-maintenance.py |
| vault-maintenance-monthly | 1st 09:45 | vault-maintenance.py |

## Pi systemd timers

| Timer | Schedule | Script |
|---|---|---|
| health-check | Every 4h | health-check.sh |
| backup | 02:30 daily | backup.sh |
| pkg-maintenance | Sun 09:00 | pkg-maintenance.sh (chezmoi) |
| nightmode-on/off | 01:00 / 07:00 | nightmode.sh |
| freshrss-refresh | */15 07-23h | (PHP actualize) |
| freshrss-digest | Mon 08:00 | freshrss-digest.sh |
| freshrss-autoupdate | 09:00 daily | freshrss-autoupdate.sh |
| freshrss-yt-favicons | 1st 05:00 | freshrss-yt-favicons.sh |
| rss-bridge-cache-cleanup | 04:00 daily | rss-bridge-cache-cleanup.sh |
| wifi-watchdog | Every 2 min | wifi-watchdog.sh |
| gpx-manifest | Path watcher | gpx-manifest.sh |

## Arch server systemd timers

| Timer | Schedule | Script |
|---|---|---|
| backup-arch | 03:00 daily | backup-arch.sh |
| health-check-arch | Every 4h | health-check-arch.sh |
| pkg-maintenance | Sun 09:00 | pkg-maintenance.sh (chezmoi) |

## Proxmox systemd timers

| Timer | Schedule | Script |
|---|---|---|
| backup-proxmox | 02:00 daily | backup-proxmox.sh |
| health-check-proxmox | Every 4h | health-check-proxmox.sh |
| pkg-maintenance | Sun 09:00 | pkg-maintenance.sh (chezmoi) |

## Key paths

- Repo / chezmoi source: `~/repositories/dotfiles/` (symlinked from `~/.local/share/chezmoi`)
- Dashboard: `~/repositories/pi-dashboard/`
- Private config: `~/.config/dotfiles/env` (chezmoi, age-encrypted)
- Platform git overrides: `~/.config/git/local.gitconfig` (chezmoi template)
- User scripts: `~/.local/bin/` (chezmoi-managed copies)
- Server scripts: `/usr/local/bin/` (Ansible symlinks, Pi + arch-server + Proxmox)
- ZDOTDIR: `~/.config/zsh/`
- age key: `~/.config/chezmoi/key.txt`

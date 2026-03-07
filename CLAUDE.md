# dotfiles

Cross-platform dotfiles repo for macOS and Linux (Raspberry Pi).
Managed by **chezmoi** (user configs) and **Ansible** (Pi server infra).

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
│   │   └── local.gitconfig.tmpl       # → ~/.config/git/local.gitconfig (bat/gh paths)
│   └── dotfiles/
│       └── create_env                 # → ~/.config/dotfiles/env (create if missing)
├── private_dot_hammerspoon/           # macOS only (.chezmoiignore)
│   ├── init.lua
│   └── Spoons/MiroWindowsManager.spoon/
├── dot_local/bin/                     # → ~/.local/bin/*
│   ├── executable_ntfy                # cross-platform
│   ├── executable_backup-status       # cross-platform
│   ├── executable_syncthing-status    # cross-platform
│   ├── executable_pkg-maintenance.sh   # cross-platform (brew/apt)
│   ├── executable_backup.sh           # macOS only (.chezmoiignore)
│   ├── executable_health-check.sh     # macOS only
│   ├── executable_stats-push.sh       # macOS only
│   ├── executable_photo-sort.sh       # macOS only
│   └── executable_obsidian-*.sh/py    # macOS only
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
│   ├── scripts/                       # Pi server scripts → /usr/local/bin/
│   ├── systemd/                       # systemd units (copies) + overrides/
│   ├── config/                        # server configs (apt, logrotate, etc.)
│   ├── ansible/                       # Ansible playbook + roles
│   │   ├── roles/nginx/templates/     # nginx site configs (Jinja2)
│   │   ├── roles/configs/templates/   # ntfy + cloudflared configs (Jinja2)
│   │   └── vars/private.yml           # secrets (gitignored)
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

### Pi server infrastructure (Ansible)

```sh
cd ~/repositories/dotfiles
ansible-playbook linux/ansible/site.yml
```

Runs from Mac over SSH. Manages scripts, systemd, nginx, configs, dashboard, sudoers.
Dry-run: `ansible-playbook linux/ansible/site.yml --check --diff`

### Legacy fallbacks

- `bootstrap.sh` — pre-chezmoi user config deployer (kept for reference)
- `linux/install.sh` — pre-Ansible server deployer (kept as no-dependency fallback)

## Conventions

- chezmoi manages `$HOME` files with templates for platform branching
- Ansible manages system-level files (`/etc/`, `/usr/local/bin/`)
- LaunchAgent plists: COPIED (launchd removes symlinks on unload)
- Systemd units: COPIED (systemctl disable deletes symlinks)
- Private values sourced from `~/.config/dotfiles/env`
- age encryption available for secrets (key at `~/.config/chezmoi/key.txt`)
- 2-space indentation, `set -euo pipefail` for bash scripts

## macOS LaunchAgents

| Agent | Schedule | Script |
|---|---|---|
| backup-claude | WatchPaths | /bin/cp (no script) |
| backup | 03:00 daily | backup.sh |
| health-check | 08:00 daily | health-check.sh |
| stats-push | Every 5 min | stats-push.sh |
| pkg-maintenance | Sun 09:00 | pkg-maintenance.sh |
| obsidian-weekly-note | Mon 00:05 | obsidian-weekly-note.py |
| obsidian-new-year | Jan 1 09:00 | obsidian-new-year.sh |
| photo-sort | Every 30 min | photo-sort.sh |

## Pi systemd timers

| Timer | Schedule | Script |
|---|---|---|
| health-check | Every 4h | health-check.sh |
| backup | 02:30 daily | backup.sh |
| pkg-maintenance | Sun 09:00 | pkg-maintenance.sh (chezmoi) |
| nightmode-on/off | 01:00 / 07:00 | nightmode.sh |
| freshrss-refresh | */15 07-23h | (PHP actualize) |
| freshrss-digest | Mon 08:00 | freshrss-digest.sh |
| freshrss-yt-favicons | 1st 05:00 | freshrss-yt-favicons.sh |
| rss-bridge-cache-cleanup | 04:00 daily | rss-bridge-cache-cleanup.sh |
| wifi-watchdog | Every 2 min | wifi-watchdog.sh |

## Key paths

- Repo / chezmoi source: `~/repositories/dotfiles/` (symlinked from `~/.local/share/chezmoi`)
- Dashboard: `~/repositories/pi-dashboard/`
- Private config: `~/.config/dotfiles/env` (chezmoi `create_` — never overwrites)
- Platform git overrides: `~/.config/git/local.gitconfig` (chezmoi template)
- User scripts: `~/.local/bin/` (chezmoi-managed copies)
- Server scripts: `/usr/local/bin/` (Ansible symlinks, Pi only)
- ZDOTDIR: `~/.config/zsh/`
- age key: `~/.config/chezmoi/key.txt`

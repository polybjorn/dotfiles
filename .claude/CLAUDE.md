# dotfiles — Claude Code instructions

Cross-platform dotfiles managed by chezmoi (user configs) and Ansible (server infra).
Currently: macOS + Raspberry Pi + Proxmox + Arch Linux (arch-server). Planned: Windows.

## Architecture

- **chezmoi** manages `$HOME` files on all machines — templates + `.chezmoiignore` for platform differences
- **Ansible** manages system-level files on servers (`/etc/`, `/usr/local/bin/`) — deployed from Mac over SSH
- **Secrets**: chezmoi uses age encryption, Ansible uses gitignored `linux/ansible/vars/private.yml`

## Key files

- `.chezmoi.toml.tmpl` — chezmoi config (age encryption, OS flags)
- `.chezmoiignore` — platform gating (darwin/linux/windows blocks)
- `linux/ansible/site.yml` — main Ansible playbook
- `linux/ansible/inventory.ini` — Ansible host inventory
- `linux/ansible/vars/private.yml` — secrets (gitignored, copy from `.example`)
- `linux/ansible/vars/ssh_keys.yml` — SSH public keys per host (not secret)
- `linux/ansible/roles/` — sshd, scripts, systemd, nginx, configs, dashboard, sudoers, fail2ban, authorized_keys

## Conventions

- **Always `git pull` before making changes** — repo is edited from multiple devices
- chezmoi prefix conventions: `dot_`, `private_dot_`, `executable_`, `create_`, `run_after_`, `.tmpl`
- LaunchAgent plists and systemd units are COPIED, not symlinked (both systems delete symlinks)
- Platform branching: `{{ if eq .chezmoi.os "darwin" }}` in templates, `$OSTYPE` in scripts
- Ansible templates (`.j2`) use variables from `vars/private.yml` for secrets
- `set -euo pipefail` and 2-space indentation for all bash scripts
- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`

## Adding a new platform

1. **chezmoi**: add `{{ if eq .chezmoi.os "..." }}` blocks to templates, add ignore rules to `.chezmoiignore`
2. **Ansible** (servers only): add host to `inventory.ini`, create host group, add playbook or extend `site.yml` with `when:` conditionals
3. **Scripts**: use `$OSTYPE` branching in cross-platform scripts, or create platform-specific scripts gated by `.chezmoiignore`

## Testing changes

- `chezmoi diff` — preview what chezmoi would change
- `chezmoi apply --dry-run` — simulate apply
- `ansible-playbook site.yml --check --diff` — Ansible dry run
- CI runs `chezmoi init --dry-run` and `ansible-playbook --syntax-check` on push

## Secrets — never commit

- `linux/ansible/vars/private.yml` (Tailscale hostname, Syncthing API key, Cloudflare tunnel ID)
- `~/.config/dotfiles/env` (ntfy URL, Pi hostname)
- `~/.config/chezmoi/key.txt` (age private key)

# Shared aliases — cross-platform (macOS + Linux)
# Platform-specific sections use: if [[ "$OSTYPE" == darwin* ]]

# ── Navigation ────────────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias cd='z'
alias ls='eza --icons --group-directories-first'
alias l='eza -la --icons --group-directories-first --git'
alias ll='eza -lah --icons --group-directories-first --git'
alias la='eza -A --icons --group-directories-first'
alias lt='eza --tree --icons --level=2'
alias ltt='eza --tree --icons --level=3'

# ── Docker (~/docker/docker-compose.yml) ─────────────────
alias dpull='docker compose -f ~/docker/docker-compose.yml pull'
alias dup='docker compose -f ~/docker/docker-compose.yml up -d'
alias ddown='docker compose -f ~/docker/docker-compose.yml down'
alias dlogs='docker compose -f ~/docker/docker-compose.yml logs -f'
alias dps='docker compose -f ~/docker/docker-compose.yml ps'
alias dres='docker compose -f ~/docker/docker-compose.yml restart'
alias dexec='docker compose -f ~/docker/docker-compose.yml exec'

# ── bat / fd ─────────────────────────────────────────────
if [[ "$OSTYPE" == darwin* ]]; then
  alias cat='bat --paging=never'
  alias batp='bat'
  alias bat-themes='bat --list-themes | fzf --preview="bat --theme={} --color=always ${ZDOTDIR}/.zshrc"'
  alias fd='fd --hidden --follow'
else
  alias cat='batcat --paging=never'
  alias batp='batcat'
  alias fd='fdfind --hidden --follow'
fi
alias ccat='/bin/cat'
alias ffd='/usr/bin/find'

# ── ripgrep ──────────────────────────────────────────────
alias grep='grep --color=auto'
alias rg='rg --smart-case'
alias rgl='rg -l'
alias rgt='rg --type'

# ── System ───────────────────────────────────────────────
alias diskuse='df -h'
alias myip='curl -s ifconfig.me && echo'

if [[ "$OSTYPE" == darwin* ]]; then
  alias update='softwareupdate -ia && brew update && brew upgrade && brew cleanup'
  alias ports='lsof -iTCP -sTCP:LISTEN -nP'
  alias flushdns='sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder'
  alias services='launchctl list'
  alias usersvcs='launchctl list | grep -v "com.apple"'
  alias brewsvcs='brew services list'
  alias memuse='top -l 1 -s 0 | head -n 12'
  alias cpuuse='ps aux | sort -nrk 3,3 | head -n 10'
  alias wifi='networksetup -getairportnetwork en0'
  alias localip='ipconfig getifaddr en0'
else
  alias update='sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y'
  alias ports='ss -tlnp'
  alias services='systemctl list-units --type=service --state=running'
  alias memuse='free -h'
  alias cpuuse='ps aux --sort=-%cpu | head -n 10'
  alias localip="ip -4 addr show | grep inet | grep -v '127.0.0.1' | awk '{print \$2}'"
  alias temp='vcgencmd measure_temp'
  alias throttle='vcgencmd get_throttled'
fi

# ── SSH (mac only) ───────────────────────────────────────
if [[ "$OSTYPE" == darwin* ]]; then
  alias pi='ssh admin@${PI_HOST:-pi-server}'
  alias deploy='cd ~/repositories/polybjorn-en && git add . && git commit -m "Update" && git push origin main'

  # ── chezmoi + Ansible ──────────────────────────────────
  alias cm='chezmoi'
  alias cma='chezmoi apply'
  alias cmd='chezmoi diff'
  alias cme='chezmoi edit'
  alias cms='chezmoi status'
  alias ans='cd ~/repositories/dotfiles/linux/ansible && ansible-playbook site.yml'
  alias anst='cd ~/repositories/dotfiles/linux/ansible && ansible-playbook site.yml --tags'
  alias ansc='cd ~/repositories/dotfiles/linux/ansible && ansible-playbook site.yml --check'
  alias pideploy='ssh admin@${PI_HOST:-pi-server} "cd ~/repositories/dotfiles && git pull" && ans'
fi

# ── Convenience ─────────────────────────────────────────
alias mkdir='mkdir -pv'
alias c='clear'
alias sn='sudo nano'
alias reload='source ${ZDOTDIR}/.zshrc'
alias zshrc='${EDITOR:-nano} ${ZDOTDIR}/.zshrc'
alias aliases='${EDITOR:-nano} ${ZDOTDIR}/aliases.zsh'
alias path='echo $PATH | tr ":" "\n"'

# ── Claude Code ─────────────────────────────────────────
alias cc='cd ~/code && claude'
alias ccc='claude -c'
alias ccr='claude --resume'
alias ccp='claude -p'
alias ccup='claude update'
alias ccdoc='claude /doctor'
alias ccv='claude --version'
alias ccexplain='claude -p "explain this code"'
alias ccreview='claude -p "review this code for bugs and improvements"'
alias ccfix='claude -p "find and fix bugs in this code"'
alias cctest='claude -p "write tests for this code"'
alias ccdiff='git diff | claude -p "review this diff"'

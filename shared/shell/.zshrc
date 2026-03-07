# ── Environment ──────────────────────────────────────────
export HISTFILE="${ZDOTDIR}/.zsh_history"
export EDITOR="nano"
export PATH="$HOME/.local/bin:$PATH"

# ── nvm ─────────────────────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# ── Powerlevel10k ────────────────────────────────────────
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi
if [[ "$OSTYPE" == darwin* ]]; then
  source /opt/homebrew/share/powerlevel10k/powerlevel10k.zsh-theme
elif [[ -f "${ZDOTDIR}/powerlevel10k/powerlevel10k.zsh-theme" ]]; then
  source "${ZDOTDIR}/powerlevel10k/powerlevel10k.zsh-theme"
fi
[[ ! -f "${ZDOTDIR}/.p10k.zsh" ]] || source "${ZDOTDIR}/.p10k.zsh"

# ── History ──────────────────────────────────────────────
HISTSIZE=100000
SAVEHIST=100000
setopt EXTENDED_HISTORY
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_FIND_NO_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY
setopt SHARE_HISTORY

# ── Shell behaviour ─────────────────────────────────────
setopt AUTO_CD
setopt CORRECT
setopt GLOB_DOTS

# ── Plugins ──────────────────────────────────────────────
if [[ "$OSTYPE" == darwin* ]]; then
  ZSH_PLUGIN_DIR="/opt/homebrew/share"
elif [[ -d "${ZDOTDIR}/plugins" ]]; then
  ZSH_PLUGIN_DIR="${ZDOTDIR}/plugins"
else
  ZSH_PLUGIN_DIR="/usr/share"
fi
source "$ZSH_PLUGIN_DIR/zsh-autosuggestions/zsh-autosuggestions.zsh"
source "$ZSH_PLUGIN_DIR/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
source "$ZSH_PLUGIN_DIR/zsh-history-substring-search/zsh-history-substring-search.zsh"

# ── Completion ───────────────────────────────────────────
[[ -d "$HOME/.docker/completions" ]] && fpath=($HOME/.docker/completions $fpath)
[[ -d "$ZSH_PLUGIN_DIR/zsh-completions/src" ]] && fpath=($ZSH_PLUGIN_DIR/zsh-completions/src $fpath)
autoload -Uz compinit
if [[ -n ${ZDOTDIR}/.zcompdump(#qN.mh+24) ]]; then
  compinit
else
  compinit -C
fi
zstyle ':completion:*' menu select
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'

# ── bat ──────────────────────────────────────────────────
export BAT_THEME="Catppuccin Mocha"
if [[ "$OSTYPE" == darwin* ]]; then
  export MANPAGER="sh -c 'col -bx | bat -l man -p'"
else
  export MANPAGER="sh -c 'col -bx | batcat -l man -p'"
fi
export MANROFFOPT="-c"
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

# ── FZF ──────────────────────────────────────────────────
if [[ "$OSTYPE" == darwin* ]]; then
  source <(fzf --zsh)
else
  [[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]] && source /usr/share/doc/fzf/examples/key-bindings.zsh
  [[ -f /usr/share/doc/fzf/examples/completion.zsh ]] && source /usr/share/doc/fzf/examples/completion.zsh
fi

# ── Zoxide ───────────────────────────────────────────────
eval "$(zoxide init zsh)"

# ── Aliases ──────────────────────────────────────────────
[[ -f "${ZDOTDIR}/aliases.zsh" ]] && source "${ZDOTDIR}/aliases.zsh"

# ── Local overrides ──────────────────────────────────────
[[ -f "${ZDOTDIR}/local.zsh" ]] && source "${ZDOTDIR}/local.zsh"

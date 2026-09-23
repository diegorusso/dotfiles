#!/usr/bin/env bash

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias -- -='cd -'

alias g=git
alias vi=nvim
alias vim=nvim
alias week='date +%V'
alias reload='exec "$BASH" -l'
alias c=copy

# Detect GNU and BSD ls without assuming the host OS.
if command ls --color=auto -d . >/dev/null 2>&1; then
	alias ls='command ls --color=auto'
	alias l='command ls -lF --color=auto'
	alias la='command ls -lAF --color=auto'
else
	alias ls='command ls -G'
	alias l='command ls -lF -G'
	alias la='command ls -lAF -G'
fi

# GNU and modern BSD grep both accept --color; leave older implementations
# untouched rather than breaking every grep invocation.
grep --color=auto -e '__dotfiles_no_match__' /dev/null >/dev/null 2>&1
_dotfiles_grep_status=$?
if (( _dotfiles_grep_status <= 1 )); then
	alias grep='grep --color=auto'
fi
unset _dotfiles_grep_status

if ! command -v hd >/dev/null 2>&1 && command -v hexdump >/dev/null 2>&1; then
	alias hd='hexdump -C'
fi

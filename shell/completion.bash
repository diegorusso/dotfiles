#!/usr/bin/env bash

# bash-completion 2.x requires Bash 4.2. Keep the rest of the interactive
# configuration usable with macOS's system Bash 3.2 by skipping it there.
if (( BASH_VERSINFO[0] > 4 || \
	BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2 )); then
	if [[ -n ${HOMEBREW_PREFIX:-} && \
		-r "$HOMEBREW_PREFIX/etc/profile.d/bash_completion.sh" ]]; then
		# shellcheck source=/dev/null
		source "$HOMEBREW_PREFIX/etc/profile.d/bash_completion.sh"
	elif [[ -r /usr/share/bash-completion/bash_completion ]]; then
		# shellcheck source=/dev/null
		source /usr/share/bash-completion/bash_completion
	elif [[ -r /etc/bash_completion ]]; then
		# shellcheck source=/dev/null
		source /etc/bash_completion
	fi
fi

if declare -F _git >/dev/null 2>&1; then
	complete -o default -o nospace -F _git g
fi

if [[ -r "$HOME/.ssh/config" ]]; then
	_dotfiles_ssh_hosts=$(
		awk '
			tolower($1) == "host" {
				for (i = 2; i <= NF; i++) {
					if ($i !~ /[?*!]/) print $i
				}
			}
		' "$HOME/.ssh/config"
	)
	complete -o default -o nospace -W "$_dotfiles_ssh_hosts" scp sftp ssh
	unset _dotfiles_ssh_hosts
fi

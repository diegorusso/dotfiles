#!/usr/bin/env bash

# Machine-, role-, employer-, and secret shell settings live in one local file.
[[ -z ${DOTFILES_LOCAL_SHELL_LOADED:-} ]] || return 0
DOTFILES_LOCAL_SHELL_LOADED=1

_dotfiles_shell_overlay="$HOME/.config/extra"

if [[ -e $_dotfiles_shell_overlay || -L $_dotfiles_shell_overlay ]]; then
	if [[ -f $_dotfiles_shell_overlay && -r $_dotfiles_shell_overlay ]]; then
		# shellcheck source=/dev/null
		source "$_dotfiles_shell_overlay"
	else
		printf 'Local shell overlay is not a readable file: %s\n' \
			"$_dotfiles_shell_overlay" >&2
	fi
fi

unset _dotfiles_shell_overlay

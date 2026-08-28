#!/usr/bin/env bash

[[ $- == *i* ]] || return 0
[[ -z ${DOTFILES_INTERACTIVE_LOADED:-} ]] || return 0
DOTFILES_INTERACTIVE_LOADED=1

shopt -s nocaseglob histappend cdspell
for _dotfiles_option in autocd globstar; do
	shopt -s "$_dotfiles_option" 2>/dev/null || true
done
unset _dotfiles_option

_dotfiles_shell_dir=${BASH_SOURCE[0]%/*}

# shellcheck source=/dev/null
source "$_dotfiles_shell_dir/functions.bash"
# shellcheck source=/dev/null
source "$_dotfiles_shell_dir/aliases.bash"
# shellcheck source=/dev/null
source "$_dotfiles_shell_dir/completion.bash"

case "${DOTFILES_OS:-unknown}" in
	macos)
		# shellcheck source=/dev/null
		source "$_dotfiles_shell_dir/platform/macos.bash"
		;;
	linux)
		# shellcheck source=/dev/null
		source "$_dotfiles_shell_dir/platform/linux.bash"
		;;
esac

if [[ -t 0 ]] && command -v tty >/dev/null 2>&1; then
	_dotfiles_tty=$(tty 2>/dev/null) || _dotfiles_tty=
	if [[ -n $_dotfiles_tty && $_dotfiles_tty != 'not a tty' ]]; then
		export GPG_TTY=$_dotfiles_tty
	fi
	unset _dotfiles_tty
fi

if command -v starship >/dev/null 2>&1; then
	eval "$(starship init bash)"
fi

unset _dotfiles_shell_dir

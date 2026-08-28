#!/usr/bin/env bash

# This file is sourced by both login and interactive non-login Bash shells.
[[ -z ${DOTFILES_ENV_LOADED:-} ]] || return 0
DOTFILES_ENV_LOADED=1

_dotfiles_path_prepend() {
	local directory=$1
	[[ -d $directory ]] || return 0
	case ":${PATH:-}:" in
		*":${directory}:"*) ;;
		*) PATH="${directory}${PATH:+:${PATH}}" ;;
	esac
}

case "$(uname -s 2>/dev/null)" in
	Darwin) export DOTFILES_OS=macos ;;
	Linux) export DOTFILES_OS=linux ;;
	*) export DOTFILES_OS=unknown ;;
esac

# Locate Homebrew without assuming Intel macOS, Apple Silicon, or Linuxbrew.
_dotfiles_brew=
if command -v brew >/dev/null 2>&1; then
	_dotfiles_brew=$(command -v brew)
else
	for _dotfiles_candidate in \
		/opt/homebrew/bin/brew \
		/usr/local/bin/brew \
		/home/linuxbrew/.linuxbrew/bin/brew; do
		if [[ -x $_dotfiles_candidate ]]; then
			_dotfiles_brew=$_dotfiles_candidate
			break
		fi
	done
fi

if [[ -n $_dotfiles_brew ]]; then
	# Homebrew emits portable exports for its actual installation prefix.
	eval "$("$_dotfiles_brew" shellenv bash)"
fi

_dotfiles_path_prepend "$HOME/bin"
_dotfiles_path_prepend "$HOME/.local/bin"
_dotfiles_path_prepend /usr/local/sbin

if [[ -n ${HOMEBREW_PREFIX:-} ]]; then
	_dotfiles_path_prepend "$HOMEBREW_PREFIX/opt/gettext/bin"
	_dotfiles_path_prepend "$HOMEBREW_PREFIX/opt/sqlite/bin"
fi
export PATH

if [[ -z ${EDITOR:-} ]]; then
	if command -v nvim >/dev/null 2>&1; then
		export EDITOR=nvim
	else
		export EDITOR=vi
	fi
fi
export VISUAL="${VISUAL:-$EDITOR}"

export NODE_REPL_HISTORY="${NODE_REPL_HISTORY:-$HOME/.node_history}"
export NODE_REPL_HISTORY_SIZE="${NODE_REPL_HISTORY_SIZE:-32768}"
export NODE_REPL_MODE="${NODE_REPL_MODE:-sloppy}"

export HISTSIZE="${HISTSIZE:-32768}"
export HISTFILESIZE="${HISTFILESIZE:-$HISTSIZE}"
export HISTCONTROL="${HISTCONTROL:-ignoreboth}"

# Prefer the user's chosen British English locale when the host provides it,
# but never force LC_ALL or select a locale that would produce startup errors.
if command -v locale >/dev/null 2>&1 && \
	locale -a 2>/dev/null | grep -Eiq '^en_GB\.(UTF-?8|utf8)$'; then
	export LANG=en_GB.UTF-8
fi

export MANPAGER="${MANPAGER:-less -X}"

if [[ $DOTFILES_OS == macos ]]; then
	export BASH_SILENCE_DEPRECATION_WARNING=1
fi

unset _dotfiles_brew _dotfiles_candidate
unset -f _dotfiles_path_prepend

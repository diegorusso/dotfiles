# shellcheck shell=bash

# Preserve host- or administrator-provided login setup. A guard in .bashrc
# prevents a conventional .profile from initializing the interactive layer
# early when it sources .bashrc itself.
if [[ -z ${DOTFILES_PROFILE_LOADED:-} && -r "$HOME/.profile" ]]; then
	DOTFILES_PROFILE_LOADED=1
	# Read by .bashrc while the separately managed .profile is being sourced.
	# shellcheck disable=SC2034
	DOTFILES_LOADING_PROFILE=1
	# shellcheck source=/dev/null
	source "$HOME/.profile"
	unset DOTFILES_LOADING_PROFILE
fi

# Environment belongs in login shells; prompts, aliases, and completions do not.
if [[ -r "$HOME/.config/dotfiles/shell/env.bash" ]]; then
	# shellcheck source=/dev/null
	source "$HOME/.config/dotfiles/shell/env.bash"
fi

# Bash does not read .bashrc for login shells, so load it explicitly when the
# login shell is interactive.
if [[ $- == *i* && -r "$HOME/.bashrc" ]]; then
	# shellcheck source=/dev/null
	source "$HOME/.bashrc"
fi

# Interactive shells normally load the local overlay from .bashrc; the guard in
# local.bash makes this second source a no-op and also supports non-interactive
# login shells.
if [[ -r "$HOME/.config/dotfiles/shell/local.bash" ]]; then
	# shellcheck source=/dev/null
	source "$HOME/.config/dotfiles/shell/local.bash"
fi

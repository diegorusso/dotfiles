# shellcheck shell=bash

# Do not initialize prompts, aliases, or completions for scripts and remote
# non-interactive commands.
[[ -z ${DOTFILES_LOADING_PROFILE:-} ]] || return 0
[[ $- == *i* ]] || return 0

if [[ -r "$HOME/.config/dotfiles/shell/env.bash" ]]; then
	# shellcheck source=/dev/null
	source "$HOME/.config/dotfiles/shell/env.bash"
fi

if [[ -r "$HOME/.config/dotfiles/shell/interactive.bash" ]]; then
	# shellcheck source=/dev/null
	source "$HOME/.config/dotfiles/shell/interactive.bash"
fi

# Load the machine-local overlay last so it can replace shared aliases,
# functions, environment values, or other interactive settings.
if [[ -r "$HOME/.config/dotfiles/shell/local.bash" ]]; then
	# shellcheck source=/dev/null
	source "$HOME/.config/dotfiles/shell/local.bash"
fi

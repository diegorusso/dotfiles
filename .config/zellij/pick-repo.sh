#!/usr/bin/env bash
set -euo pipefail

fail() {
	printf '%s\n' "$*" >&2
	if [[ -t 0 ]]; then
		IFS= read -r -p 'Press Enter to close. ' || true
	fi
	exit 1
}

[[ -n ${ZELLIJ_SESSION_NAME:-} ]] || fail 'Open the repository picker inside Zellij'
for dependency in git fzf jq zellij; do
	command -v "$dependency" >/dev/null 2>&1 || fail "Repository picker requires $dependency"
done

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=${DOTFILES_REPO_ROOT:-$HOME/repos}
case $root in
	\~) root=$HOME ;;
	\~/*) root="$HOME/${root:2}" ;;
esac
[[ -d $root ]] || fail 'Set DOTFILES_REPO_ROOT to your repository parent directory'

rows=
seen=$'\n'
add_checkout() {
	local directory primary=$2 label branch
	[[ -d $1 ]] || return 0
	# The trailing slash preserves newlines until the delimiter check below.
	directory=$(CDPATH='' cd -P -- "$1" && printf '%s/' "$PWD") || return 0
	directory=${directory%/}
	[[ $directory != *$'\n'* && $directory != *$'\t'* ]] || return 0
	[[ $seen != *$'\n'"$directory"$'\n'* ]] || return 0
	seen+="$directory"$'\n'
	label=${directory##*/}
	if [[ -n $primary && $directory != "$primary" ]]; then
		label="${primary##*/}/$label"
	fi
	branch=$(git -C "$directory" symbolic-ref --quiet --short HEAD 2>/dev/null ||
		git -C "$directory" rev-parse --short HEAD 2>/dev/null || true)
	[[ -z $branch ]] || label+=" [$branch]"
	rows+="$directory"$'\t'"${label//[[:cntrl:]]/}"$'\n'
}

shopt -s nullglob
for repository in "$root"/*; do
	[[ -d $repository ]] || continue
	primary=
	while IFS= read -r -d '' field; do
		[[ $field == 'worktree '* ]] || continue
		directory=${field#worktree }
		if [[ -z $primary ]]; then
			primary=$directory
			add_checkout "$repository" "$primary"
		fi
		add_checkout "$directory" "$primary"
	done < <(git -C "$repository" worktree list --porcelain -z 2>/dev/null || true)
	[[ -n $primary ]] || add_checkout "$repository" ''
done
[[ -n $rows ]] || exit 0

status=0
selection=$(fzf --delimiter=$'\t' --with-nth=2.. --reverse --prompt='Repo / worktree> ' \
	<<<"${rows%$'\n'}") || status=$?
case $status in
	0) ;;
	1|130) exit 0 ;;
	*) fail 'Repository picker failed' ;;
esac
[[ $'\n'$rows == *$'\n'"$selection"$'\n'* ]] || fail 'The selected checkout is no longer available'
directory=${selection%%$'\t'*}
label=${selection#*$'\t'}
[[ -d $directory ]] || fail 'The selected checkout is no longer available'

panes=$(zellij --session "$ZELLIJ_SESSION_NAME" action list-panes --json |
	jq -c '[.[] | select(.is_plugin == false and .is_floating == false and .pane_cwd != null)]') ||
	fail 'Could not inspect open repository tabs'
while IFS= read -r -d '' tab_id && IFS= read -r -d '' pane_directory; do
	# Resolve subdirectories to their checkout, keeping separate worktrees distinct.
	pane_checkout=$(git -C "$pane_directory" rev-parse --show-toplevel 2>/dev/null ||
		printf '%s' "$pane_directory")
	pane_checkout=$(CDPATH='' cd -P -- "$pane_checkout" 2>/dev/null && printf '%s/' "$PWD") || continue
	[[ ${pane_checkout%/} == "$directory" ]] || continue
	zellij --session "$ZELLIJ_SESSION_NAME" action go-to-tab-by-id "$tab_id" >/dev/null ||
		fail 'Could not switch to the repository tab'
	exit 0
done < <(jq -j '.[] | .tab_id, "\u0000", .pane_cwd, "\u0000"' <<<"$panes")

zellij --session "$ZELLIJ_SESSION_NAME" action new-tab \
	--layout "$script_dir/layouts/repo.kdl" --cwd "$directory" --name "$label" >/dev/null ||
	fail 'Could not open the repository tab'

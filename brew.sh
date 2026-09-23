#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: ./brew.sh [--dry-run | --apply]

  --dry-run  Check the shared and matching platform bundles (the default).
  --apply    Install missing dependencies without running `brew upgrade`.

Linux uses Brewfile. macOS also uses macos/Brewfile for system tools and casks.
On Debian-family Linux, existing system commands and optional APT removals are reported.
EOF
}

mode=dry-run

while (( $# > 0 )); do
	case $1 in
		--dry-run) mode=dry-run ;;
		--apply) mode=apply ;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			printf 'Unknown option: %s\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
	shift
done

repo_dir=$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
bundles=("$repo_dir/Brewfile")
platform=$(uname -s)
case $platform in
	Darwin) bundles+=("$repo_dir/macos/Brewfile") ;;
	Linux) ;;
	*)
		printf 'brew.sh supports macOS and Linux.\n' >&2
		exit 1
		;;
esac

if ! command -v brew >/dev/null 2>&1; then
	printf 'Homebrew is not on PATH. Run ./bootstrap.sh --apply, then start a new Bash login shell.\n' >&2
	exit 1
fi

if [[ $platform == Linux ]] && command -v dpkg-query >/dev/null 2>&1 && \
	command -v apt-get >/dev/null 2>&1; then
	if brew_prefix=$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix) && \
		"$repo_dir/linux/brew-check.sh" "$brew_prefix"; then
		:
	else
		printf 'Unable to complete the system-package check; continuing with the Homebrew bundle.\n' >&2
	fi
fi

status=0
for bundle in "${bundles[@]}"; do
	printf '%s %s\n' "$mode" "$bundle"
	if [[ $mode == apply ]]; then
		HOMEBREW_NO_AUTO_UPDATE=1 \
		brew bundle install --no-upgrade --file="$bundle"
	elif ! HOMEBREW_NO_AUTO_UPDATE=1 \
		brew bundle check --no-upgrade --verbose --file="$bundle"; then
		status=1
	fi
done

if [[ $mode == dry-run ]]; then
	printf '\nDry run only. Re-run with --apply to install missing dependencies.\n'
fi

exit "$status"

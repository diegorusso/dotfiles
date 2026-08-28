#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: ./macos/brew.sh [--dry-run | --apply]

  --dry-run  Check and print the package bundle (the default).
  --apply    Install missing dependencies without running `brew upgrade`.
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

if [[ $(uname -s) != Darwin ]]; then
	printf 'macos/brew.sh only supports macOS; use linux/packages.txt on Debian-family Linux.\n' >&2
	exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
	printf 'Homebrew is not installed. Review the current installer at https://brew.sh/\n' >&2
	exit 1
fi

macos_dir=$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)
bundle="$macos_dir/Brewfile"

status=0
printf '%s %s\n' "$mode" "$bundle"
if [[ $mode == apply ]]; then
	HOMEBREW_NO_AUTO_UPDATE=1 \
	brew bundle install --no-upgrade --file="$bundle"
elif ! HOMEBREW_NO_AUTO_UPDATE=1 \
	brew bundle check --no-upgrade --verbose --file="$bundle"; then
	status=1
fi

if [[ $mode == dry-run ]]; then
	printf '\nDry run only. Re-run with --apply to install missing dependencies.\n'
fi

exit "$status"

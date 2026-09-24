#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: ./brew.sh [--dry-run | --apply] [--personal | --work]

  --dry-run  Refresh Homebrew, then check the matching bundles (the default).
  --apply    Install missing dependencies without running `brew upgrade`.
  --personal On macOS, include the personal application bundle.
  --work     On macOS, include the work application bundle.

Linux uses Brewfile. macOS also uses the core macos/Brewfile. Select exactly
one application profile when wanted; without one, only core packages are used.
On Debian-family Linux, existing system commands and optional APT removals are reported.
EOF
}

mode=dry-run
machine_profile=core

while (( $# > 0 )); do
	case $1 in
		--dry-run) mode=dry-run ;;
		--apply) mode=apply ;;
		--personal|--work)
			selected_profile=${1#--}
			if [[ $machine_profile != core && $machine_profile != "$selected_profile" ]]; then
				printf 'Choose only one of --personal or --work.\n' >&2
				exit 2
			fi
			machine_profile=$selected_profile
			;;
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
	Darwin)
		bundles+=("$repo_dir/macos/Brewfile")
		if [[ $machine_profile != core ]]; then
			bundles+=("$repo_dir/macos/Brewfile.$machine_profile")
		fi
		;;
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

# Keep Homebrew itself current before suppressing Bundle's automatic update.
# This matters after a macOS upgrade: older Homebrew releases may not know the
# new macOS version and fail before they can inspect either Brewfile. This does
# does not install packages from the Brewfiles in dry-run mode, though Homebrew
# may perform migrations needed by the new macOS version while updating itself.
printf 'Updating Homebrew metadata\n'
brew update --auto-update

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
	elif ! output=$(HOMEBREW_NO_AUTO_UPDATE=1 \
		brew bundle check --no-upgrade --verbose --file="$bundle" 2>&1); then
		printf '%s\n' "$output" >&2
		if [[ $platform == Darwin && $output == *'unknown or unsupported macOS version'* ]]; then
			printf '%s\n' 'Homebrew still does not recognise this macOS release after updating.' >&2
		fi
		status=1
	else
		printf '%s\n' "$output"
	fi
done

if [[ $mode == dry-run ]]; then
	printf '\nDry run only. Re-run with --apply to install missing dependencies.\n'
fi

exit "$status"

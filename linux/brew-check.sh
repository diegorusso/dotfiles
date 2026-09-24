#!/usr/bin/env bash

# Report existing commands before brew.sh installs the shared Linux tools.
# Package ownership queries are read-only; removal commands are printed only.
set -euo pipefail

repo_dir=$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)
brew_prefix=${1:?Homebrew prefix is required}
brew_prefix=$(readlink -f -- "$brew_prefix" 2>/dev/null) || brew_prefix=$1
brew_prefix=${brew_prefix%/}

find_package_owner() {
	local executable=$1 resolved=$2 lookup_path ownership line owner
	local lookup_paths=("$resolved" "$executable")
	# Older dpkg databases may record /bin while the merged filesystem uses /usr/bin.
	case $resolved in
		/usr/bin/*|/usr/sbin/*) lookup_paths+=("${resolved#/usr}") ;;
	esac
	for lookup_path in "${lookup_paths[@]}"; do
		ownership=$(LC_ALL=C dpkg-query -S -- "$lookup_path" 2>/dev/null) || continue
		while IFS= read -r line; do
			[[ ${line#*: } == "$lookup_path" ]] || continue
			owner=${line%%: *}
			# Ignore diversions and ambiguous ownership; retain architecture qualifiers.
			[[ $owner =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9][a-z0-9-]*)?$ ]] || continue
			printf '%s\n' "$owner"
			return 0
		done <<<"$ownership"
	done
	return 1
}

seen_paths=()
apt_packages=()
reported=false
while IFS= read -r formula; do
	case $formula in
		bash-completion@*) continue ;; # Shell data, not an executable.
		neovim) binary=nvim ;;
		ripgrep) binary=rg ;;
		tree-sitter-cli) binary=tree-sitter ;;
		python|python@*) binary=python3 ;;
		*) binary=${formula%%@*} ;;
	esac
	while IFS= read -r executable; do
		resolved=$(readlink -f -- "$executable" 2>/dev/null) || resolved=$executable
		case $executable in "$brew_prefix"/*) continue ;; esac
		case $resolved in "$brew_prefix"/*) continue ;; esac
		already_seen=false
		for seen in "${seen_paths[@]:-}"; do
			if [[ $seen == "$resolved" ]]; then already_seen=true; break; fi
		done
		[[ $already_seen == false ]] || continue
		seen_paths+=("$resolved")
		if [[ $reported == false ]]; then
			printf 'Commands already installed outside Homebrew:\n'
			reported=true
		fi
		printf '  %s: %s' "$binary" "$executable"
		if ! owner=$(find_package_owner "$executable" "$resolved"); then
			printf ' (no unambiguous dpkg owner; no APT removal suggestion)\n'
			continue
		fi
		printf ' (APT package: %s)\n' "$owner"
		if ! metadata=$(dpkg-query -W -f='${db:Status-Status}|${Essential}|${Protected}' \
			-- "$owner" 2>/dev/null); then
			printf '    Keep: unable to verify package status.\n'
			continue
		fi
		IFS='|' read -r package_status essential protected <<<"$metadata"
		if [[ $package_status != installed ]]; then
			printf '    Keep: dpkg does not report a fully installed package.\n'
			continue
		fi
		if [[ $essential == yes || $protected == yes ]]; then
			printf '    Keep: essential or protected system package.\n'
			continue
		fi
		case $formula in
			bash|python|python@*)
				printf '    Keep: system shell or Python runtime.\n'
				continue
				;;
			et)
				printf '    Keep: Eternal Terminal also provides the remote-access server.\n'
				continue
				;;
		esac
		if grep -Fxq -- "${owner%%:*}" "$repo_dir/linux/packages.txt"; then
			printf '    Keep: listed in linux/packages.txt for system use or Homebrew setup.\n'
			continue
		fi
		case " ${apt_packages[*]-} " in
			*" $owner "*) ;;
			*) apt_packages+=("$owner") ;;
		esac
	done < <(type -aP "$binary" || true)
done < <(awk -F '"' '/^brew "[A-Za-z0-9@+._-]+"$/ { print $2 }' "$repo_dir/Brewfile")

if (( ${#apt_packages[@]} > 0 )); then
	printf '\nAfter installing and testing the Homebrew replacements, preview optional APT removals:\n'
	printf '  sudo apt-get --simulate remove --'
	printf ' %q' "${apt_packages[@]}"
	printf '\nReview every package APT would remove. If the complete removal list is acceptable:\n'
	printf '  sudo apt-get remove --'
	printf ' %q' "${apt_packages[@]}"
	printf '\n'
fi
if [[ $reported == true ]]; then
	printf 'This check only reports existing commands; it does not remove packages.\n\n'
fi

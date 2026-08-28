#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: ./macos/defaults.sh [--dry-run | --apply]

  --dry-run  Print the curated user-default changes (the default).
  --apply    Back up affected preference domains, apply changes, and restart
             Finder and Dock.

Privileged, power-management, hardware-specific, and employer-managed settings
are deliberately outside this shared user-defaults script.
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
	printf 'This script only supports macOS.\n' >&2
	exit 1
fi

run() {
	printf '  '
	printf '%q ' "$@"
	printf '\n'
	if [[ $mode == apply ]]; then
		"$@"
	fi
}

write_default() {
	run defaults write "$@"
}

if [[ $mode == apply ]]; then
	umask 077
	timestamp=$(date -u +%Y%m%dT%H%M%SZ)
	backup_parent="$HOME/.local/state/dotfiles/macos-defaults"
	backup_dir="$backup_parent/$timestamp"
	backup_suffix=0
	while [[ -e $backup_dir ]]; do
		backup_suffix=$((backup_suffix + 1))
		backup_dir="$backup_parent/${timestamp}-${backup_suffix}"
	done
	if [[ -L $backup_parent || ( -e $backup_parent && ! -d $backup_parent ) ]]; then
		printf 'Backup path is not a normal directory: %s\n' "$backup_parent" >&2
		exit 1
	fi
	mkdir -p "$backup_parent" "$backup_dir"
	chmod 700 "$backup_parent" "$backup_dir"
	for domain in NSGlobalDomain com.apple.finder com.apple.dock \
		com.apple.desktopservices com.apple.Safari; do
		if defaults export "$domain" "$backup_dir/$domain.plist" >/dev/null 2>&1; then
			continue
		fi
		if defaults read "$domain" >/dev/null 2>&1; then
			printf 'Unable to back up existing preference domain: %s\n' "$domain" >&2
			exit 1
		fi
		printf 'No existing preference domain: %s\n' "$domain" >"$backup_dir/$domain.absent"
	done
	printf 'Preference backup: %s\n' "$backup_dir"
else
	printf 'Dry-run preference changes:\n'
fi

# Keyboard and global UI.
write_default NSGlobalDomain KeyRepeat -int 1
write_default NSGlobalDomain InitialKeyRepeat -int 10
write_default NSGlobalDomain AppleShowAllExtensions -bool true

# Finder and filesystem metadata behavior.
write_default com.apple.finder ShowExternalHardDrivesOnDesktop -bool true
write_default com.apple.finder ShowHardDrivesOnDesktop -bool true
write_default com.apple.finder ShowMountedServersOnDesktop -bool true
write_default com.apple.finder ShowRemovableMediaOnDesktop -bool true
write_default com.apple.finder ShowStatusBar -bool true
write_default com.apple.finder ShowPathbar -bool true
write_default com.apple.finder _FXShowPosixPathInTitle -bool true
write_default com.apple.finder FXDefaultSearchScope -string SCcf
write_default com.apple.finder FXPreferredViewStyle -string Nlsv
write_default com.apple.desktopservices DSDontWriteNetworkStores -bool true
write_default com.apple.desktopservices DSDontWriteUSBStores -bool true

# Dock animation and hot corners retained from the actively used configuration.
write_default com.apple.dock expose-animation-duration -float 0.1
write_default com.apple.dock wvous-tl-corner -int 2
write_default com.apple.dock wvous-tl-modifier -int 0
write_default com.apple.dock wvous-tr-corner -int 12
write_default com.apple.dock wvous-tr-modifier -int 0
write_default com.apple.dock wvous-bl-corner -int 4
write_default com.apple.dock wvous-bl-modifier -int 0
write_default com.apple.dock wvous-br-corner -int 5
write_default com.apple.dock wvous-br-modifier -int 0

# Small, still-relevant Safari defaults. Deeper WebKit and retired application
# keys from the previous archive have intentionally been removed.
write_default com.apple.Safari ShowFullURLInSmartSearchField -bool true
write_default com.apple.Safari AutoOpenSafeDownloads -bool false
write_default com.apple.Safari IncludeDevelopMenu -bool true
write_default com.apple.Safari WebKitDeveloperExtrasEnabledPreferenceKey -bool true
write_default NSGlobalDomain WebKitDeveloperExtras -bool true
write_default com.apple.Safari WarnAboutFraudulentWebsites -bool true

if [[ $mode == apply ]]; then
	killall Finder >/dev/null 2>&1 || true
	killall Dock >/dev/null 2>&1 || true
	printf 'Applied. Some applications may need to be reopened.\n'
else
	printf '\nDry run only. Re-run with --apply after reviewing these commands.\n'
fi

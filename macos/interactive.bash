#!/usr/bin/env bash

localip() {
	local interface
	interface=$(route get default 2>/dev/null | awk '/interface:/{print $2; exit}')
	[[ -n $interface ]] || {
		printf 'Unable to determine the default interface\n' >&2
		return 1
	}
	ipconfig getifaddr "$interface"
}

cdf() {
	cd "$(osascript -e 'tell application "Finder" to POSIX path of (insertion location as alias)')" || return
}

flush_dns() {
	sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
}

show_hidden_files() {
	defaults write com.apple.finder AppleShowAllFiles -bool true && killall Finder
}

hide_hidden_files() {
	defaults write com.apple.finder AppleShowAllFiles -bool false && killall Finder
}

hide_desktop() {
	defaults write com.apple.finder CreateDesktop -bool false && killall Finder
}

show_desktop() {
	defaults write com.apple.finder CreateDesktop -bool true && killall Finder
}

if [[ -x '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' ]]; then
	chrome() {
		'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' "$@"
	}
fi
[[ -x /usr/libexec/PlistBuddy ]] && alias plistbuddy=/usr/libexec/PlistBuddy

command -v defaults >/dev/null 2>&1 && complete -W NSGlobalDomain defaults

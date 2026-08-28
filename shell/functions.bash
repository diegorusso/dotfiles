#!/usr/bin/env bash

mkd() {
	if (( $# != 1 )); then
		printf 'usage: mkd DIRECTORY\n' >&2
		return 2
	fi
	mkdir -p -- "$1" || return
	cd -- "$1" || return
}

targz() {
	if (( $# != 1 )); then
		printf 'usage: targz PATH\n' >&2
		return 2
	fi
	local source_path=${1%/}
	local archive="${source_path}.tar.gz"
	tar -czf "$archive" -- "$source_path" || return
	printf '%s created\n' "$archive"
}

fs() {
	if (( $# == 0 )); then
		du -sh .
	else
		du -sh "$@"
	fi
}

dataurl() {
	if (( $# != 1 )) || [[ ! -f $1 ]]; then
		printf 'usage: dataurl FILE\n' >&2
		return 2
	fi
	command -v file >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || {
		printf 'dataurl requires file and openssl\n' >&2
		return 127
	}
	local mime_type
	mime_type=$(file -b --mime-type "$1") || return
	[[ $mime_type == text/* ]] && mime_type="${mime_type};charset=utf-8"
	printf 'data:%s;base64,' "$mime_type"
	openssl base64 -A -in "$1"
	printf '\n'
}

server() {
	if (( $# > 1 )); then
		printf 'usage: server [PORT]\n' >&2
		return 2
	fi
	local port=${1:-8000}
	[[ $port =~ ^[0-9]+$ ]] || {
		printf 'usage: server [PORT]\n' >&2
		return 2
	}
	command -v python3 >/dev/null 2>&1 || {
		printf 'server requires python3\n' >&2
		return 127
	}
	printf 'Serving %s at http://localhost:%s/\n' "$PWD" "$port"
	python3 -m http.server "$port" --bind 127.0.0.1
}

urlencode() {
	if (( $# != 1 )); then
		printf 'usage: urlencode STRING\n' >&2
		return 2
	fi
	command -v python3 >/dev/null 2>&1 || {
		printf 'urlencode requires python3\n' >&2
		return 127
	}
	python3 -c 'import sys; from urllib.parse import quote_plus; print(quote_plus(sys.argv[1]))' "$1"
}

gz() {
	if (( $# != 1 )) || [[ ! -f $1 ]]; then
		printf 'usage: gz FILE\n' >&2
		return 2
	fi
	local original compressed
	original=$(wc -c <"$1") || return
	compressed=$(gzip -c -- "$1" | wc -c) || return
	awk -v original="$original" -v compressed="$compressed" 'BEGIN {
		ratio = original == 0 ? 0 : compressed * 100 / original
		printf "original: %d bytes\ngzip: %d bytes (%.2f%%)\n", original, compressed, ratio
	}'
}

digga() {
	if (( $# != 1 )); then
		printf 'usage: digga DOMAIN\n' >&2
		return 2
	fi
	command -v dig >/dev/null 2>&1 || {
		printf 'digga requires dig\n' >&2
		return 127
	}
	dig +nocmd "$1" any +multiline +noall +answer
}

getcertnames() {
	if (( $# != 1 )); then
		printf 'usage: getcertnames DOMAIN\n' >&2
		return 2
	fi
	command -v openssl >/dev/null 2>&1 || {
		printf 'getcertnames requires openssl\n' >&2
		return 127
	}
	local certificate
	certificate=$(openssl s_client -connect "$1:443" -servername "$1" </dev/null 2>/dev/null) || return
	printf '%s\n' "$certificate" | openssl x509 -noout -subject
	printf '%s\n' "$certificate" | openssl x509 -noout -text |
		awk '/Subject Alternative Name/{getline; sub(/^[[:space:]]+/, ""); print}'
}

o() {
	if (( $# > 1 )); then
		printf 'usage: o [PATH_OR_URL]\n' >&2
		return 2
	fi
	local target=${1:-.}
	if [[ ${DOTFILES_OS:-} == macos ]] && command -v open >/dev/null 2>&1; then
		open "$target"
	elif command -v wslview >/dev/null 2>&1; then
		wslview "$target"
	elif command -v xdg-open >/dev/null 2>&1 && [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
		xdg-open "$target"
	else
		printf 'No graphical opener is available in this session\n' >&2
		return 127
	fi
}

copy() {
	if command -v pbcopy >/dev/null 2>&1; then
		pbcopy
	elif command -v wl-copy >/dev/null 2>&1 && [[ -n ${WAYLAND_DISPLAY:-} ]]; then
		wl-copy
	elif command -v xclip >/dev/null 2>&1 && [[ -n ${DISPLAY:-} ]]; then
		xclip -selection clipboard
	elif [[ -n ${TMUX:-} ]] && command -v tmux >/dev/null 2>&1; then
		tmux load-buffer -w -
	else
		printf 'No supported clipboard command is available\n' >&2
		return 127
	fi
}

myip() {
	if command -v dig >/dev/null 2>&1; then
		dig +short myip.opendns.com @resolver1.opendns.com
	elif command -v curl >/dev/null 2>&1; then
		curl --fail --silent --show-error https://api.ipify.org
		printf '\n'
	else
		printf 'myip requires dig or curl\n' >&2
		return 127
	fi
}

path() {
	printf '%s\n' "$PATH" | tr ':' '\n'
}

tre() {
	command -v tree >/dev/null 2>&1 || {
		printf 'tre requires tree\n' >&2
		return 127
	}
	command -v less >/dev/null 2>&1 || {
		printf 'tre requires less\n' >&2
		return 127
	}
	tree -aC -I '.git|node_modules|bower_components' --dirsfirst "$@" | less -FRNX
}

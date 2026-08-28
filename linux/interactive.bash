#!/usr/bin/env bash

localip() {
	if command -v ip >/dev/null 2>&1; then
		ip -brief address show scope global | awk '{print $1, $3}'
	elif command -v hostname >/dev/null 2>&1; then
		hostname -I
	else
		printf 'localip requires ip or hostname\n' >&2
		return 127
	fi
}

ifactive() {
	command -v ip >/dev/null 2>&1 || {
		printf 'ifactive requires ip\n' >&2
		return 127
	}
	ip -brief link show up
}

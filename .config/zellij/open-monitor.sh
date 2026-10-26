#!/usr/bin/env bash
set -euo pipefail

if [[ -z ${ZELLIJ_SESSION_NAME:-} ]]; then
	printf 'Open the monitor from inside Zellij.\n' >&2
	exit 1
fi

tabs=$(zellij --session "$ZELLIJ_SESSION_NAME" action query-tab-names)
while IFS= read -r tab; do
	if [[ $tab == monitor ]]; then
		exec zellij --session "$ZELLIJ_SESSION_NAME" action go-to-tab-name monitor
	fi
done <<< "$tabs"

exec zellij --session "$ZELLIJ_SESSION_NAME" action new-tab \
	--layout "${BASH_SOURCE[0]%/*}/layouts/monitor.kdl" --cwd "$HOME"

#!/usr/bin/env bash
set -eu

BASE="${1:-$HOME/repos}"
PRESET="${2:-default}"

if [ ! -d "$BASE" ]; then
  tmux display-message "Not a directory: $BASE"
  exit 1
fi

DIR="$(
  find "$BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
  sort |
  fzf --prompt="Repo> " --height=40% --reverse
)"

[ -n "${DIR:-}" ] || exit 0

"$HOME/.tmux/layouts/dev-3cols.sh" "$BASE/$DIR" "$PRESET"

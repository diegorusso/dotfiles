#!/usr/bin/env bash
set -euo pipefail

message() {
  if command -v tmux >/dev/null 2>&1 && [ -n "${TMUX:-}" ]; then
    tmux display-message "$*" 2>/dev/null || printf '%s\n' "$*" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}

for dependency in sort fzf; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    message "Repository picker requires '$dependency'."
    exit 1
  fi
done

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
LAYOUT="$SCRIPT_DIR/dev-3cols.sh"

if [ ! -x "$LAYOUT" ]; then
  message "Development layout is missing or not executable: $LAYOUT"
  exit 1
fi

BASE="${1:-}"
if [ -z "$BASE" ] && command -v tmux >/dev/null 2>&1 && [ -n "${TMUX:-}" ]; then
  BASE="$(tmux show-option -gqv @repo-root 2>/dev/null || true)"
fi
BASE="${BASE:-${TMUX_REPO_ROOT:-$HOME/repos}}"

if [ ! -d "$BASE" ]; then
  message "Repository root is not a directory: $BASE"
  exit 1
fi

BASE="$(CDPATH='' cd -- "$BASE" && pwd -P)"

# A shell glob avoids GNU-only `find -printf` and also includes repositories
# reached through directory symlinks. Hidden directories are intentionally
# omitted from the interactive list.
DIR="$(
  for path in "$BASE"/*; do
    [ -d "$path" ] || continue
    printf '%s\n' "${path##*/}"
  done |
    LC_ALL=C sort |
    fzf --prompt='Repo> ' --height=40% --reverse
)" || exit 0

[ -n "${DIR:-}" ] || exit 0

"$LAYOUT" "$BASE/$DIR"

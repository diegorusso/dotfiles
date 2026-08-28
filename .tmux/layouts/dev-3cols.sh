#!/usr/bin/env bash
set -euo pipefail

DIR="${1:-$HOME}"

message() {
  tmux display-message "$*" 2>/dev/null || printf '%s\n' "$*" >&2
}

if ! command -v tmux >/dev/null 2>&1; then
  printf 'Development layout requires tmux.\n' >&2
  exit 1
fi

if [ -z "${TMUX:-}" ]; then
  printf 'Development layout must be run from inside tmux.\n' >&2
  exit 1
fi

if [ ! -d "$DIR" ]; then
  message "Not a directory: $DIR"
  exit 1
fi

DIR="$(CDPATH='' cd -- "$DIR" && pwd -P)"

EDITOR_CMD="$(tmux show-option -gqv @dev-editor-command 2>/dev/null || true)"
ASSISTANT_CMD="$(tmux show-option -gqv @dev-assistant-command 2>/dev/null || true)"
EDITOR_CMD="${EDITOR_CMD:-nvim}"
ASSISTANT_CMD="${ASSISTANT_CMD:-codex resume --last || codex}"

command_program() {
  local command_string="$1"
  local program="${command_string%%[[:space:]]*}"
  command -v "$program" >/dev/null 2>&1
}

send_command() {
  local pane_id="$1"
  local command_string="$2"

  tmux send-keys -t "$pane_id" -l "$command_string"
  tmux send-keys -t "$pane_id" Enter
}

WINDOW_ID=''
cleanup_partial_window() {
  local status="$?"

  if [ "$status" -ne 0 ] && [ -n "$WINDOW_ID" ]; then
    tmux kill-window -t "$WINDOW_ID" 2>/dev/null || true
  fi
}
trap cleanup_partial_window EXIT

NAME="$(basename "$DIR")"
WIN_NAME="${NAME}-dev"

# Resolve the invoking session once and target everything by stable tmux IDs.
if [ -n "${TMUX_PANE:-}" ]; then
  SESSION_ID="$(tmux display-message -p -t "$TMUX_PANE" '#{session_id}')"
else
  SESSION_ID="$(tmux display-message -p '#{session_id}')"
fi

# Reuse only a window created for this exact repository, even when two
# repositories share the same basename.
EXISTING_WINDOW=''
while IFS= read -r window_id; do
  [ -n "$window_id" ] || continue
  repo_path="$(tmux show-option -wqv -t "$window_id" @repo-path 2>/dev/null || true)"
  if [ "$repo_path" = "$DIR" ]; then
    EXISTING_WINDOW="$window_id"
    break
  fi
done < <(tmux list-windows -t "$SESSION_ID" -F '#{window_id}')

if [ -n "$EXISTING_WINDOW" ]; then
  tmux select-window -t "$EXISTING_WINDOW"
  exit 0
fi

# Capture the first pane and derive the window ID from it, avoiding ambiguous
# numeric pane indexes and window names.
PANE0="$(tmux new-window -P -F '#{pane_id}' -t "$SESSION_ID:" -n "$WIN_NAME" -c "$DIR")"
WINDOW_ID="$(tmux display-message -p -t "$PANE0" '#{window_id}')"
tmux set-option -wq -t "$WINDOW_ID" @repo-path "$DIR"

# Create 3 side-by-side panes
PANE1="$(tmux split-window -P -F '#{pane_id}' -t "$PANE0" -h -c "$DIR")"
PANE2="$(tmux split-window -P -F '#{pane_id}' -t "$PANE1" -h -c "$DIR")"

# Equal-width columns
tmux select-layout -t "$WINDOW_ID" even-horizontal

# Optional tools leave a normal shell behind when they are unavailable.
MISSING=''
if command_program "$EDITOR_CMD"; then
  send_command "$PANE0" "$EDITOR_CMD"
else
  MISSING="${EDITOR_CMD%%[[:space:]]*}"
fi

if command_program "$ASSISTANT_CMD"; then
  send_command "$PANE2" "$ASSISTANT_CMD"
else
  MISSING="${MISSING:+$MISSING, }${ASSISTANT_CMD%%[[:space:]]*}"
fi

tmux select-pane -t "$PANE0"

if [ -n "$MISSING" ]; then
  message "Layout opened; optional commands not found: $MISSING"
fi

trap - EXIT

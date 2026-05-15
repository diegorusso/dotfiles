#!/usr/bin/env bash
set -eu

DIR="${1:-$HOME}"
PRESET="${2:-default}"

if [ ! -d "$DIR" ]; then
  tmux display-message "Not a directory: $DIR"
  exit 1
fi

case "$PRESET" in
  cpython)
    CMD0='nvim'
    CMD1=''
    CMD2='codex resume --last || codex'
    ;;
  ci-scripts)
    CMD0='nvim'
    CMD1=''
    CMD2='codex resume --last || codex'
    ;;
  default)
    CMD0='nvim'
    CMD1=''
    CMD2='codex resume --last || codex'
    ;;
  *)
    tmux display-message "Unknown preset: $PRESET"
    exit 1
    ;;
esac

NAME="$(basename "$DIR")"
WIN_NAME="${NAME}-dev"

# If the window already exists in the current session, switch to it
if tmux list-windows -F '#{window_name}' | grep -qx "$WIN_NAME"; then
  tmux select-window -t "$WIN_NAME"
  exit 0
fi

# Create the window
tmux new-window -n "$WIN_NAME" -c "$DIR"

# Create 3 side-by-side panes
tmux split-window -h -c "$DIR"
tmux split-window -h -c "$DIR"

# Equal-width columns
tmux select-layout even-horizontal

# Run commands
tmux send-keys -t 0 "$CMD0" C-m
tmux send-keys -t 1 "$CMD1" C-m
tmux send-keys -t 2 "$CMD2" C-m

#!/bin/sh
set -eu

xdg_config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
print_path=false

if [ "$#" -gt 0 ]; then
  case $1 in
    --print-path) print_path=true ;;
    *)
      printf 'Usage: %s [--print-path]\n' "$0" >&2
      exit 2
      ;;
  esac
  shift
fi
if [ "$#" -ne 0 ]; then
  printf 'Usage: %s [--print-path]\n' "$0" >&2
  exit 2
fi

use_tpm() {
  [ -n "$1" ] && [ -f "$1" ] && [ -x "$1" ] || return 1
  if [ "$print_path" = true ]; then
    printf '%s\n' "$1"
    exit 0
  fi
  exec "$1"
}

use_tpm "${TMUX_TPM_PATH:-}" || :

if [ -n "${TMUX_PLUGIN_MANAGER_PATH:-}" ]; then
  use_tpm "$TMUX_PLUGIN_MANAGER_PATH/tpm/tpm" || :
fi

use_tpm "$HOME/.tmux/plugins/tpm/tpm" || :
use_tpm "$xdg_config_home/tmux/plugins/tpm/tpm" || :

if [ -n "${HOMEBREW_PREFIX:-}" ]; then
  use_tpm "$HOMEBREW_PREFIX/opt/tpm/share/tpm/tpm" || :
fi

for tpm in \
  /opt/homebrew/opt/tpm/share/tpm/tpm \
  /usr/local/opt/tpm/share/tpm/tpm \
  /home/linuxbrew/.linuxbrew/opt/tpm/share/tpm/tpm \
  /usr/local/share/tmux-plugin-manager/tpm \
  /usr/share/tmux-plugin-manager/tpm
do
  use_tpm "$tpm" || :
done

# Plugins are optional; a missing TPM installation must not break tmux startup.
[ "$print_path" = false ] || exit 1
exit 0

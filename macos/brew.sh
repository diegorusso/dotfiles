#!/usr/bin/env bash

set -euo pipefail

# Compatibility entrypoint for existing setup commands.
repo_dir=$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)
exec "$repo_dir/brew.sh" "$@"

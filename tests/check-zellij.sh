#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo_dir"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/zellij -v

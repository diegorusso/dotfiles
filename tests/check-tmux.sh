#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo_dir"
bash -n .tmux/layouts/dev-3cols.sh .tmux/layouts/pick-repo.sh
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning .tmux/layouts/dev-3cols.sh .tmux/layouts/pick-repo.sh
fi
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/tmux -v

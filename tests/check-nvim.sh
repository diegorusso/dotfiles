#!/usr/bin/env bash
# Run the tracked configuration with copies of an installed, locked plugin set.
set -euo pipefail
repo_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_data=${1:?Usage: bash tests/check-nvim.sh /path/to/nvim/data}
test_root=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-nvim-check.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/config" "$test_root/data/nvim" "$test_root/state" \
	"$test_root/cache" "$test_root/runtime" "$test_root/empty" "$test_root/work"
chmod 700 "$test_root/runtime"
cp -R "$repo_dir/.config/nvim" "$test_root/config/nvim"
cp -R "$test_data/lazy" "$test_root/data/nvim/lazy"
# Query directories can be symlinks into the source plugin tree.
cp -RL "$test_data/site" "$test_root/data/nvim/site"
if [[ -d $test_data/mason ]]; then cp -R "$test_data/mason" "$test_root/data/nvim/mason"; fi
# Keep periodic registry refreshes offline.
# This overlay exists only in the disposable test config.
cat > "$test_root/config/nvim/lua/plugins/offline_test.lua" <<'LUA'
return {
  { "mason-org/mason.nvim", opts = { registry_cache = { refresh = false } } },
}
LUA

export XDG_CONFIG_HOME="$test_root/config" XDG_DATA_HOME="$test_root/data"
export XDG_STATE_HOME="$test_root/state" XDG_CACHE_HOME="$test_root/cache"
export XDG_RUNTIME_DIR="$test_root/runtime"
export XDG_CONFIG_DIRS="$test_root/empty" XDG_DATA_DIRS="$test_root/empty"
export NVIM_APPNAME=nvim NVIM_LOG_FILE="$test_root/nvim.log"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export DOTFILES_NVIM_TEST_SCRIPT="$repo_dir/tests/nvim.lua"
export DOTFILES_ASTRONVIM_HEALTH_SCRIPT="$repo_dir/astronvim-health.lua"
export DOTFILES_ASTRONVIM_HEALTH_MARKER="$test_root/health.ok"
unset VIMINIT EXINIT
cd "$test_root/work"

# Preflight before loading plugins: refuse incomplete data instead of allowing
# Lazy or AstroCore to download replacements during an offline regression run.
nvim --headless --clean -u NONE -i NONE -l /dev/stdin <<'LUA'
local data = vim.fn.stdpath "data"
local lock = vim.json.decode(table.concat(vim.fn.readfile(vim.fn.stdpath "config" .. "/lazy-lock.json"), "\n"))
for name, entry in pairs(lock) do
  local result = vim.system({ "git", "-C", data .. "/lazy/" .. name, "rev-parse", "HEAD" }, { text = true }):wait()
  assert(result.code == 0 and vim.trim(result.stdout or "") == entry.commit, "wrong or missing locked plugin: " .. name)
end
for _, lang in ipairs { "bash", "c", "lua", "markdown", "markdown_inline", "python", "query", "vim", "vimdoc" } do
  assert(vim.uv.fs_stat(data .. "/site/parser/" .. lang .. ".so"), "missing parser: " .. lang)
end
local extension = vim.uv.os_uname().sysname == "Darwin" and ".dylib" or ".so"
local fuzzy = data .. "/lazy/blink.cmp/target/release/"
assert(vim.uv.fs_stat(fuzzy .. "libblink_cmp_fuzzy" .. extension), "open a code file once to finish completion setup")
assert(vim.uv.fs_stat(fuzzy .. "version"), "completion binary download is incomplete")
LUA

nvim --headless -n -i NONE --cmd 'lua dofile(vim.env.DOTFILES_ASTRONVIM_HEALTH_SCRIPT)'
[[ $(cat "$DOTFILES_ASTRONVIM_HEALTH_MARKER") == ok ]]
nvim --headless -n -i NONE --cmd 'lua dofile(vim.env.DOTFILES_NVIM_TEST_SCRIPT)'
cmp "$repo_dir/.config/nvim/lazy-lock.json" "$test_root/config/nvim/lazy-lock.json"
printf 'PASS AstroNvim 6 locked startup, Tree-sitter, LSP preferences, and sessions\n'

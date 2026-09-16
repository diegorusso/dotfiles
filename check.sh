#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$repo_dir"

bash_files=(
	.bash_profile
	.bashrc
	bootstrap.sh
	linux/interactive.bash
	macos/brew.sh
	macos/defaults.sh
	macos/interactive.bash
	check.sh
	.tmux/load-tpm.sh
	.tmux/layouts/dev-3cols.sh
	.tmux/layouts/pick-repo.sh
)

while IFS= read -r file; do
	bash_files+=("$file")
done < <(find shell -type f \( -name '*.bash' -o -name '*.sh' \) -print | sort)

for file in "${bash_files[@]}"; do
	bash -n "$file"
done
printf 'PASS bash syntax (%d files)\n' "${#bash_files[@]}"

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck -x -S warning "${bash_files[@]}"
	printf 'PASS shellcheck\n'
else
	printf 'SKIP shellcheck (not installed)\n'
fi

git_configs=(
	.gitconfig
)
for file in "${git_configs[@]}"; do
	git config --file "$file" --list >/dev/null
done
printf 'PASS Git config parsing\n'

awk '
	/^[[:space:]]*(#|$)/ { next }
	/^(brew|cask) "[A-Za-z0-9@+._-]+"$/ { next }
	{ printf "%s:%d: unsupported Brewfile entry: %s\n", FILENAME, FNR, $0 > "/dev/stderr"; failed = 1 }
	END { exit failed }
' macos/Brewfile
awk '
	/^[[:space:]]*(#|$)/ { next }
	/^[a-z0-9][a-z0-9+.-]*$/ { next }
	{ printf "%s:%d: invalid Debian package entry: %s\n", FILENAME, FNR, $0 > "/dev/stderr"; failed = 1 }
	END { exit failed }
' linux/packages.txt
printf 'PASS package manifest shape\n'

if command -v nvim >/dev/null 2>&1; then
	nvim_version=$(NVIM_LOG_FILE=/dev/null nvim --version |
		sed -n '1s/^NVIM v\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
	read -r nvim_major nvim_minor <<<"$nvim_version"
	if [[ -z ${nvim_major:-} || -z ${nvim_minor:-} ]] || \
		(( nvim_major == 0 && nvim_minor < 10 )); then
		printf 'FAIL Neovim 0.10 or newer is required (found: %s)\n' \
			"$(NVIM_LOG_FILE=/dev/null nvim --version | sed -n '1p')" >&2
		exit 1
	fi
	while IFS= read -r file; do
		DOTFILES_LUA_CHECK="$repo_dir/$file" NVIM_LOG_FILE=/dev/null \
			nvim --headless --clean -u NONE -i NONE \
			--cmd 'lua assert(loadfile(vim.env.DOTFILES_LUA_CHECK))' +qa
	done < <(find .config/nvim -type f -name '*.lua' -print | sort)
	DOTFILES_LUA_CHECK="$repo_dir/astronvim-health.lua" \
		NVIM_LOG_FILE=/dev/null nvim --headless --clean -u NONE -i NONE \
		--cmd 'lua assert(loadfile(vim.env.DOTFILES_LUA_CHECK))' +qa
	printf 'PASS Neovim Lua syntax\n'

	health_hook_command='lua local ok, message = xpcall(function() dofile(vim.env.DOTFILES_ASTRONVIM_HEALTH_SCRIPT) end, debug.traceback); if not ok then io.stderr:write("AstroNvim health hook failed:\n" .. tostring(message) .. "\n"); vim.cmd "cquit 1" end'
	if health_hook_failure=$(
		unset DOTFILES_ASTRONVIM_HEALTH_MARKER
		DOTFILES_ASTRONVIM_HEALTH_SCRIPT="$repo_dir/astronvim-health.lua" \
			NVIM_LOG_FILE=/dev/null nvim --headless --clean -u NONE -n -i NONE \
			--cmd "$health_hook_command" 2>&1
	); then
		printf '%s\n' 'AstroNvim health hook accepted a missing marker path' >&2
		exit 1
	fi
	grep -Fq 'AstroNvim health hook failed:' <<<"$health_hook_failure"
	printf 'PASS AstroNvim health hook failure guard\n'

	DOTFILES_ASTROLSP_CHECK="$repo_dir/.config/nvim/lua/plugins/astrolsp.lua" \
		NVIM_LOG_FILE=/dev/null nvim --headless --clean -u NONE -i NONE \
		-l /dev/stdin <<'LUA'
local spec = assert(loadfile(vim.env.DOTFILES_ASTROLSP_CHECK))()
local callback = spec.opts.autocmds.lsp_codelens_refresh[1].callback
local semantic_tokens_cond = spec.opts.mappings.n["<Leader>uY"].cond

package.loaded.astrolsp = { config = { features = { codelens = true } } }

local refreshed = false
vim.lsp.codelens.enable = nil
vim.lsp.codelens.refresh = function(opts)
  assert(opts.bufnr == 17)
  refreshed = true
end
callback { buf = 17 }
assert(refreshed)

local enabled = false
vim.lsp.codelens.enable = function(value, opts)
  assert(value == true)
  assert(opts.bufnr == 17)
  enabled = true
end
vim.lsp.codelens.refresh = function() error "refresh called when enable is available" end
callback { buf = 17 }
assert(enabled)

package.loaded.astrolsp.config.features.codelens = false
vim.lsp.codelens.enable = function() error "codelens called while disabled" end
callback { buf = 17 }

local expected_client = {}
package.loaded["astrolsp.utils"] = {
  supports_method = function(client, method, bufnr)
    assert(client == expected_client)
    assert(method == "textDocument/semanticTokens/full")
    assert(bufnr == 17)
    return false
  end,
}
assert(semantic_tokens_cond(expected_client, 17) == false)
LUA
	printf 'PASS AstroLSP cross-version callbacks\n'
else
	printf 'SKIP Neovim Lua syntax (nvim not installed)\n'
	printf 'SKIP AstroLSP cross-version callbacks (nvim not installed)\n'
fi

if command -v jq >/dev/null 2>&1; then
	jq -e 'type == "object" and length > 0' .config/nvim/lazy-lock.json >/dev/null
	printf 'PASS Neovim lock JSON\n'
elif command -v python3 >/dev/null 2>&1; then
	python3 -m json.tool .config/nvim/lazy-lock.json >/dev/null
	printf 'PASS Neovim lock JSON\n'
else
	printf 'SKIP Neovim lock JSON (jq and python3 not installed)\n'
fi

check_tmp_parent=$(CDPATH='' cd -- "${TMPDIR:-/tmp}" && pwd -P)
check_root=$(mktemp -d "$check_tmp_parent/dotfiles-check.XXXXXX")
cleanup() {
	case $check_root in
		"$check_tmp_parent"/dotfiles-check.*) rm -rf -- "$check_root" ;;
	esac
}
trap cleanup EXIT

# Ordinary bootstrap checks must never depend on network access or a host TPM
# installation. TPM-specific checks below use their own scoped fake sh/git
# commands to exercise the installation path deterministically.
offline_tpm="$check_root/offline-tpm"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$offline_tpm"
chmod 755 "$offline_tpm"

offline_astronvim_data="$check_root/offline-astronvim-data"
mkdir -p "$offline_astronvim_data/nvim/lazy/AstroNvim/lua/astronvim"
printf '%s\n' 'offline AstroNvim fixture' \
	>"$offline_astronvim_data/nvim/lazy/AstroNvim/version.txt"

root_home_alias="$check_root/root-home-alias"
ln -s / "$root_home_alias"
if HOME=$root_home_alias TMUX_TPM_PATH=$offline_tpm \
	XDG_DATA_HOME=$offline_astronvim_data \
	./bootstrap.sh --dry-run >/dev/null 2>&1; then
	printf 'Bootstrap accepted a HOME symlink resolving to root\n' >&2
	exit 1
fi
printf 'PASS canonical HOME safety guard\n'

loader_home="$check_root/tpm-loader-home"
loader_direct="$check_root/tpm loader/direct-tpm"
loader_directory="$check_root/tpm loader/directory-tpm"
loader_plugin_root="$check_root/tpm plugin manager"
mkdir -p "$loader_home" "${loader_direct%/*}" \
	"$loader_directory" "$loader_plugin_root/tpm"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$loader_direct"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$loader_plugin_root/tpm/tpm"
chmod 755 "$loader_direct" "$loader_plugin_root/tpm/tpm"
[[ $(HOME=$loader_home TMUX_TPM_PATH=$loader_direct \
	sh .tmux/load-tpm.sh --print-path) == "$loader_direct" ]]
loader_plugin_result=$(
	unset TMUX_TPM_PATH
	HOME=$loader_home TMUX_PLUGIN_MANAGER_PATH=$loader_plugin_root \
		sh .tmux/load-tpm.sh --print-path
)
[[ $loader_plugin_result == "$loader_plugin_root/tpm/tpm" ]]
loader_directory_result=$(
	HOME=$loader_home TMUX_TPM_PATH=$loader_directory \
		TMUX_PLUGIN_MANAGER_PATH=$loader_plugin_root \
		sh .tmux/load-tpm.sh --print-path
)
[[ $loader_directory_result == "$loader_plugin_root/tpm/tpm" ]]
printf 'PASS TPM loader explicit-path discovery\n'

if command -v starship >/dev/null 2>&1; then
	mkdir -p "$check_root/starship-home" "$check_root/starship-cache"
	HOME="$check_root/starship-home" \
		STARSHIP_CONFIG="$repo_dir/.config/starship.toml" \
		STARSHIP_CACHE="$check_root/starship-cache" \
		TERM=xterm-256color starship print-config >/dev/null
	printf 'PASS Starship config parsing\n'
else
	printf 'SKIP Starship config parsing (starship not installed)\n'
fi

check_path_mode() {
	local checked_path=$1 checked_mode
	checked_mode=$(stat -c '%a' "$checked_path" 2>/dev/null) ||
		checked_mode=$(stat -f '%Lp' "$checked_path" 2>/dev/null) || return
	printf '%s\n' "$checked_mode"
}

directory_has_entries_except() {
	local checked_directory=$1 excluded_path=${2:-} checked_entry
	for checked_entry in \
		"$checked_directory"/* \
		"$checked_directory"/.[!.]* \
		"$checked_directory"/..?*; do
		[[ -e $checked_entry || -L $checked_entry ]] || continue
		[[ -n $excluded_path && $checked_entry == "$excluded_path" ]] && continue
		return 0
	done
	return 1
}

run_bootstrap() (
	local kernel=$1 check_home=$2
	shift 2
	DOTFILES_CHECK_KERNEL=$kernel
	export DOTFILES_CHECK_KERNEL
	uname() { printf '%s\n' "$DOTFILES_CHECK_KERNEL"; }
	export -f uname
	HOME=$check_home TMUX_TPM_PATH=$offline_tpm \
		XDG_DATA_HOME=$offline_astronvim_data ./bootstrap.sh "$@"
)

check_bootstrap_platform() {
	local kernel=$1 platform=$2
	local check_home="$check_root/$platform" second_run noninteractive_output
	mkdir -p "$check_home"
	printf '%s\n' \
		'export DOTFILES_PROFILE_SENTINEL=loaded' \
		'if [ -n "$BASH_VERSION" ] && [ -r "$HOME/.bashrc" ]; then' \
		'  . "$HOME/.bashrc"' \
		'fi' >"$check_home/.profile"

	run_bootstrap "$kernel" "$check_home" --apply >/dev/null
	second_run=$(run_bootstrap "$kernel" "$check_home" --apply)
	if grep -Eq '^(INSTALL|REPLACE)' <<<"$second_run"; then
		printf '%s bootstrap is not idempotent:\n%s\n' "$platform" "$second_run" >&2
		exit 1
	fi
	[[ $(git config --file "$check_home/.gitconfig" --get user.name) == \
		'Diego Russo' ]]
	[[ $(git config --file "$check_home/.gitconfig" --get user.email) == \
		'me@diegor.it' ]]
	[[ $(git config --file "$check_home/.gitconfig" --bool \
		--get core.trustctime) == false ]]
	[[ $(git config --file "$check_home/.gitconfig" --bool \
		--get core.precomposeunicode) == true ]]
	[[ $(HOME=$check_home git config --path --file "$check_home/.gitconfig" \
		--get core.excludesfile) == "$check_home/.gitignore" ]]
	if git config --file "$check_home/.gitconfig" \
		--get-all include.path >/dev/null 2>&1 || \
		git config --file "$check_home/.gitconfig" \
		--get-regexp '^includeIf\.' >/dev/null 2>&1; then
		printf '%s Git config retained an include layer\n' "$platform" >&2
		exit 1
	fi
	cmp -s .config/starship.toml "$check_home/.config/starship.toml"
	if [[ $platform == macos ]]; then
		cmp -s .config/ghostty/config.ghostty \
			"$check_home/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
	else
		cmp -s .config/ghostty/config.ghostty \
			"$check_home/.config/ghostty/config.ghostty"
	fi
	cmp -s .gitignore "$check_home/.gitignore"
	cmp -s macos/interactive.bash \
		"$check_home/.config/dotfiles/shell/platform/macos.bash"
	cmp -s linux/interactive.bash \
		"$check_home/.config/dotfiles/shell/platform/linux.bash"

	noninteractive_output=$(
		HOME=$check_home BASH_ENV='' bash --noprofile --norc -c \
			'source "$HOME/.bashrc"'
	)
	if [[ -n $noninteractive_output ]]; then
		printf '%s non-interactive .bashrc produced output: %s\n' \
			"$platform" "$noninteractive_output" >&2
		exit 1
	fi
	HOME=$check_home BASH_ENV='' bash --noprofile --norc -c '
		unset DOTFILES_ENV_LOADED DOTFILES_PROFILE_LOADED DOTFILES_LOADING_PROFILE
		source "$HOME/.bash_profile"
		[[ $DOTFILES_PROFILE_SENTINEL == loaded ]]
		[[ $DOTFILES_ENV_LOADED == 1 ]]
	'
}

check_bootstrap_platform Linux linux
check_bootstrap_platform Darwin macos
printf 'PASS isolated Linux/macOS bootstrap apply and idempotence\n'

diff_home="$check_root/bootstrap-diff"
mkdir -p "$diff_home"
printf '%s\n' 'local diff sentinel' >"$diff_home/.bashrc"
chmod 640 "$diff_home/.bashrc"
diff_without_output=$(run_bootstrap Linux "$diff_home" --dry-run)
if grep -Fq 'Difference for ' <<<"$diff_without_output"; then
	printf 'Bootstrap showed content differences without --diff\n' >&2
	exit 1
fi
grep -Fxq 'local diff sentinel' "$diff_home/.bashrc"
[[ $(check_path_mode "$diff_home/.bashrc") == 640 ]]

diff_dry_output=$(run_bootstrap Linux "$diff_home" --dry-run -d)
grep -Fq "REPLACE   $diff_home/.bashrc" <<<"$diff_dry_output"
grep -Fq "Difference for $diff_home/.bashrc:" <<<"$diff_dry_output"
grep -Fq -- '-local diff sentinel' <<<"$diff_dry_output"
grep -Fxq 'local diff sentinel' "$diff_home/.bashrc"
[[ ! -e "$diff_home/.bash_profile" ]]

diff_apply_output=$(run_bootstrap Linux "$diff_home" --apply --diff)
diff_backup=$(sed -n 's/^Restore backup: //p' <<<"$diff_apply_output")
[[ -d $diff_backup ]]
grep -Fq "Difference for $diff_home/.bashrc:" <<<"$diff_apply_output"
grep -Fq -- '-local diff sentinel' <<<"$diff_apply_output"
cmp -s .bashrc "$diff_home/.bashrc"

chmod 664 "$diff_home/.hushlogin"
mode_only_output=$(run_bootstrap Linux "$diff_home" --dry-run --diff)
grep -Fq "REPLACE   $diff_home/.hushlogin" <<<"$mode_only_output"
grep -Fq "Mode change for $diff_home/.hushlogin: 664 -> 644" \
	<<<"$mode_only_output"
run_bootstrap Linux "$diff_home" --apply >/dev/null
[[ $(check_path_mode "$diff_home/.hushlogin") == 644 ]]

diff_idempotent_output=$(run_bootstrap Linux "$diff_home" --apply -d)
if grep -Eq '^(Difference for |DIFF[[:space:]])' \
	<<<"$diff_idempotent_output"; then
	printf 'Idempotent bootstrap emitted a content difference\n' >&2
	exit 1
fi
diff_restore_output=$(run_bootstrap Plan9 "$diff_home" \
	--restore "$diff_backup" --dry-run --diff)
grep -Fq "Difference for $diff_home/.bashrc:" <<<"$diff_restore_output"
grep -Fq '+local diff sentinel' <<<"$diff_restore_output"
cmp -s .bashrc "$diff_home/.bashrc"
printf 'PASS optional install and restore content diffs\n'

tpm_fixture="$check_root/tpm-clone-fixture"
tpm_fake_git_bin="$check_root/tpm-fake-git-bin"
tpm_force_absent_bin="$check_root/tpm-force-absent-bin"
tpm_race_bin="$check_root/tpm-race-bin"
tpm_real_mkdir=$(command -v mkdir)
[[ $tpm_real_mkdir == /* ]]
mkdir -p "$tpm_fixture/.git" "$tpm_fake_git_bin" "$tpm_force_absent_bin" \
	"$tpm_race_bin"
printf '%s\n' \
	'#!/bin/sh' \
	'if [ -n "${CHECK_TPM_EXEC_LOG:-}" ]; then' \
	'  printf "executed\\n" >>"$CHECK_TPM_EXEC_LOG"' \
	'fi' \
	'exit 0' >"$tpm_fixture/tpm"
printf '%s\n' 'ref: refs/tags/v3.1.0' >"$tpm_fixture/.git/HEAD"
printf '%s\n' 'offline TPM fixture' >"$tpm_fixture/README.md"
chmod 755 "$tpm_fixture/tpm"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	': "${CHECK_FAKE_GIT_LOG:?}"' \
	': "${CHECK_FAKE_GIT_MODE:?}"' \
	': "${CHECK_TPM_FIXTURE:?}"' \
	'printf "git" >>"$CHECK_FAKE_GIT_LOG"' \
	'printf "\\t%s" "$@" >>"$CHECK_FAKE_GIT_LOG"' \
	'printf "\\tHOME=%s" "${HOME:-}" >>"$CHECK_FAKE_GIT_LOG"' \
	'printf "\\tXDG_CONFIG_HOME=%s" "${XDG_CONFIG_HOME:-}" >>"$CHECK_FAKE_GIT_LOG"' \
	'printf "\\tGIT_TERMINAL_PROMPT=%s" "${GIT_TERMINAL_PROMPT:-}" >>"$CHECK_FAKE_GIT_LOG"' \
	'printf "\\tGIT_CONFIG_GLOBAL=%s" "${GIT_CONFIG_GLOBAL:-}" >>"$CHECK_FAKE_GIT_LOG"' \
	'printf "\\tGIT_SSL_NO_VERIFY=%s" "${GIT_SSL_NO_VERIFY:-}" >>"$CHECK_FAKE_GIT_LOG"' \
	'printf "\\tGIT_CONFIG_NOSYSTEM=%s" "${GIT_CONFIG_NOSYSTEM:-}" >>"$CHECK_FAKE_GIT_LOG"' \
	'printf "\\tGIT_CONFIG_SYSTEM=%s" "${GIT_CONFIG_SYSTEM:-}" >>"$CHECK_FAKE_GIT_LOG"' \
	'printf "\\tGIT_CONFIG_PARAMETERS=%s" "${GIT_CONFIG_PARAMETERS:-}" >>"$CHECK_FAKE_GIT_LOG"' \
	'printf "\\tGIT_CONFIG_COUNT=%s" "${GIT_CONFIG_COUNT:-}" >>"$CHECK_FAKE_GIT_LOG"' \
	'if grep -Fq "sslVerify = true" "$HOME/.gitconfig"; then' \
	'  printf "\\tSAFE_SSL_VERIFY=true" >>"$CHECK_FAKE_GIT_LOG"' \
	'else' \
	'  printf "\\tSAFE_SSL_VERIFY=false" >>"$CHECK_FAKE_GIT_LOG"' \
	'fi' \
	'printf "\\n" >>"$CHECK_FAKE_GIT_LOG"' \
	'if (( $# != 9 )) || [[ $1 != clone || $2 != --quiet ||' \
	'  $3 != --branch || $4 != v3.1.0 || $5 != --depth || $6 != 1 ||' \
	'  $7 != -- || $8 != https://github.com/tmux-plugins/tpm ]]; then' \
	'  exit 64' \
	'fi' \
	'destination=$9' \
	'case $CHECK_FAKE_GIT_MODE in' \
	'  success)' \
	'    mkdir -p "$destination"' \
	'    cp -Rp "$CHECK_TPM_FIXTURE"/. "$destination"' \
	'    ;;' \
	'  malformed)' \
	'    mkdir -p "$destination"' \
	'    cp -Rp "$CHECK_TPM_FIXTURE"/. "$destination"' \
	'    chmod 644 "$destination/tpm"' \
	'    ;;' \
	'  fail)' \
	'    mkdir -p "$destination"' \
	'    printf "partial clone\\n" >"$destination/PARTIAL"' \
	'    exit 42' \
	'    ;;' \
	'  forbidden) exit 99 ;;' \
	'  *) exit 65 ;;' \
	'esac' >"$tpm_fake_git_bin/git"
chmod 755 "$tpm_fake_git_bin/git"
printf '%s\n' \
	'#!/bin/sh' \
	'case ${1:-} in' \
	'  */.tmux/load-tpm.sh)' \
	'    if [ "$#" -eq 2 ] && [ "$2" = --print-path ]; then' \
	'      exit 1' \
	'    fi' \
	'    ;;' \
	'esac' \
	'exec /bin/sh "$@"' >"$tpm_force_absent_bin/sh"
chmod 755 "$tpm_force_absent_bin/sh"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	': "${CHECK_TPM_RACE_TARGET:?}"' \
	': "${CHECK_TPM_RACE_LOG:?}"' \
	': "${CHECK_REAL_MKDIR:?}"' \
	'if (( $# == 1 )) && [[ $1 == "$CHECK_TPM_RACE_TARGET" ]]; then' \
	'  printf "reservation race triggered\\n" >>"$CHECK_TPM_RACE_LOG"' \
	'  "$CHECK_REAL_MKDIR" "$CHECK_TPM_RACE_TARGET"' \
	'  printf "competing owner state\\n" >"$CHECK_TPM_RACE_TARGET/owner-state"' \
	'fi' \
	'exec "$CHECK_REAL_MKDIR" "$@"' >"$tpm_race_bin/mkdir"
chmod 755 "$tpm_race_bin/mkdir"

run_tpm_bootstrap() (
	local kernel=$1 check_home=$2 fake_mode=$3 force_absent=$4 fake_log=$5
	local scoped_path="$tpm_fake_git_bin:$PATH"
	shift 5
	if [[ -n ${CHECK_TPM_RACE_TARGET:-} ]]; then
		scoped_path="$tpm_race_bin:$scoped_path"
		: "${CHECK_TPM_RACE_LOG:?}"
		CHECK_REAL_MKDIR=$tpm_real_mkdir
		export CHECK_TPM_RACE_TARGET CHECK_TPM_RACE_LOG CHECK_REAL_MKDIR
	fi
	if [[ $force_absent == true ]]; then
		scoped_path="$tpm_force_absent_bin:$scoped_path"
	fi
	DOTFILES_CHECK_KERNEL=$kernel
	export DOTFILES_CHECK_KERNEL
	uname() { printf '%s\n' "$DOTFILES_CHECK_KERNEL"; }
	export -f uname
	PATH=$scoped_path
	CHECK_FAKE_GIT_LOG=$fake_log
	CHECK_FAKE_GIT_MODE=$fake_mode
	CHECK_TPM_FIXTURE=$tpm_fixture
	export PATH CHECK_FAKE_GIT_LOG CHECK_FAKE_GIT_MODE CHECK_TPM_FIXTURE
	GIT_CONFIG_GLOBAL="$check_home/.gitconfig"
	GIT_SSL_NO_VERIFY=1
	GIT_CONFIG_NOSYSTEM=1
	GIT_CONFIG_SYSTEM="$check_home/system.gitconfig"
	GIT_CONFIG_PARAMETERS=poison
	GIT_CONFIG_COUNT=1
	GIT_CONFIG_KEY_0=http.sslVerify
	GIT_CONFIG_VALUE_0=false
	export GIT_CONFIG_GLOBAL GIT_SSL_NO_VERIFY GIT_CONFIG_NOSYSTEM
	export GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
	export GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
	unset TMUX_TPM_PATH TMUX_PLUGIN_MANAGER_PATH HOMEBREW_PREFIX
	HOME=$check_home XDG_CONFIG_HOME="$check_home/.config" \
		XDG_DATA_HOME=$offline_astronvim_data \
		./bootstrap.sh "$@"
)

tpm_dry_home="$check_root/tpm-dry-run"
tpm_dry_log="$check_root/tpm-dry-run.git.log"
mkdir -p "$tpm_dry_home"
: >"$tpm_dry_log"
tpm_dry_output=$(run_tpm_bootstrap Linux "$tpm_dry_home" forbidden true \
	"$tpm_dry_log" --dry-run)
[[ ! -s $tpm_dry_log ]]
[[ ! -e "$tpm_dry_home/.tmux/plugins/tpm" ]]
grep -Fq "INSTALL   $tpm_dry_home/.tmux/plugins/tpm" <<<"$tpm_dry_output"

tpm_apply_home="$check_root/tpm-apply"
tpm_apply_log="$check_root/tpm-apply.git.log"
mkdir -p "$tpm_apply_home"
: >"$tpm_apply_log"
tpm_apply_output=$(run_tpm_bootstrap Linux "$tpm_apply_home" success true \
	"$tpm_apply_log" --apply)
tpm_apply_backup=$(sed -n 's/^Restore backup: //p' <<<"$tpm_apply_output")
[[ -d $tpm_apply_backup ]]
(( $(wc -l <"$tpm_apply_log") == 1 ))
grep -Fq $'git\tclone\t--quiet\t--branch\tv3.1.0\t--depth\t1\t--\thttps://github.com/tmux-plugins/tpm\t' \
	"$tpm_apply_log"
grep -Fq $'\tGIT_TERMINAL_PROMPT=0' "$tpm_apply_log"
grep -Eq $'\tHOME=.*/dotfiles-bootstrap\\.[^/]+/bootstrap-git-home\t' \
	"$tpm_apply_log"
grep -Eq $'\tXDG_CONFIG_HOME=.*/dotfiles-bootstrap\\.[^/]+/bootstrap-git-config\t' \
	"$tpm_apply_log"
grep -Fq $'\tGIT_CONFIG_GLOBAL=' "$tpm_apply_log"
grep -Fq $'\tGIT_SSL_NO_VERIFY=' "$tpm_apply_log"
grep -Fq $'\tGIT_CONFIG_NOSYSTEM=' "$tpm_apply_log"
grep -Fq $'\tGIT_CONFIG_SYSTEM=' "$tpm_apply_log"
grep -Fq $'\tGIT_CONFIG_PARAMETERS=' "$tpm_apply_log"
grep -Fq $'\tGIT_CONFIG_COUNT=' "$tpm_apply_log"
grep -Fq $'\tSAFE_SSL_VERIFY=true' "$tpm_apply_log"
grep -Fq $'\tGIT_CONFIG_GLOBAL=\tGIT_SSL_NO_VERIFY=\tGIT_CONFIG_NOSYSTEM=\tGIT_CONFIG_SYSTEM=\tGIT_CONFIG_PARAMETERS=\tGIT_CONFIG_COUNT=\tSAFE_SSL_VERIFY=true' \
	"$tpm_apply_log"
[[ -x "$tpm_apply_home/.tmux/plugins/tpm/tpm" ]]
cmp -s "$tpm_fixture/tpm" "$tpm_apply_home/.tmux/plugins/tpm/tpm"
cmp -s "$tpm_fixture/.git/HEAD" \
	"$tpm_apply_home/.tmux/plugins/tpm/.git/HEAD"
grep -Fqx $'INSTALL\t.tmux/plugins/tpm\t-' \
	"$tpm_apply_backup/restore.manifest"
tpm_exec_log="$check_root/tpm-executed.log"
HOME=$tpm_apply_home CHECK_TPM_EXEC_LOG=$tpm_exec_log \
	sh "$tpm_apply_home/.tmux/load-tpm.sh"
grep -Fxq executed "$tpm_exec_log"

printf '%s\n' 'preserve this local TPM state' \
	>"$tpm_apply_home/.tmux/plugins/tpm/local-sentinel"
chmod 640 "$tpm_apply_home/.tmux/plugins/tpm/local-sentinel"
tpm_idempotent_log="$check_root/tpm-idempotent.git.log"
: >"$tpm_idempotent_log"
tpm_idempotent_output=$(run_tpm_bootstrap Linux "$tpm_apply_home" forbidden \
	false "$tpm_idempotent_log" --apply)
[[ ! -s $tpm_idempotent_log ]]
grep -Fq "UNCHANGED $tpm_apply_home/.tmux/plugins/tpm/tpm (TPM)" \
	<<<"$tpm_idempotent_output"
grep -Fxq 'preserve this local TPM state' \
	"$tpm_apply_home/.tmux/plugins/tpm/local-sentinel"
[[ $(check_path_mode \
	"$tpm_apply_home/.tmux/plugins/tpm/local-sentinel") == 640 ]]

tpm_restore_log="$check_root/tpm-restore.git.log"
: >"$tpm_restore_log"
tpm_restore_preview=$(run_tpm_bootstrap Plan9 "$tpm_apply_home" forbidden \
	true "$tpm_restore_log" --restore "$tpm_apply_backup" --diff)
grep -Fq "REMOVE    $tpm_apply_home/.tmux/plugins/tpm" \
	<<<"$tpm_restore_preview"
grep -Fq "DIFF      skipped for external generated tree: $tpm_apply_home/.tmux/plugins/tpm" \
	<<<"$tpm_restore_preview"
tpm_restore_output=$(run_tpm_bootstrap Plan9 "$tpm_apply_home" forbidden \
	true "$tpm_restore_log" --restore "$tpm_apply_backup" --apply)
tpm_restore_safety=$(sed -n 's/^The pre-restore state is under //p' \
	<<<"$tpm_restore_output")
[[ -d $tpm_restore_safety ]]
[[ ! -e "$tpm_apply_home/.tmux/plugins/tpm" ]]
[[ ! -s $tpm_restore_log ]]
run_tpm_bootstrap Plan9 "$tpm_apply_home" forbidden true "$tpm_restore_log" \
	--restore "$tpm_restore_safety" --apply >/dev/null
[[ -x "$tpm_apply_home/.tmux/plugins/tpm/tpm" ]]
cmp -s "$tpm_fixture/tpm" "$tpm_apply_home/.tmux/plugins/tpm/tpm"
grep -Fxq 'preserve this local TPM state' \
	"$tpm_apply_home/.tmux/plugins/tpm/local-sentinel"
[[ $(check_path_mode \
	"$tpm_apply_home/.tmux/plugins/tpm/local-sentinel") == 640 ]]
run_tpm_bootstrap Plan9 "$tpm_apply_home" forbidden true "$tpm_restore_log" \
	--restore "$tpm_apply_backup" --apply >/dev/null
[[ ! -e "$tpm_apply_home/.tmux/plugins/tpm" ]]
[[ ! -s $tpm_restore_log ]]

tpm_existing_home="$check_root/tpm-existing"
tpm_existing_log="$check_root/tpm-existing.git.log"
mkdir -p "$tpm_existing_home/.tmux/plugins/tpm"
cp -Rp "$tpm_fixture"/. "$tpm_existing_home/.tmux/plugins/tpm"
printf '%s\n' preexisting >"$tpm_existing_home/.tmux/plugins/tpm/owner-state"
: >"$tpm_existing_log"
tpm_existing_output=$(run_tpm_bootstrap Linux "$tpm_existing_home" forbidden \
	false "$tpm_existing_log" --apply)
tpm_existing_backup=$(sed -n 's/^Restore backup: //p' <<<"$tpm_existing_output")
[[ ! -s $tpm_existing_log ]]
grep -Fxq preexisting "$tpm_existing_home/.tmux/plugins/tpm/owner-state"
if grep -Fq $'\t.tmux/plugins/tpm\t' \
	"$tpm_existing_backup/restore.manifest"; then
	printf 'Bootstrap journalled a pre-existing TPM installation\n' >&2
	exit 1
fi

for tpm_conflict_kind in file directory symlink; do
	tmp_conflict_home="$check_root/tpm-conflict-$tpm_conflict_kind"
	tmp_conflict_log="$check_root/tpm-conflict-$tpm_conflict_kind.git.log"
	mkdir -p "$tmp_conflict_home/.tmux/plugins"
	case $tpm_conflict_kind in
		file) printf '%s\n' conflict >"$tmp_conflict_home/.tmux/plugins/tpm" ;;
		directory)
			mkdir "$tmp_conflict_home/.tmux/plugins/tpm"
			printf '%s\n' conflict \
				>"$tmp_conflict_home/.tmux/plugins/tpm/owner-state"
			;;
		symlink)
			mkdir "$tmp_conflict_home/outside-tpm"
			ln -s "$tmp_conflict_home/outside-tpm" \
				"$tmp_conflict_home/.tmux/plugins/tpm"
			;;
	esac
	: >"$tmp_conflict_log"
	if run_tpm_bootstrap Linux "$tmp_conflict_home" forbidden true \
		"$tmp_conflict_log" --apply >/dev/null 2>&1; then
		printf 'Bootstrap accepted an unusable TPM %s conflict\n' \
			"$tpm_conflict_kind" >&2
		exit 1
	fi
	[[ ! -s $tmp_conflict_log ]]
	[[ ! -e "$tmp_conflict_home/.bashrc" ]]
	[[ ! -e "$tmp_conflict_home/.local/state/dotfiles/bootstrap.lock" ]]
	case $tpm_conflict_kind in
		file) grep -Fxq conflict "$tmp_conflict_home/.tmux/plugins/tpm" ;;
		directory)
			grep -Fxq conflict \
				"$tmp_conflict_home/.tmux/plugins/tpm/owner-state"
			;;
		symlink)
			[[ -L "$tmp_conflict_home/.tmux/plugins/tpm" ]]
			[[ $(readlink "$tmp_conflict_home/.tmux/plugins/tpm") == \
				"$tmp_conflict_home/outside-tpm" ]]
			;;
	esac
done

for tpm_failure_mode in malformed fail; do
	tmp_failure_home="$check_root/tpm-$tpm_failure_mode"
	tmp_failure_log="$check_root/tpm-$tpm_failure_mode.git.log"
	tmp_failure_tmp="$tmp_failure_home/tmp"
	mkdir -p "$tmp_failure_home" "$tmp_failure_tmp"
	: >"$tmp_failure_log"
	if TMPDIR=$tmp_failure_tmp run_tpm_bootstrap Linux "$tmp_failure_home" \
		"$tpm_failure_mode" true "$tmp_failure_log" --apply \
		>/dev/null 2>&1; then
		printf 'Bootstrap accepted a %s TPM clone\n' "$tpm_failure_mode" >&2
		exit 1
	fi
	(( $(wc -l <"$tmp_failure_log") == 1 ))
	[[ ! -e "$tmp_failure_home/.tmux/plugins/tpm" ]]
	[[ ! -e "$tmp_failure_home/.bashrc" ]]
	[[ ! -e "$tmp_failure_home/.local/state/dotfiles/bootstrap.lock" ]]
	! directory_has_entries_except "$tmp_failure_tmp"
done

for tpm_ancestor_kind in tmux plugins; do
	tmp_ancestor_home="$check_root/tpm-symlink-ancestor-$tpm_ancestor_kind"
	tmp_ancestor_outside="$check_root/tpm-symlink-outside-$tpm_ancestor_kind"
	tmp_ancestor_log="$check_root/tpm-symlink-ancestor-$tpm_ancestor_kind.git.log"
	mkdir -p "$tmp_ancestor_home" "$tmp_ancestor_outside"
	printf '%s\n' 'outside owner state' >"$tmp_ancestor_outside/owner-state"
	case $tpm_ancestor_kind in
		tmux)
			mkdir "$tmp_ancestor_outside/tmux"
			ln -s "$tmp_ancestor_outside/tmux" "$tmp_ancestor_home/.tmux"
			tmp_ancestor_link="$tmp_ancestor_home/.tmux"
			tmp_ancestor_link_target="$tmp_ancestor_outside/tmux"
			tmp_ancestor_destination="$tmp_ancestor_outside/tmux/plugins/tpm"
			;;
		plugins)
			mkdir -p "$tmp_ancestor_home/.tmux" \
				"$tmp_ancestor_outside/plugins"
			ln -s "$tmp_ancestor_outside/plugins" \
				"$tmp_ancestor_home/.tmux/plugins"
			tmp_ancestor_link="$tmp_ancestor_home/.tmux/plugins"
			tmp_ancestor_link_target="$tmp_ancestor_outside/plugins"
			tmp_ancestor_destination="$tmp_ancestor_outside/plugins/tpm"
			;;
	esac
	: >"$tmp_ancestor_log"
	if tmp_ancestor_output=$(run_tpm_bootstrap Linux "$tmp_ancestor_home" \
		success true "$tmp_ancestor_log" --apply 2>&1); then
		printf 'Bootstrap accepted a symlinked .tmux/%s ancestor\n' \
			"$tpm_ancestor_kind" >&2
		exit 1
	fi
	(( $(wc -l <"$tmp_ancestor_log") == 1 ))
	grep -Fq "Refusing symlink ancestor for managed path: $tmp_ancestor_link" \
		<<<"$tmp_ancestor_output"
	[[ -L $tmp_ancestor_link ]]
	[[ $(readlink "$tmp_ancestor_link") == "$tmp_ancestor_link_target" ]]
	grep -Fxq 'outside owner state' "$tmp_ancestor_outside/owner-state"
	[[ ! -e $tmp_ancestor_destination ]]
	[[ ! -e "$tmp_ancestor_home/.bashrc" ]]
	[[ ! -e "$tmp_ancestor_home/.local/state/dotfiles/bootstrap.lock" ]]

	tmp_ancestor_restore="$tmp_ancestor_home/.local/state/dotfiles/backups/forged"
	mkdir -p "$tmp_ancestor_restore"
	printf '%s\n' 'dotfiles-restore-v1' \
		$'INSTALL\t.tmux/plugins/tpm\t-' \
		>"$tmp_ancestor_restore/restore.manifest"
	: >"$tmp_ancestor_log"
	if tmp_ancestor_restore_output=$(run_tpm_bootstrap Plan9 \
		"$tmp_ancestor_home" forbidden true "$tmp_ancestor_log" \
		--restore "$tmp_ancestor_restore" --apply 2>&1); then
		printf 'Restore accepted a symlinked .tmux/%s ancestor\n' \
			"$tpm_ancestor_kind" >&2
		exit 1
	fi
	[[ ! -s $tmp_ancestor_log ]]
	grep -Fq "Refusing symlink ancestor for managed path: $tmp_ancestor_link" \
		<<<"$tmp_ancestor_restore_output"
	[[ -L $tmp_ancestor_link ]]
	grep -Fxq 'outside owner state' "$tmp_ancestor_outside/owner-state"
	[[ ! -e $tmp_ancestor_destination ]]
done

tpm_race_home="$check_root/tpm-reservation-race"
tpm_race_git_log="$check_root/tpm-reservation-race.git.log"
tpm_race_log="$check_root/tpm-reservation-race.log"
tpm_race_target="$tpm_race_home/.tmux/plugins/tpm"
mkdir -p "$tpm_race_home"
: >"$tpm_race_git_log"
: >"$tpm_race_log"
if tpm_race_output=$(CHECK_TPM_RACE_TARGET=$tpm_race_target \
	CHECK_TPM_RACE_LOG=$tpm_race_log run_tpm_bootstrap Linux \
	"$tpm_race_home" success true "$tpm_race_git_log" --apply 2>&1); then
	printf 'Bootstrap overwrote a TPM path created at reservation time\n' >&2
	exit 1
fi
grep -Fxq 'reservation race triggered' "$tpm_race_log"
(( $(wc -l <"$tpm_race_git_log") == 1 ))
grep -Fq "TPM path appeared during installation: $tpm_race_target" \
	<<<"$tpm_race_output"
grep -Fxq 'competing owner state' "$tpm_race_target/owner-state"
! directory_has_entries_except "$tpm_race_target" \
	"$tpm_race_target/owner-state"
[[ ! -e "$tpm_race_home/.bashrc" ]]
[[ ! -e "$tpm_race_home/.local/state/dotfiles/bootstrap.lock" ]]
if grep -R -Fq $'\t.tmux/plugins/tpm\t' \
	"$tpm_race_home/.local/state/dotfiles/backups"; then
	printf 'Bootstrap journalled a TPM reservation it did not own\n' >&2
	exit 1
fi
printf 'PASS offline TPM bootstrap install, conflicts, failure, and idempotence\n'

astro_fake_bin="$check_root/astronvim-fake-bin"
astro_tmp="$check_root/astronvim-tmp"
astro_git_log="$check_root/astronvim.git.log"
mkdir -p "$astro_fake_bin" "$astro_tmp"
: >"$astro_git_log"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	': "${CHECK_FAKE_NVIM_LOG:?}"' \
	': "${CHECK_FAKE_NVIM_MODE:?}"' \
	': "${CHECK_TRACKED_NVIM_LOCK:?}"' \
	'if (( $# == 1 )) && [[ $1 == --version ]]; then' \
	'  printf "VERSION\\n" >>"$CHECK_FAKE_NVIM_LOG"' \
	'  printf "NVIM v0.10.4\\n"' \
	'  exit 0' \
	'fi' \
	'{' \
	'  printf "HEADLESS"' \
	'  printf "\\t%s" "$@"' \
	'  printf "\\n"' \
	'  printf "HOME\\t%s\\n" "${HOME:-}"' \
	'  printf "XDG_CONFIG_HOME\\t%s\\n" "${XDG_CONFIG_HOME:-}"' \
	'  printf "XDG_CONFIG_DIRS\\t%s\\n" "${XDG_CONFIG_DIRS:-}"' \
	'  printf "XDG_DATA_HOME\\t%s\\n" "${XDG_DATA_HOME:-}"' \
	'  printf "XDG_DATA_DIRS\\t%s\\n" "${XDG_DATA_DIRS:-}"' \
	'  printf "XDG_STATE_HOME\\t%s\\n" "${XDG_STATE_HOME:-}"' \
	'  printf "XDG_CACHE_HOME\\t%s\\n" "${XDG_CACHE_HOME:-}"' \
	'  printf "XDG_RUNTIME_DIR\\t%s\\n" "${XDG_RUNTIME_DIR:-}"' \
	'  printf "NVIM_APPNAME\\t%s\\n" "${NVIM_APPNAME:-}"' \
	'  printf "NVIM_LOG_FILE\\t%s\\n" "${NVIM_LOG_FILE:-}"' \
	'  printf "GIT_CONFIG_GLOBAL\\t%s\\n" "${GIT_CONFIG_GLOBAL:-}"' \
	'  printf "GIT_SSL_NO_VERIFY\\t%s\\n" "${GIT_SSL_NO_VERIFY:-}"' \
	'  printf "GIT_CONFIG_NOSYSTEM\\t%s\\n" "${GIT_CONFIG_NOSYSTEM:-}"' \
	'  printf "GIT_CONFIG_SYSTEM\\t%s\\n" "${GIT_CONFIG_SYSTEM:-}"' \
	'  printf "GIT_CONFIG_PARAMETERS\\t%s\\n" "${GIT_CONFIG_PARAMETERS:-}"' \
	'  printf "GIT_CONFIG_COUNT\\t%s\\n" "${GIT_CONFIG_COUNT:-}"' \
	'  if grep -Fq "sslVerify = true" "$HOME/.gitconfig"; then' \
	'    printf "SAFE_SSL_VERIFY\\ttrue\\n"' \
	'  else' \
	'    printf "SAFE_SSL_VERIFY\\tfalse\\n"' \
	'  fi' \
	'  printf "GIT_TERMINAL_PROMPT\\t%s\\n" "${GIT_TERMINAL_PROMPT:-}"' \
	'  printf "DOTFILES_ASTRONVIM_HEALTH_SCRIPT\\t%s\\n" "${DOTFILES_ASTRONVIM_HEALTH_SCRIPT:-}"' \
	'  printf "DOTFILES_ASTRONVIM_HEALTH_MARKER\\t%s\\n" "${DOTFILES_ASTRONVIM_HEALTH_MARKER:-}"' \
	'  printf "VIMINIT\\t%s\\n" "${VIMINIT:-}"' \
	'  printf "EXINIT\\t%s\\n" "${EXINIT:-}"' \
	'  printf "PWD\\t%s\\n" "$PWD"' \
	'  runtime_mode=$(stat -c "%a" "$XDG_RUNTIME_DIR" 2>/dev/null || stat -f "%Lp" "$XDG_RUNTIME_DIR")' \
	'  printf "XDG_RUNTIME_MODE\\t%s\\n" "$runtime_mode"' \
	'} >>"$CHECK_FAKE_NVIM_LOG"' \
	'if (( $# == 6 )) && [[ $1 == --headless && $2 == -n &&' \
	'  $3 == -i && $4 == NONE && $5 == "+Lazy! restore" && $6 == +qa ]]; then' \
	'  phase=restore' \
	'elif (( $# == 6 )) && [[ $1 == --headless && $2 == -n &&' \
	'  $3 == -i && $4 == NONE && $5 == --cmd &&' \
	'  $6 == *xpcall* && $6 == *DOTFILES_ASTRONVIM_HEALTH_SCRIPT* ]]; then' \
	'  phase=health' \
	'else' \
	'  exit 64' \
	'fi' \
	'[[ -f $XDG_CONFIG_HOME/nvim/lazy-lock.json ]] || exit 65' \
	'cmp -s "$CHECK_TRACKED_NVIM_LOCK" "$XDG_CONFIG_HOME/nvim/lazy-lock.json" || exit 66' \
	'create_complete_tree() {' \
	'  mkdir -p "$XDG_DATA_HOME/nvim/lazy/lazy.nvim/lua/lazy"' \
	'  mkdir -p "$XDG_DATA_HOME/nvim/lazy/AstroNvim/lua/astronvim"' \
	'  printf "offline AstroNvim version\\n" >"$XDG_DATA_HOME/nvim/lazy/AstroNvim/version.txt"' \
	'  printf "installed by fake nvim\\n" >"$XDG_DATA_HOME/nvim/fake-install-sentinel"' \
	'}' \
	'if [[ $phase == health ]]; then' \
	'  case $CHECK_FAKE_NVIM_MODE in' \
	'    success)' \
	'      printf "ok\\n" >"$DOTFILES_ASTRONVIM_HEALTH_MARKER"' \
	'      exit 0' \
	'      ;;' \
	'    health-no-marker)' \
	'      printf "simulated status-zero startup error\\n" >&2' \
	'      exit 0' \
	'      ;;' \
	'    *) exit 68 ;;' \
	'  esac' \
	'fi' \
	'case $CHECK_FAKE_NVIM_MODE in' \
	'  success|health-no-marker)' \
	'    create_complete_tree' \
	'    printf "isolated HOME\\n" >"$HOME/stage-home-sentinel"' \
	'    mkdir -p "$XDG_STATE_HOME/nvim" "$XDG_CACHE_HOME/nvim"' \
	'    printf "isolated state\\n" >"$XDG_STATE_HOME/nvim/state-sentinel"' \
	'    printf "isolated cache\\n" >"$XDG_CACHE_HOME/nvim/cache-sentinel"' \
	'    ;;' \
	'  failure)' \
	'    mkdir -p "$XDG_DATA_HOME/nvim/partial"' \
	'    printf "isolated HOME\\n" >"$HOME/stage-home-sentinel"' \
	'    printf "offline fake nvim failure\\n" >&2' \
	'    exit 42' \
	'    ;;' \
	'  malformed)' \
	'    mkdir -p "$XDG_DATA_HOME/nvim/lazy/lazy.nvim/lua/lazy"' \
	'    ;;' \
	'  lock-change)' \
	'    create_complete_tree' \
	'    printf "{}\\n" >"$XDG_CONFIG_HOME/nvim/lazy-lock.json"' \
	'    ;;' \
	'  forbidden) exit 99 ;;' \
	'  *) exit 67 ;;' \
	'esac' >"$astro_fake_bin/nvim"
chmod 755 "$astro_fake_bin/nvim"
printf '%s\n' \
	'#!/bin/sh' \
	': "${CHECK_ASTRO_GIT_LOG:?}"' \
	'if [ "$#" -eq 1 ] && [ "$1" = --version ]; then' \
	'  printf "VERSION\\n" >>"$CHECK_ASTRO_GIT_LOG"' \
	'  printf "git version 2.45.0\\n"' \
	'  exit 0' \
	'fi' \
	'printf "git" >>"$CHECK_ASTRO_GIT_LOG"' \
	'printf "\\t%s" "$@" >>"$CHECK_ASTRO_GIT_LOG"' \
	'printf "\\n" >>"$CHECK_ASTRO_GIT_LOG"' \
	'exit 99' >"$astro_fake_bin/git"
chmod 755 "$astro_fake_bin/git"

run_astronvim_bootstrap() (
	local kernel=$1 check_home=$2 fake_mode=$3 fake_log=$4
	local data_home=$5 app_name=$6
	local config_home=${CHECK_ASTRO_CONFIG_HOME:-unset}
	shift 6
	DOTFILES_CHECK_KERNEL=$kernel
	export DOTFILES_CHECK_KERNEL
	uname() { printf '%s\n' "$DOTFILES_CHECK_KERNEL"; }
	export -f uname
	PATH="$astro_fake_bin:$PATH"
	CHECK_FAKE_NVIM_LOG=$fake_log
	CHECK_FAKE_NVIM_MODE=$fake_mode
	CHECK_TRACKED_NVIM_LOCK="$repo_dir/.config/nvim/lazy-lock.json"
	CHECK_ASTRO_GIT_LOG=$astro_git_log
	export PATH CHECK_FAKE_NVIM_LOG CHECK_FAKE_NVIM_MODE
	export CHECK_TRACKED_NVIM_LOCK CHECK_ASTRO_GIT_LOG
	GIT_CONFIG_GLOBAL="$check_home/.gitconfig"
	GIT_SSL_NO_VERIFY=1
	GIT_CONFIG_NOSYSTEM=1
	GIT_CONFIG_SYSTEM="$check_home/system.gitconfig"
	GIT_CONFIG_PARAMETERS=poison
	GIT_CONFIG_COUNT=1
	GIT_CONFIG_KEY_0=http.sslVerify
	GIT_CONFIG_VALUE_0=false
	export GIT_CONFIG_GLOBAL GIT_SSL_NO_VERIFY GIT_CONFIG_NOSYSTEM
	export GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
	export GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
	unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
	unset NVIM_APPNAME
	if [[ $config_home != unset ]]; then
		XDG_CONFIG_HOME=$config_home
		export XDG_CONFIG_HOME
	fi
	if [[ $data_home != unset ]]; then
		XDG_DATA_HOME=$data_home
		export XDG_DATA_HOME
	fi
	if [[ $app_name != unset ]]; then
		NVIM_APPNAME=$app_name
		export NVIM_APPNAME
	fi
	HOME=$check_home TMUX_TPM_PATH=$offline_tpm TMPDIR=$astro_tmp \
		./bootstrap.sh "$@"
)

astro_dry_home="$check_root/astronvim-dry-run"
astro_dry_log="$check_root/astronvim-dry-run.nvim.log"
mkdir -p "$astro_dry_home"
: >"$astro_dry_log"
: >"$astro_git_log"
astro_dry_output=$(run_astronvim_bootstrap Linux "$astro_dry_home" \
	forbidden "$astro_dry_log" unset unset --dry-run)
[[ ! -s $astro_dry_log ]]
[[ ! -s $astro_git_log ]]
[[ ! -e "$astro_dry_home/.local/share/nvim" ]]
grep -Fq "INSTALL   $astro_dry_home/.local/share/nvim (AstroNvim)" \
	<<<"$astro_dry_output"

astro_apply_home="$check_root/astronvim-apply"
astro_apply_log="$check_root/astronvim-apply.nvim.log"
mkdir -p "$astro_apply_home"
: >"$astro_apply_log"
: >"$astro_git_log"
astro_apply_output=$(run_astronvim_bootstrap Linux "$astro_apply_home" \
	success "$astro_apply_log" unset unset --apply)
astro_apply_backup=$(sed -n 's/^Restore backup: //p' \
	<<<"$astro_apply_output")
[[ -d $astro_apply_backup ]]
grep -Fxq VERSION "$astro_git_log"
(( $(wc -l <"$astro_git_log") == 1 ))
(( $(grep -Fxc VERSION "$astro_apply_log") == 1 ))
(( $(grep -c '^HEADLESS' "$astro_apply_log") == 2 ))
grep -Fqx $'HEADLESS\t--headless\t-n\t-i\tNONE\t+Lazy! restore\t+qa' \
	"$astro_apply_log"
grep -Eq $'^HEADLESS\t--headless\t-n\t-i\tNONE\t--cmd\tlua .*xpcall.*DOTFILES_ASTRONVIM_HEALTH_SCRIPT' \
	"$astro_apply_log"
for astro_clean_value in \
	$'NVIM_APPNAME\tnvim' \
	$'GIT_TERMINAL_PROMPT\t0' \
	$'GIT_CONFIG_GLOBAL\t' \
	$'GIT_SSL_NO_VERIFY\t' \
	$'GIT_CONFIG_NOSYSTEM\t' \
	$'GIT_CONFIG_SYSTEM\t' \
	$'GIT_CONFIG_PARAMETERS\t' \
	$'GIT_CONFIG_COUNT\t' \
	$'SAFE_SSL_VERIFY\ttrue'; do
	(( $(grep -Fxc "$astro_clean_value" "$astro_apply_log") == 2 ))
done
grep -Fqx $'VIMINIT\t' "$astro_apply_log"
grep -Fqx $'EXINIT\t' "$astro_apply_log"
grep -Fqx $'XDG_RUNTIME_MODE\t700' "$astro_apply_log"
astro_staged_home=$(sed -n $'s/^HOME\t//p' "$astro_apply_log" | sort -u)
astro_staged_config=$(sed -n $'s/^XDG_CONFIG_HOME\t//p' \
	"$astro_apply_log" | sort -u)
astro_staged_config_dirs=$(sed -n $'s/^XDG_CONFIG_DIRS\t//p' \
	"$astro_apply_log" | sort -u)
astro_staged_data=$(sed -n $'s/^XDG_DATA_HOME\t//p' "$astro_apply_log" | sort -u)
astro_staged_data_dirs=$(sed -n $'s/^XDG_DATA_DIRS\t//p' \
	"$astro_apply_log" | sort -u)
astro_staged_state=$(sed -n $'s/^XDG_STATE_HOME\t//p' "$astro_apply_log" | sort -u)
astro_staged_cache=$(sed -n $'s/^XDG_CACHE_HOME\t//p' "$astro_apply_log" | sort -u)
astro_staged_runtime=$(sed -n $'s/^XDG_RUNTIME_DIR\t//p' "$astro_apply_log" | sort -u)
astro_staged_log=$(sed -n $'s/^NVIM_LOG_FILE\t//p' "$astro_apply_log" | sort -u)
astro_staged_work=$(sed -n $'s/^PWD\t//p' "$astro_apply_log" | sort -u)
astro_health_script=$(sed -n $'s/^DOTFILES_ASTRONVIM_HEALTH_SCRIPT\t//p' \
	"$astro_apply_log" | sort -u)
astro_staged_root=${astro_staged_config%/astronvim-config}
[[ $astro_staged_root == "$astro_tmp"/dotfiles-bootstrap.* ]]
[[ $astro_staged_home == "$astro_staged_root/astronvim-home" ]]
[[ $astro_staged_config_dirs == "$astro_staged_root/astronvim-config-dirs" ]]
[[ $astro_staged_data == "$astro_staged_root/astronvim-data" ]]
[[ $astro_staged_data_dirs == "$astro_staged_root/astronvim-data-dirs" ]]
[[ $astro_staged_state == "$astro_staged_root/astronvim-state" ]]
[[ $astro_staged_cache == "$astro_staged_root/astronvim-cache" ]]
[[ $astro_staged_runtime == "$astro_staged_root/astronvim-runtime" ]]
[[ $astro_staged_log == "$astro_staged_root/astronvim-state/nvim.log" ]]
[[ $astro_staged_work == "$astro_staged_root/astronvim-work" ]]
[[ $astro_health_script == "$astro_staged_root/astronvim-health.lua" ]]
[[ -d "$astro_apply_home/.local/share/nvim/lazy/lazy.nvim/lua/lazy" ]]
[[ -d "$astro_apply_home/.local/share/nvim/lazy/AstroNvim/lua/astronvim" ]]
grep -Fxq 'offline AstroNvim version' \
	"$astro_apply_home/.local/share/nvim/lazy/AstroNvim/version.txt"
grep -Fxq 'installed by fake nvim' \
	"$astro_apply_home/.local/share/nvim/fake-install-sentinel"
[[ ! -e "$astro_apply_home/stage-home-sentinel" ]]
grep -Fqx $'INSTALL\t.local/share/nvim\t-' \
	"$astro_apply_backup/restore.manifest"
! directory_has_entries_except "$astro_tmp"

printf '%s\n' 'preserve local AstroNvim state' \
	>"$astro_apply_home/.local/share/nvim/local-sentinel"
chmod 640 "$astro_apply_home/.local/share/nvim/local-sentinel"
: >"$astro_apply_log"
: >"$astro_git_log"
astro_idempotent_output=$(run_astronvim_bootstrap Linux "$astro_apply_home" \
	forbidden "$astro_apply_log" unset unset --apply)
[[ ! -s $astro_apply_log ]]
[[ ! -s $astro_git_log ]]
grep -Fq "UNCHANGED $astro_apply_home/.local/share/nvim/lazy/AstroNvim" \
	<<<"$astro_idempotent_output"
grep -Fxq 'preserve local AstroNvim state' \
	"$astro_apply_home/.local/share/nvim/local-sentinel"
[[ $(check_path_mode \
	"$astro_apply_home/.local/share/nvim/local-sentinel") == 640 ]]

astro_restore_preview=$(run_astronvim_bootstrap Plan9 "$astro_apply_home" \
	forbidden "$astro_apply_log" unset unset \
	--restore "$astro_apply_backup" --diff)
grep -Fq "REMOVE    $astro_apply_home/.local/share/nvim" \
	<<<"$astro_restore_preview"
grep -Fq "DIFF      skipped for external generated tree: $astro_apply_home/.local/share/nvim" \
	<<<"$astro_restore_preview"
astro_restore_output=$(run_astronvim_bootstrap Plan9 "$astro_apply_home" \
	forbidden "$astro_apply_log" unset unset \
	--restore "$astro_apply_backup" --apply)
astro_restore_safety=$(sed -n 's/^The pre-restore state is under //p' \
	<<<"$astro_restore_output")
[[ -d $astro_restore_safety ]]
[[ ! -e "$astro_apply_home/.local/share/nvim" ]]
run_astronvim_bootstrap Plan9 "$astro_apply_home" forbidden \
	"$astro_apply_log" unset unset \
	--restore "$astro_restore_safety" --apply >/dev/null
[[ -d "$astro_apply_home/.local/share/nvim/lazy/AstroNvim/lua/astronvim" ]]
grep -Fxq 'preserve local AstroNvim state' \
	"$astro_apply_home/.local/share/nvim/local-sentinel"
[[ $(check_path_mode \
	"$astro_apply_home/.local/share/nvim/local-sentinel") == 640 ]]
run_astronvim_bootstrap Plan9 "$astro_apply_home" forbidden \
	"$astro_apply_log" unset unset \
	--restore "$astro_apply_backup" --apply >/dev/null
[[ ! -e "$astro_apply_home/.local/share/nvim" ]]

astro_empty_home="$check_root/astronvim-empty-canonical"
astro_empty_log="$check_root/astronvim-empty-canonical.nvim.log"
mkdir -p "$astro_empty_home/.local/share/nvim"
chmod 711 "$astro_empty_home/.local/share/nvim"
printf '%s\n' '[user]' '  name = AstroNvim Git fixture' \
	>"$astro_empty_home/.gitconfig"
chmod 600 "$astro_empty_home/.gitconfig"
: >"$astro_empty_log"
: >"$astro_git_log"
astro_empty_plan=$(run_astronvim_bootstrap Linux "$astro_empty_home" \
	forbidden "$astro_empty_log" unset unset --dry-run)
grep -Fq "REPLACE   $astro_empty_home/.local/share/nvim (AstroNvim; backup:" \
	<<<"$astro_empty_plan"
[[ ! -s $astro_empty_log ]]
[[ ! -s $astro_git_log ]]
[[ $(check_path_mode "$astro_empty_home/.local/share/nvim") == 711 ]]
! directory_has_entries_except "$astro_empty_home/.local/share/nvim"
: >"$astro_empty_log"
: >"$astro_git_log"
astro_empty_output=$(run_astronvim_bootstrap Linux "$astro_empty_home" \
	success "$astro_empty_log" unset unset --apply)
astro_empty_backup=$(sed -n 's/^Restore backup: //p' \
	<<<"$astro_empty_output")
[[ -d $astro_empty_backup ]]
grep -Fxq VERSION "$astro_git_log"
(( $(wc -l <"$astro_git_log") == 1 ))
grep -Fqx $'GIT_CONFIG_GLOBAL\t' "$astro_empty_log"
grep -Fqx $'SAFE_SSL_VERIFY\ttrue' "$astro_empty_log"
grep -Fqx $'REPLACE\t.local/share/nvim\t.local/share/nvim' \
	"$astro_empty_backup/restore.manifest"
[[ -d "$astro_empty_home/.local/share/nvim/lazy/AstroNvim/lua/astronvim" ]]
[[ $(check_path_mode "$astro_empty_home/.local/share/nvim") == 700 ]]
[[ -d "$astro_empty_backup/.local/share/nvim" ]]
[[ $(check_path_mode "$astro_empty_backup/.local/share/nvim") == 711 ]]
! directory_has_entries_except "$astro_empty_backup/.local/share/nvim"
astro_empty_backup_snapshot="$check_root/astronvim-empty-backup.tar"
astro_empty_backup_current="$check_root/astronvim-empty-backup-current.tar"
tar -cf "$astro_empty_backup_snapshot" -C "$astro_empty_backup" .
: >"$astro_empty_log"
: >"$astro_git_log"
astro_empty_restore_output=$(run_astronvim_bootstrap Plan9 \
	"$astro_empty_home" forbidden "$astro_empty_log" unset unset \
	--restore "$astro_empty_backup" --apply)
astro_empty_safety=$(sed -n 's/^The pre-restore state is under //p' \
	<<<"$astro_empty_restore_output")
[[ -d $astro_empty_safety ]]
[[ ! -s $astro_empty_log ]]
[[ ! -s $astro_git_log ]]
[[ -d "$astro_empty_home/.local/share/nvim" ]]
[[ $(check_path_mode "$astro_empty_home/.local/share/nvim") == 711 ]]
! directory_has_entries_except "$astro_empty_home/.local/share/nvim"
grep -Fqx $'REPLACE\t.local/share/nvim\t.local/share/nvim' \
	"$astro_empty_safety/restore.manifest"
run_astronvim_bootstrap Plan9 "$astro_empty_home" forbidden \
	"$astro_empty_log" unset unset \
	--restore "$astro_empty_safety" --apply >/dev/null
[[ -d "$astro_empty_home/.local/share/nvim/lazy/AstroNvim/lua/astronvim" ]]
[[ $(check_path_mode "$astro_empty_home/.local/share/nvim") == 700 ]]
run_astronvim_bootstrap Plan9 "$astro_empty_home" forbidden \
	"$astro_empty_log" unset unset \
	--restore "$astro_empty_backup" --apply >/dev/null
[[ -d "$astro_empty_home/.local/share/nvim" ]]
[[ $(check_path_mode "$astro_empty_home/.local/share/nvim") == 711 ]]
! directory_has_entries_except "$astro_empty_home/.local/share/nvim"
tar -cf "$astro_empty_backup_current" -C "$astro_empty_backup" .
cmp -s "$astro_empty_backup_snapshot" "$astro_empty_backup_current"

astro_lock_snapshot="$check_root/astronvim-lazy-lock.snapshot"
cp -p .config/nvim/lazy-lock.json "$astro_lock_snapshot"
for astro_failure_mode in failure malformed lock-change health-no-marker; do
	astro_failure_home="$check_root/astronvim-$astro_failure_mode"
	astro_failure_log="$check_root/astronvim-$astro_failure_mode.nvim.log"
	mkdir -p "$astro_failure_home"
	printf '%s\n' 'original HOME state' >"$astro_failure_home/owner-state"
	chmod 640 "$astro_failure_home/owner-state"
	: >"$astro_failure_log"
	: >"$astro_git_log"
	if astro_failure_output=$(run_astronvim_bootstrap Linux \
		"$astro_failure_home" \
		"$astro_failure_mode" "$astro_failure_log" unset unset --apply \
		2>&1); then
		printf 'Bootstrap accepted an AstroNvim %s result\n' \
			"$astro_failure_mode" >&2
		exit 1
	fi
	grep -Fxq VERSION "$astro_git_log"
	(( $(wc -l <"$astro_git_log") == 1 ))
	case $astro_failure_mode in
		failure)
			grep -Fq 'AstroNvim plugin installation failed:' \
				<<<"$astro_failure_output"
			grep -Fq 'offline fake nvim failure' <<<"$astro_failure_output"
			;;
		malformed)
			grep -Fq 'AstroNvim installation did not produce a complete plugin tree' \
				<<<"$astro_failure_output"
			;;
		lock-change)
			grep -Fq 'AstroNvim installation unexpectedly changed lazy-lock.json' \
				<<<"$astro_failure_output"
			;;
		health-no-marker)
			grep -Fq 'AstroNvim startup validation did not complete' \
				<<<"$astro_failure_output"
			;;
	esac
	grep -Fxq 'original HOME state' "$astro_failure_home/owner-state"
	[[ $(check_path_mode "$astro_failure_home/owner-state") == 640 ]]
	! directory_has_entries_except "$astro_failure_home" \
		"$astro_failure_home/owner-state"
	! directory_has_entries_except "$astro_tmp"
	cmp -s "$astro_lock_snapshot" .config/nvim/lazy-lock.json
done

for astro_existing_kind in directory file symlink; do
	astro_existing_home="$check_root/astronvim-existing-$astro_existing_kind"
	astro_existing_log="$check_root/astronvim-existing-$astro_existing_kind.nvim.log"
	astro_existing_path="$astro_existing_home/.local/share/nvim"
	mkdir -p "$astro_existing_home/.local/share"
	case $astro_existing_kind in
		directory)
			mkdir "$astro_existing_path"
			printf '%s\n' 'preserve nonempty Neovim data' \
				>"$astro_existing_path/owner-state"
			chmod 750 "$astro_existing_path"
			chmod 640 "$astro_existing_path/owner-state"
			;;
		file)
			printf '%s\n' 'preserve Neovim data file' >"$astro_existing_path"
			chmod 640 "$astro_existing_path"
			;;
		symlink)
			astro_existing_outside="$check_root/astronvim-existing-symlink-target"
			mkdir "$astro_existing_outside"
			printf '%s\n' 'preserve symlink target' \
				>"$astro_existing_outside/owner-state"
			ln -s "$astro_existing_outside" "$astro_existing_path"
			;;
	esac
	: >"$astro_existing_log"
	: >"$astro_git_log"
	astro_existing_output=$(run_astronvim_bootstrap Linux \
		"$astro_existing_home" forbidden "$astro_existing_log" \
		unset unset --apply)
	astro_existing_backup=$(sed -n 's/^Restore backup: //p' \
		<<<"$astro_existing_output")
	[[ -d $astro_existing_backup ]]
	[[ ! -s $astro_existing_log ]]
	[[ ! -s $astro_git_log ]]
	grep -Fq "SKIP      AstroNvim preinstall (preserving existing Neovim data: $astro_existing_path)" \
		<<<"$astro_existing_output"
	if grep -Fq $'\t.local/share/nvim\t' \
		"$astro_existing_backup/restore.manifest"; then
		printf 'Bootstrap journalled preserved %s Neovim data\n' \
			"$astro_existing_kind" >&2
		exit 1
	fi
	case $astro_existing_kind in
		directory)
			grep -Fxq 'preserve nonempty Neovim data' \
				"$astro_existing_path/owner-state"
			[[ $(check_path_mode "$astro_existing_path") == 750 ]]
			[[ $(check_path_mode "$astro_existing_path/owner-state") == 640 ]]
			;;
		file)
			grep -Fxq 'preserve Neovim data file' "$astro_existing_path"
			[[ $(check_path_mode "$astro_existing_path") == 640 ]]
			;;
		symlink)
			[[ -L $astro_existing_path ]]
			[[ $(readlink "$astro_existing_path") == \
				"$astro_existing_outside" ]]
			grep -Fxq 'preserve symlink target' \
				"$astro_existing_outside/owner-state"
			;;
	esac
done

for astro_custom_kind in data config appname; do
	astro_custom_home="$check_root/astronvim-custom-$astro_custom_kind"
	astro_custom_log="$check_root/astronvim-custom-$astro_custom_kind.nvim.log"
	astro_custom_value="$check_root/astronvim-custom-$astro_custom_kind-value"
	astro_custom_data='unset'
	astro_custom_app='unset'
	astro_custom_config='unset'
	case $astro_custom_kind in
		data) astro_custom_data=$astro_custom_value ;;
		config) astro_custom_config=$astro_custom_value ;;
		appname) astro_custom_app=work-nvim ;;
	esac
	mkdir -p "$astro_custom_home"
	case $astro_custom_kind in
		data|config)
			astro_custom_preserve="$astro_custom_value/owner-state"
			mkdir -p "$astro_custom_value"
			;;
		appname)
			astro_custom_preserve="$astro_custom_home/.local/share/work-nvim/owner-state"
			mkdir -p "${astro_custom_preserve%/*}"
			;;
	esac
	printf '%s\n' 'preserve custom Neovim namespace' \
		>"$astro_custom_preserve"
	chmod 640 "$astro_custom_preserve"
	: >"$astro_custom_log"
	: >"$astro_git_log"
	if [[ $astro_custom_config == unset ]]; then
		astro_custom_output=$(run_astronvim_bootstrap Linux \
			"$astro_custom_home" forbidden "$astro_custom_log" \
			"$astro_custom_data" "$astro_custom_app" --apply)
	else
		astro_custom_output=$(CHECK_ASTRO_CONFIG_HOME=$astro_custom_config \
			run_astronvim_bootstrap Linux "$astro_custom_home" forbidden \
			"$astro_custom_log" "$astro_custom_data" \
			"$astro_custom_app" --apply)
	fi
	astro_custom_backup=$(sed -n 's/^Restore backup: //p' \
		<<<"$astro_custom_output")
	[[ -d $astro_custom_backup ]]
	[[ ! -s $astro_custom_log ]]
	[[ ! -s $astro_git_log ]]
	grep -Fq 'SKIP      AstroNvim preinstall (custom XDG or NVIM_APPNAME setting)' \
		<<<"$astro_custom_output"
	[[ ! -e "$astro_custom_home/.local/share/nvim" ]]
	grep -Fxq 'preserve custom Neovim namespace' "$astro_custom_preserve"
	[[ $(check_path_mode "$astro_custom_preserve") == 640 ]]
	if grep -Fq $'\t.local/share/nvim\t' \
		"$astro_custom_backup/restore.manifest"; then
		printf 'Bootstrap journalled an AstroNvim custom-%s skip\n' \
			"$astro_custom_kind" >&2
		exit 1
	fi
done
printf 'PASS offline AstroNvim install, isolation, restore, and failure guards\n'

# Files not named by a managed-tree manifest must never leak into HOME.
fixture_repo="$check_root/repository-fixture"
fixture_home="$check_root/manifest-filter-home"
cp -R "$repo_dir" "$fixture_repo"
mkdir -p "$fixture_home"
printf 'must not be installed\n' >"$fixture_repo/shell/unlisted.local.bash"
printf 'must not be installed\n' >"$fixture_repo/.config/nvim/unlisted.local.lua"
# Source checkout modes are not an installation contract. Deliberately corrupt
# representative modes and require bootstrap to install its explicit policy.
chmod 600 "$fixture_repo/.bashrc" \
	"$fixture_repo/.tmux/layouts/dev-3cols.sh"
chmod 777 "$fixture_repo/.tmux/load-tpm.sh" \
	"$fixture_repo/shell/aliases.bash" \
	"$fixture_repo/.config/nvim/init.lua" \
	"$fixture_repo/linux/interactive.bash"
(
	DOTFILES_CHECK_KERNEL=Linux
	export DOTFILES_CHECK_KERNEL
	uname() { printf '%s\n' "$DOTFILES_CHECK_KERNEL"; }
	export -f uname
	HOME=$fixture_home TMUX_TPM_PATH=$offline_tpm \
		XDG_DATA_HOME=$offline_astronvim_data \
		"$fixture_repo/bootstrap.sh" --apply >/dev/null
)
[[ ! -e "$fixture_home/.config/dotfiles/shell/unlisted.local.bash" ]]
[[ ! -e "$fixture_home/.config/nvim/unlisted.local.lua" ]]
[[ $(check_path_mode "$fixture_home/.bashrc") == 644 ]]
[[ $(check_path_mode "$fixture_home/.tmux/load-tpm.sh") == 755 ]]
[[ $(check_path_mode \
	"$fixture_home/.config/dotfiles/shell/aliases.bash") == 644 ]]
[[ $(check_path_mode \
	"$fixture_home/.config/dotfiles/shell/platform/linux.bash") == 644 ]]
[[ $(check_path_mode "$fixture_home/.tmux/layouts/dev-3cols.sh") == 755 ]]
[[ $(check_path_mode "$fixture_home/.config/nvim/init.lua") == 644 ]]
printf 'PASS managed-tree filtering and deterministic tracked modes\n'

# Permission drift must trigger replacement even when every byte is unchanged.
chmod 644 "$check_root/linux/.tmux/layouts/pick-repo.sh"
mode_plan=$(run_bootstrap Linux "$check_root/linux" --dry-run --diff)
if ! grep -Fq "REPLACE   $check_root/linux/.tmux/layouts" <<<"$mode_plan"; then
	printf 'Bootstrap did not detect managed-tree mode drift\n' >&2
	exit 1
fi
grep -Fq "Mode change for $check_root/linux/.tmux/layouts/pick-repo.sh: 644 -> 755" \
	<<<"$mode_plan"
run_bootstrap Linux "$check_root/linux" --apply >/dev/null
[[ -x "$check_root/linux/.tmux/layouts/pick-repo.sh" ]]
printf 'PASS bootstrap permission repair\n'

if command -v tmux >/dev/null 2>&1; then
	tmux_probe_socket="$check_root/tmux-probe.sock"
	if tmux_probe_output=$(HOME="$check_root" TMUX='' TERM=xterm-256color \
		tmux -S "$tmux_probe_socket" -f /dev/null \
		new-session -d -s dotfiles-probe 2>&1); then
		HOME="$check_root" TMUX='' tmux -S "$tmux_probe_socket" kill-server
		(
			tmux_home="$check_root/tmux-environment"
			local_socket="$check_root/tmux-environment.sock"
			tmux_p_repo="$tmux_home/repositories/project p"
			tmux_s_repo="$tmux_home/repositories/project s"
			cleanup_tmux_checks() {
				HOME="$tmux_home" TMUX='' tmux -S "$local_socket" \
					kill-server >/dev/null 2>&1 || true
			}
			trap cleanup_tmux_checks EXIT

			mkdir -p "$tmux_p_repo" "$tmux_s_repo"
			run_bootstrap Linux "$tmux_home" --apply >/dev/null

			HOME="$tmux_home" TMUX='' TERM=xterm-256color \
				DOTFILES_TMUX_P_REPO="$tmux_p_repo" \
				DOTFILES_TMUX_S_REPO="$tmux_s_repo" \
				tmux -S "$local_socket" -f "$tmux_home/.tmux.conf" \
				new-session -d -s dotfiles-environment
			p_binding=$(HOME="$tmux_home" TMUX='' tmux -S "$local_socket" \
				list-keys -T prefix P)
			s_binding=$(HOME="$tmux_home" TMUX='' tmux -S "$local_socket" \
				list-keys -T prefix S)
			grep -Fq '$HOME/.tmux/layouts/dev-3cols.sh' <<<"$p_binding"
			grep -Fq '$DOTFILES_TMUX_P_REPO' <<<"$p_binding"
			grep -Fq '$HOME/.tmux/layouts/dev-3cols.sh' <<<"$s_binding"
			grep -Fq '$DOTFILES_TMUX_S_REPO' <<<"$s_binding"

			HOME="$tmux_home" TMUX='' tmux -S "$local_socket" \
				set-environment -gu DOTFILES_TMUX_P_REPO
			HOME="$tmux_home" TMUX='' tmux -S "$local_socket" \
				set-environment -u -t dotfiles-environment \
				DOTFILES_TMUX_P_REPO
			HOME="$tmux_home" TMUX='' tmux -S "$local_socket" \
				source-file "$tmux_home/.tmux.conf"
			if HOME="$tmux_home" TMUX='' tmux -S "$local_socket" \
				list-keys -T prefix P >/dev/null 2>&1; then
				printf 'tmux reload retained stale P binding after unsetting its variable\n' >&2
				exit 1
			fi
			HOME="$tmux_home" TMUX='' tmux -S "$local_socket" \
				list-keys -T prefix S >/dev/null
			HOME="$tmux_home" TMUX='' tmux -S "$local_socket" \
				set-environment -gu DOTFILES_TMUX_S_REPO
			HOME="$tmux_home" TMUX='' tmux -S "$local_socket" \
				set-environment -u -t dotfiles-environment \
				DOTFILES_TMUX_S_REPO
			HOME="$tmux_home" TMUX='' tmux -S "$local_socket" \
				source-file "$tmux_home/.tmux.conf"
			if HOME="$tmux_home" TMUX='' tmux -S "$local_socket" \
				list-keys -T prefix S >/dev/null 2>&1; then
				printf 'tmux reload retained stale S binding after unsetting its variable\n' >&2
				exit 1
			fi
		)
		printf 'PASS tmux environment-driven P/S bindings and reload\n'
	elif grep -Eiq 'Operation not permitted|Permission denied' \
		<<<"$tmux_probe_output"; then
		printf 'SKIP tmux environment-binding integration (socket creation denied)\n'
	else
		printf 'tmux isolated-server probe failed: %s\n' "$tmux_probe_output" >&2
		exit 1
	fi
else
	printf 'SKIP tmux environment-binding integration (tmux not installed)\n'
fi

# Every applied change must be journalled so installation can be restored in
# reverse without consuming the selected backup. A restore creates another
# manifest-equipped safety backup, making the restore itself reversible.
restore_home="$check_root/restore"
restore_expected="$check_root/restore-expected"
mkdir -p \
	"$restore_home/.config" \
	"$restore_expected"
printf '%s\n' 'original profile' >"$restore_home/.bash_profile"
printf '%s\n' 'original bashrc' >"$restore_home/.bashrc"
printf '%s\n' 'machine-local canonical shell' \
	>"$restore_home/.config/extra"
printf '%s\n' 'same link payload' >"$restore_home/link-original"
printf '%s\n' 'same link payload' >"$restore_home/link-other"
ln -s link-original "$restore_home/.wgetrc"
mkdir -p "$restore_home/.config/nvim"
printf '%s\n' 'same nested payload' \
	>"$restore_home/.config/nvim/target-original"
printf '%s\n' 'same nested payload' >"$restore_home/.config/nvim/target-other"
ln -s target-original "$restore_home/.config/nvim/nested-link"
ln -s missing-target "$restore_home/.config/nvim/dangling-link"
chmod 600 "$restore_home/.bash_profile"
chmod 640 "$restore_home/.bashrc"
chmod 750 "$restore_home/.config"
chmod 600 "$restore_home/.config/extra"
cp -p "$restore_home/.bash_profile" "$restore_expected/.bash_profile"
cp -p "$restore_home/.bashrc" "$restore_expected/.bashrc"

local_overlay_files=(
	.config/extra
)
local_overlay_directories=(
	.config
)
for relative in "${local_overlay_files[@]}"; do
	expected_parent=${relative%/*}
	[[ $expected_parent != "$relative" ]] || expected_parent=.
	mkdir -p "$restore_expected/$expected_parent"
	cp -p "$restore_home/$relative" "$restore_expected/$relative"
done
unset expected_parent

assert_local_overlays_preserved() {
	local relative
	for relative in "${local_overlay_files[@]}"; do
		cmp -s "$restore_expected/$relative" "$restore_home/$relative"
		[[ $(check_path_mode "$restore_expected/$relative") == \
			$(check_path_mode "$restore_home/$relative") ]]
	done
	for relative in "${local_overlay_directories[@]}"; do
		[[ $(check_path_mode "$restore_expected/$relative") == \
			$(check_path_mode "$restore_home/$relative") ]]
	done
}

for relative in "${local_overlay_directories[@]}"; do
	mkdir -p "$restore_expected/$relative"
	chmod "$(check_path_mode "$restore_home/$relative")" \
		"$restore_expected/$relative"
done

restore_install_output=$(run_bootstrap Linux "$restore_home" --apply)
restore_backup=$(sed -n 's/^Restore backup: //p' <<<"$restore_install_output")
if [[ -z $restore_backup || ! -d $restore_backup ]]; then
	printf 'Bootstrap did not report a usable restore backup\n' >&2
	exit 1
fi
[[ $(check_path_mode "$restore_backup") == 700 ]]
[[ $(check_path_mode "$restore_backup/restore.manifest") == 600 ]]
grep -Fxq 'dotfiles-restore-v1' <(sed -n '1p' "$restore_backup/restore.manifest")
grep -Fqx $'REPLACE\t.bash_profile\t.bash_profile' \
	"$restore_backup/restore.manifest"
grep -Fqx $'INSTALL\t.config/starship.toml\t-' \
	"$restore_backup/restore.manifest"
grep -Fqx $'INSTALL\t.config/dotfiles/shell\t-' \
	"$restore_backup/restore.manifest"
for relative in "${local_overlay_files[@]}"; do
	if grep -Fq $'\t'"$relative"$'\t' "$restore_backup/restore.manifest"; then
		printf 'Restore manifest unexpectedly manages local overlay: %s\n' \
			"$relative" >&2
		exit 1
	fi
done
cmp -s .config/starship.toml "$restore_home/.config/starship.toml"
assert_local_overlays_preserved
cmp -s shell/env.bash "$restore_home/.config/dotfiles/shell/env.bash"

# Different symlink text must not compare equal merely because both targets
# currently contain the same bytes.
mv "$restore_home/.wgetrc" "$restore_expected/managed-wgetrc"
ln -s link-other "$restore_home/.wgetrc"

restore_backup_snapshot="$check_root/restore-backup.tar"
restore_backup_current="$check_root/restore-backup-current.tar"
tar -cf "$restore_backup_snapshot" -C "$restore_backup" .
assert_restore_backup_unchanged() {
	tar -cf "$restore_backup_current" -C "$restore_backup" .
	cmp -s "$restore_backup_snapshot" "$restore_backup_current"
}
restore_preview=$(run_bootstrap Plan9 "$restore_home" --restore "$restore_backup")
grep -Fq "RESTORE   $restore_home/.bash_profile" <<<"$restore_preview"
grep -Fq "RESTORE   $restore_home/.wgetrc" <<<"$restore_preview"
grep -Fq "REMOVE    $restore_home/.config/starship.toml" <<<"$restore_preview"
cmp -s .bash_profile "$restore_home/.bash_profile"

# An otherwise blocking Git file must not prevent recovery.
printf '%s\n' '[user]' '  name = restore sentinel' >"$restore_home/.gitconfig"
restore_output=$(run_bootstrap Plan9 "$restore_home" \
	--restore "$restore_backup" --apply)
restore_safety=$(sed -n 's/^The pre-restore state is under //p' \
	<<<"$restore_output")
if [[ -z $restore_safety || ! -d $restore_safety ]]; then
	printf 'Restore did not create a usable safety backup\n' >&2
	exit 1
fi
grep -Fqx "Pre-restore safety backup: $restore_safety" <<<"$restore_output"
[[ $(check_path_mode "$restore_safety") == 700 ]]
[[ $(check_path_mode "$restore_safety/restore.manifest") == 600 ]]
cmp -s "$restore_expected/.bash_profile" "$restore_home/.bash_profile"
cmp -s "$restore_expected/.bashrc" "$restore_home/.bashrc"
assert_local_overlays_preserved
[[ $(check_path_mode "$restore_home/.bash_profile") == 600 ]]
[[ $(check_path_mode "$restore_home/.bashrc") == 640 ]]
[[ ! -e "$restore_home/.config/starship.toml" ]]
[[ ! -e "$restore_home/.config/dotfiles/shell" ]]
[[ -L "$restore_home/.wgetrc" ]]
[[ $(readlink "$restore_home/.wgetrc") == link-original ]]
[[ -L "$restore_home/.config/nvim/nested-link" ]]
[[ $(readlink "$restore_home/.config/nvim/nested-link") == target-original ]]
[[ -L "$restore_home/.config/nvim/dangling-link" ]]
[[ $(readlink "$restore_home/.config/nvim/dangling-link") == missing-target ]]
assert_restore_backup_unchanged

rm "$restore_home/.config/nvim/nested-link"
ln -s target-other "$restore_home/.config/nvim/nested-link"
nested_symlink_preview=$(run_bootstrap Plan9 "$restore_home" \
	--restore "$restore_backup")
grep -Fq "RESTORE   $restore_home/.config/nvim" \
	<<<"$nested_symlink_preview"
run_bootstrap Plan9 "$restore_home" --restore "$restore_backup" --apply \
	>/dev/null
[[ $(readlink "$restore_home/.config/nvim/nested-link") == target-original ]]

# The safety backup can undo the restore and recover even a post-install local
# edit, while the original selected backup remains immutable.
run_bootstrap Plan9 "$restore_home" --restore "$restore_safety" --apply >/dev/null
cmp -s .bash_profile "$restore_home/.bash_profile"
cmp -s .config/starship.toml "$restore_home/.config/starship.toml"
grep -Fq 'restore sentinel' "$restore_home/.gitconfig"
[[ -L "$restore_home/.wgetrc" ]]
[[ $(readlink "$restore_home/.wgetrc") == link-other ]]
assert_local_overlays_preserved
assert_restore_backup_unchanged

# Reapplying the original restore reaches a stable no-op plan.
run_bootstrap Plan9 "$restore_home" --restore "$restore_backup" --apply >/dev/null
[[ -L "$restore_home/.wgetrc" ]]
[[ $(readlink "$restore_home/.wgetrc") == link-original ]]
assert_local_overlays_preserved
restore_second_preview=$(run_bootstrap Plan9 "$restore_home" \
	--restore "$restore_backup")
if grep -Eq '^(RESTORE|REMOVE)' <<<"$restore_second_preview"; then
	printf 'A completed restore did not become idempotent\n' >&2
	exit 1
fi

restore_validation_sentinel="$check_root/restore-validation-profile"
cp -p "$restore_home/.bash_profile" "$restore_validation_sentinel"
restore_parent="$restore_home/.local/state/dotfiles/backups"

assert_restore_rejected() {
	local candidate=$1 description=$2
	if run_bootstrap Plan9 "$restore_home" --restore "$candidate" --apply \
		>/dev/null 2>&1; then
		printf 'Restore accepted %s\n' "$description" >&2
		exit 1
	fi
	cmp -s "$restore_validation_sentinel" "$restore_home/.bash_profile"
	assert_local_overlays_preserved
}

missing_manifest="$restore_parent/missing-manifest"
mkdir -p "$missing_manifest"
assert_restore_rejected "$missing_manifest" 'a backup without a manifest'

late_invalid="$restore_parent/late-invalid"
mkdir -p "$late_invalid"
printf '%s\n' \
	'dotfiles-restore-v1' \
	$'INSTALL\t.bash_profile\t-' \
	$'INSTALL\t../escape\t-' >"$late_invalid/restore.manifest"
assert_restore_rejected "$late_invalid" 'a traversal after a valid action'

exact_parent="$restore_parent/exact-parent"
mkdir -p "$exact_parent"
printf '%s\n' 'dotfiles-restore-v1' $'INSTALL\t..\t-' \
	>"$exact_parent/restore.manifest"
assert_restore_rejected "$exact_parent" 'the exact parent-directory target'

canonical_protected="$restore_parent/canonical-protected-target"
mkdir -p "$canonical_protected"
printf '%s\n' \
	'dotfiles-restore-v1' \
	$'INSTALL\t.bash_profile\t-' \
	$'INSTALL\t.config/extra\t-' \
	>"$canonical_protected/restore.manifest"
assert_restore_rejected "$canonical_protected" \
	'an exact canonical local-overlay target'

case_variant_target="$restore_parent/case-variant-target"
mkdir -p "$case_variant_target"
printf '%s\n' \
	'dotfiles-restore-v1' \
	$'INSTALL\t.CONFIG/EXTRA\t-' \
	>"$case_variant_target/restore.manifest"
assert_restore_rejected "$case_variant_target" \
	'a case-variant target unsafe on case-insensitive filesystems'

canonical_ancestor="$restore_parent/canonical-protected-ancestor"
mkdir -p "$canonical_ancestor"
printf '%s\n' \
	'dotfiles-restore-v1' \
	$'INSTALL\t.bash_profile\t-' \
	$'INSTALL\t.config\t-' \
	>"$canonical_ancestor/restore.manifest"
assert_restore_rejected "$canonical_ancestor" \
	'an ancestor of canonical local overlays'

ln -s .config "$restore_home/config-alias"
symlink_alias_target="$restore_parent/symlink-alias-target"
mkdir -p "$symlink_alias_target"
printf '%s\n' \
	'dotfiles-restore-v1' \
	$'INSTALL\tconfig-alias/extra\t-' \
	>"$symlink_alias_target/restore.manifest"
assert_restore_rejected "$symlink_alias_target" \
	'a target reaching a local overlay through a symlink ancestor'
mkdir -p "$restore_home/.config/dotfiles/shell"
ln -s ../../.. "$restore_home/.config/dotfiles/shell/local-overlay-alias"
managed_descendant_alias="$restore_parent/managed-descendant-alias"
mkdir -p "$managed_descendant_alias"
printf '%s\n' \
	'dotfiles-restore-v1' \
	$'INSTALL\t.config/dotfiles/shell/local-overlay-alias/.config/extra\t-' \
	>"$managed_descendant_alias/restore.manifest"
assert_restore_rejected "$managed_descendant_alias" \
	'a managed-tree descendant reaching a local overlay through a symlink'

overlap_manifest="$restore_parent/overlap"
mkdir -p "$overlap_manifest"
printf '%s\n' \
	'dotfiles-restore-v1' \
	$'INSTALL\t.cache/overlap\t-' \
	$'INSTALL\t.cache/overlap/test\t-' >"$overlap_manifest/restore.manifest"
assert_restore_rejected "$overlap_manifest" 'overlapping targets'

missing_payload="$restore_parent/missing-payload"
mkdir -p "$missing_payload"
printf '%s\n' 'dotfiles-restore-v1' \
	$'REPLACE\t.bash_profile\tmissing' >"$missing_payload/restore.manifest"
assert_restore_rejected "$missing_payload" 'a missing payload'

outside_payload="$check_root/outside-restore-payload"
mkdir -p "$outside_payload"
printf '%s\n' 'outside' >"$outside_payload/profile"
escaping_payload="$restore_parent/escaping-payload"
mkdir -p "$escaping_payload"
ln -s "$outside_payload" "$escaping_payload/payload"
printf '%s\n' 'dotfiles-restore-v1' \
	$'REPLACE\t.bash_profile\tpayload/profile' \
	>"$escaping_payload/restore.manifest"
assert_restore_rejected "$escaping_payload" 'a symlink-escaping payload'

symlink_restore="$restore_parent/symlink-root"
ln -s "$restore_backup" "$symlink_restore"
assert_restore_rejected "$symlink_restore" 'a symlink restore root'

operation_lock="$restore_home/.local/state/dotfiles/bootstrap.lock"
mkdir "$operation_lock"
assert_restore_rejected "$restore_backup" 'a concurrent bootstrap apply'
rmdir "$operation_lock"
[[ ! -e $operation_lock ]]
printf 'PASS reversible bootstrap restore and validation guards\n'

# The local shell overlay remains outside bootstrap's managed set and loads
# exactly once after the applicable shared layers.
shell_overlay_home="$check_root/shell-overlay"
mkdir -p "$shell_overlay_home/.config"
printf '%s\n' \
	'LOCAL_PROFILE_SENTINEL=loaded' \
	'if [ -n "$BASH_VERSION" ] && [ -r "$HOME/.bashrc" ]; then' \
	'  . "$HOME/.bashrc"' \
	'fi' >"$shell_overlay_home/.profile"
printf '%s\n' \
	'LOCAL_SHELL_LOAD_COUNT=$(( ${LOCAL_SHELL_LOAD_COUNT:-0} + 1 ))' \
	'LOCAL_SHELL_SOURCE=canonical' \
	'[[ ${DOTFILES_ENV_LOADED:-} == 1 ]] && LOCAL_SHELL_SAW_ENV=1' \
	'if alias g >/dev/null 2>&1; then' \
	'  LOCAL_SHELL_SAW_SHARED_ALIAS=1' \
	'fi' \
	'export LOCAL_SHELL_ENV_SENTINEL=loaded' \
	"alias local_shell_sentinel='printf local-shell-sentinel'" \
	>"$shell_overlay_home/.config/extra"
chmod 600 "$shell_overlay_home/.config/extra"
cp -p "$shell_overlay_home/.config/extra" \
	"$check_root/shell-overlay.expected"

shell_overlay_plan=$(run_bootstrap Linux "$shell_overlay_home" --dry-run)
if grep -Fq "$shell_overlay_home/.config/extra" <<<"$shell_overlay_plan"; then
	printf 'Bootstrap planned a change to a local shell overlay\n' >&2
	exit 1
fi
run_bootstrap Linux "$shell_overlay_home" --apply >/dev/null
cmp -s "$check_root/shell-overlay.expected" \
	"$shell_overlay_home/.config/extra"
[[ $(check_path_mode "$shell_overlay_home/.config/extra") == 600 ]]
[[ $(check_path_mode "$shell_overlay_home/.local/state/dotfiles/backups") == 700 ]]

if ! HOME=$shell_overlay_home BASH_ENV='' bash --noprofile --norc -ic '
	unset DOTFILES_ENV_LOADED DOTFILES_INTERACTIVE_LOADED
	unset DOTFILES_LOCAL_SHELL_LOADED
	unset LOCAL_SHELL_LOAD_COUNT LOCAL_SHELL_SOURCE LOCAL_SHELL_SAW_ENV
	unset LOCAL_SHELL_SAW_SHARED_ALIAS LOCAL_SHELL_ENV_SENTINEL
	unset LOCAL_PROFILE_SENTINEL
	source "$HOME/.bashrc"
	[[ ${LOCAL_SHELL_LOAD_COUNT:-0} == 1 ]]
	[[ ${LOCAL_SHELL_SOURCE:-} == canonical ]]
	[[ ${LOCAL_SHELL_ENV_SENTINEL:-} == loaded ]]
	[[ ${LOCAL_SHELL_SAW_ENV:-} == 1 ]]
	[[ ${LOCAL_SHELL_SAW_SHARED_ALIAS:-} == 1 ]]
	alias local_shell_sentinel >/dev/null
	source "$HOME/.bashrc"
	[[ $LOCAL_SHELL_LOAD_COUNT == 1 ]]
' >/dev/null 2>&1; then
	printf 'Interactive non-login shell did not select the canonical overlay once\n' >&2
	exit 1
fi

if ! HOME=$shell_overlay_home BASH_ENV='' bash --noprofile --norc -ic '
	unset DOTFILES_ENV_LOADED DOTFILES_INTERACTIVE_LOADED
	unset DOTFILES_LOCAL_SHELL_LOADED
	unset DOTFILES_PROFILE_LOADED DOTFILES_LOADING_PROFILE
	unset LOCAL_SHELL_LOAD_COUNT LOCAL_SHELL_SOURCE LOCAL_SHELL_SAW_ENV
	unset LOCAL_SHELL_SAW_SHARED_ALIAS LOCAL_SHELL_ENV_SENTINEL
	unset LOCAL_PROFILE_SENTINEL
	source "$HOME/.bash_profile"
	[[ ${LOCAL_SHELL_LOAD_COUNT:-0} == 1 ]]
	[[ ${LOCAL_SHELL_SOURCE:-} == canonical ]]
	[[ ${LOCAL_PROFILE_SENTINEL:-} == loaded ]]
	[[ ${LOCAL_SHELL_SAW_ENV:-} == 1 ]]
	[[ ${LOCAL_SHELL_SAW_SHARED_ALIAS:-} == 1 ]]
' >/dev/null 2>&1; then
	printf 'Interactive login shell did not select the canonical overlay once\n' >&2
	exit 1
fi

if ! HOME=$shell_overlay_home BASH_ENV='' bash --noprofile --norc -c '
	unset DOTFILES_ENV_LOADED DOTFILES_INTERACTIVE_LOADED
	unset DOTFILES_LOCAL_SHELL_LOADED
	unset DOTFILES_PROFILE_LOADED DOTFILES_LOADING_PROFILE
	unset LOCAL_SHELL_LOAD_COUNT LOCAL_SHELL_SOURCE LOCAL_SHELL_SAW_ENV
	unset LOCAL_SHELL_SAW_SHARED_ALIAS LOCAL_SHELL_ENV_SENTINEL
	unset LOCAL_PROFILE_SENTINEL
	source "$HOME/.bash_profile"
	[[ ${LOCAL_SHELL_LOAD_COUNT:-0} == 1 ]]
	[[ ${LOCAL_SHELL_SOURCE:-} == canonical ]]
	[[ ${LOCAL_PROFILE_SENTINEL:-} == loaded ]]
	[[ ${LOCAL_SHELL_SAW_ENV:-} == 1 ]]
	[[ -z ${LOCAL_SHELL_SAW_SHARED_ALIAS:-} ]]
'; then
	printf 'Non-interactive login shell did not load the canonical overlay last\n' >&2
	exit 1
fi

if ! HOME=$shell_overlay_home BASH_ENV='' bash --noprofile --norc -c '
	unset LOCAL_SHELL_LOAD_COUNT
	source "$HOME/.bashrc"
	[[ -z ${LOCAL_SHELL_LOAD_COUNT:-} ]]
'; then
	printf 'Ordinary non-interactive shell unexpectedly loaded a local overlay\n' >&2
	exit 1
fi
printf 'PASS canonical shell overlay behavior\n'

read_global_git_config() {
	local check_home=$1
	shift
	HOME=$check_home XDG_CONFIG_HOME="$check_home/.config" \
		GIT_CONFIG_NOSYSTEM=1 git config --global --includes "$@"
}

# The tracked identity is the default everywhere. Per-command environment
# variables can still select a different author/committer email when needed.
git_identity_home="$check_root/git-identity"
git_identity_repo="$git_identity_home/repository"
mkdir -p "$git_identity_home"
run_bootstrap Linux "$git_identity_home" --apply >/dev/null
[[ $(read_global_git_config "$git_identity_home" --get user.name) == \
	'Diego Russo' ]]
[[ $(read_global_git_config "$git_identity_home" --get user.email) == \
	'me@diegor.it' ]]
if read_global_git_config "$git_identity_home" --get-all include.path \
	>/dev/null 2>&1 || \
	read_global_git_config "$git_identity_home" \
	--get-regexp '^includeIf\.' >/dev/null 2>&1; then
	printf 'Tracked Git config retained an include layer\n' >&2
	exit 1
fi
HOME=$git_identity_home XDG_CONFIG_HOME="$git_identity_home/.config" \
	GIT_CONFIG_NOSYSTEM=1 git init -q "$git_identity_repo"
printf '%s\n' 'identity override fixture' >"$git_identity_repo/fixture.txt"
HOME=$git_identity_home XDG_CONFIG_HOME="$git_identity_home/.config" \
	GIT_CONFIG_NOSYSTEM=1 git -C "$git_identity_repo" add fixture.txt
HOME=$git_identity_home XDG_CONFIG_HOME="$git_identity_home/.config" \
	GIT_CONFIG_NOSYSTEM=1 \
	GIT_AUTHOR_EMAIL=work@example.test \
	GIT_COMMITTER_EMAIL=work@example.test \
	git -C "$git_identity_repo" commit -q -m 'Test environment identity override'
git_commit_identity=$(
	HOME=$git_identity_home XDG_CONFIG_HOME="$git_identity_home/.config" \
		GIT_CONFIG_NOSYSTEM=1 git -C "$git_identity_repo" \
		show -s --format='%an <%ae>|%cn <%ce>' HEAD
)
[[ $git_commit_identity == \
	'Diego Russo <work@example.test>|Diego Russo <work@example.test>' ]]
[[ $(read_global_git_config "$git_identity_home" --get user.email) == \
	'me@diegor.it' ]]
printf 'PASS tracked Git identity and environment override\n'

run_macos_defaults_dry() (
	local check_home=$1
	DOTFILES_CHECK_KERNEL=Darwin
	export DOTFILES_CHECK_KERNEL
	uname() { printf '%s\n' "$DOTFILES_CHECK_KERNEL"; }
	export -f uname
	HOME=$check_home bash macos/defaults.sh --dry-run
)

macos_dry_run=$(run_macos_defaults_dry "$check_root/macos-defaults")
grep -Fq 'Dry run only. Re-run with --apply' <<<"$macos_dry_run"
printf 'PASS macOS defaults dry run\n'

macos_apply_home="$check_root/macos-defaults-apply"
mkdir -p "$macos_apply_home"
(
	DOTFILES_CHECK_KERNEL=Darwin
	export DOTFILES_CHECK_KERNEL
	uname() { printf '%s\n' "$DOTFILES_CHECK_KERNEL"; }
	defaults() {
		case $1 in
			export)
				if [[ $2 == com.apple.Safari ]]; then
					return 1
				fi
				printf 'test plist for %s\n' "$2" >"$3"
				;;
			read) return 1 ;;
			write) return 0 ;;
			*) return 2 ;;
		esac
	}
	killall() { return 0; }
	export -f uname defaults killall
	HOME=$macos_apply_home bash macos/defaults.sh --apply >/dev/null
)
macos_backup=
for candidate in "$macos_apply_home/.local/state/dotfiles/macos-defaults"/*; do
	[[ -d $candidate ]] || continue
	macos_backup=$candidate
	break
done
[[ -n $macos_backup ]]
[[ $(check_path_mode "$macos_apply_home/.local/state/dotfiles/macos-defaults") == 700 ]]
[[ $(check_path_mode "$macos_backup") == 700 ]]
[[ -f "$macos_backup/NSGlobalDomain.plist" ]]
[[ -f "$macos_backup/com.apple.desktopservices.plist" ]]
[[ -f "$macos_backup/com.apple.Safari.absent" ]]

macos_failure_home="$check_root/macos-defaults-failure"
mkdir -p "$macos_failure_home"
if (
	DOTFILES_CHECK_KERNEL=Darwin
	export DOTFILES_CHECK_KERNEL
	uname() { printf '%s\n' "$DOTFILES_CHECK_KERNEL"; }
	defaults() {
		case $1 in
			export)
				[[ $2 != com.apple.dock ]] || return 1
				printf 'test plist for %s\n' "$2" >"$3"
				;;
			read)
				[[ $2 == com.apple.dock ]]
				;;
			write)
				printf 'unexpected write\n' >"$HOME/write-called"
				;;
			*) return 2 ;;
		esac
	}
	killall() { return 0; }
	export -f uname defaults killall
	HOME=$macos_failure_home bash macos/defaults.sh --apply >/dev/null 2>&1
); then
	printf 'macOS defaults applied after an existing-domain backup failure\n' >&2
	exit 1
fi
[[ ! -e "$macos_failure_home/write-called" ]]
printf 'PASS macOS defaults backup and failure guard\n'

git diff --check

while IFS= read -r -d '' file; do
	if whitespace_output=$(git diff --no-index --check -- /dev/null "$file" 2>&1); then
		whitespace_status=0
	else
		whitespace_status=$?
	fi
	if (( whitespace_status > 1 )) || [[ -n $whitespace_output ]]; then
		printf 'Whitespace error in untracked file %s:\n%s\n' \
			"$file" "$whitespace_output" >&2
		exit 1
	fi
done < <(git ls-files --others --exclude-standard -z)
printf 'PASS tracked and untracked whitespace\n'

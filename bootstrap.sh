#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: ./bootstrap.sh [--dry-run | --apply] [-d | --diff]
       ./bootstrap.sh --restore BACKUP [--dry-run | --apply] [-d | --diff]

	--dry-run      Show the exact installation plan (the default).
	--apply        Install missing Homebrew and back up/install tracked files.
	--restore PATH Preview or apply restoration from a managed backup.
	-d, --diff     Show content and mode differences for changed managed dotfiles.
	-h, --help     Show this help.

Diffs use colour in terminals; set NO_COLOR=1 to disable it.

The script never pulls this repository, runs apt, changes the login shell, or
overwrites ~/.config/extra. Apply mode may run Homebrew's official
installer (which can request sudo), and access GitHub to install a missing TPM
and the locked AstroNvim plugin set. Brewfile packages remain a separate step
using ./brew.sh --apply. Restore previews and
installation dry runs are offline and read-only; use --apply explicitly to
change HOME.
EOF
}

mode=dry-run
restore_source=
show_diff=false

while (( $# > 0 )); do
	case $1 in
		--dry-run) mode=dry-run ;;
		--apply) mode=apply ;;
		-d|--diff) show_diff=true ;;
		--restore)
			if (( $# < 2 )) || [[ $2 == -* ]]; then
				printf '%s\n' '--restore requires a backup directory' >&2
				exit 2
			fi
			if [[ -n $restore_source ]]; then
				printf '%s\n' '--restore may only be specified once' >&2
				exit 2
			fi
			restore_source=$2
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			printf 'Unknown option: %s\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
	shift
done

diff_color=false
if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
	diff_color=true
fi

if [[ -z ${HOME:-} || $HOME != /* || ! -d $HOME ]]; then
	printf 'Refusing to run with an empty, relative, or missing HOME\n' >&2
	exit 1
fi
HOME=$(CDPATH='' cd -- "$HOME" && pwd -P) || exit
export HOME
if [[ $HOME == / ]]; then
	printf 'Refusing to install or restore with root as HOME\n' >&2
	exit 1
fi

repo_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_parent="$HOME/.local/state/dotfiles/backups"
restore_safety_parent="$HOME/.local/state/dotfiles/restore-safety"
operation_lock=
scratch_parent=
scratch_root=
diff_empty_directory=
bootstrap_git_config=
bootstrap_git_home=
bootstrap_git_xdg_config=
tpm_repository=https://github.com/tmux-plugins/tpm
tpm_version=v3.1.0
tpm_destination="$HOME/.tmux/plugins/tpm"
astronvim_relative='.local/share/nvim'
astronvim_destination="$HOME/$astronvim_relative"
astronvim_config_home=${XDG_CONFIG_HOME:-$HOME/.config}
astronvim_config_home=${astronvim_config_home%/}
astronvim_data_home=${XDG_DATA_HOME:-$HOME/.local/share}
astronvim_data_home=${astronvim_data_home%/}
astronvim_appname=${NVIM_APPNAME:-nvim}
astronvim_detect_root="$astronvim_data_home/$astronvim_appname"
astronvim_preinstall_supported=false
if [[ $astronvim_config_home == "$HOME/.config" && \
	$astronvim_data_home == "$HOME/.local/share" && \
	$astronvim_appname == nvim ]]; then
	astronvim_preinstall_supported=true
fi
astronvim_preinstall_unavailable=false
astronvim_skip_reason=

select_backup_root() {
	local suffix=0
	backup_root="$backup_parent/$timestamp"
	while [[ -e $backup_root || -L $backup_root ]]; do
		suffix=$((suffix + 1))
		backup_root="$backup_parent/${timestamp}-${suffix}"
	done
}

select_restore_safety_root() {
	local suffix=0
	restore_safety_root="$restore_safety_parent/$timestamp"
	while [[ -e $restore_safety_root || -L $restore_safety_root ]]; do
		suffix=$((suffix + 1))
		restore_safety_root="$restore_safety_parent/${timestamp}-${suffix}"
	done
}

cleanup_runtime() {
	if [[ -n ${scratch_root:-} ]]; then
		case $scratch_root in
			"$scratch_parent"/dotfiles-bootstrap.*) rm -rf -- "$scratch_root" ;;
		esac
	fi
	if [[ -n ${operation_lock:-} && -d $operation_lock && ! -L $operation_lock ]]; then
		rmdir -- "$operation_lock" 2>/dev/null || true
	fi
}
trap cleanup_runtime EXIT

acquire_operation_lock() {
	local state_root="$HOME/.local/state/dotfiles"
	local candidate="$state_root/bootstrap.lock"

	validate_home_destination "$candidate" '.local/state/dotfiles/bootstrap.lock'
	if [[ -L $state_root || ( -e $state_root && ! -d $state_root ) ]]; then
		printf 'Dotfiles state path is not a normal directory: %s\n' \
			"$state_root" >&2
		return 1
	fi
	ensure_home_parent_directories "$candidate" \
		'.local/state/dotfiles/bootstrap.lock'
	chmod 700 "$state_root"
	if ! mkdir "$candidate" 2>/dev/null; then
		printf 'Another bootstrap apply is running, or a stale lock remains: %s\n' \
			"$candidate" >&2
		printf 'After verifying no bootstrap process is active, remove it with: rmdir -- "%s"\n' \
			"$candidate" >&2
		return 1
	fi
	operation_lock=$candidate
	chmod 700 "$operation_lock"
}

find_tpm_path() {
	sh "$repo_dir/.tmux/load-tpm.sh" --print-path
}

find_homebrew() {
	local candidate
	if candidate=$(type -P brew); then
		printf '%s\n' "$candidate"
		return 0
	fi
	if [[ -n ${HOMEBREW_PREFIX:-} && -x $HOMEBREW_PREFIX/bin/brew ]]; then
		printf '%s\n' "$HOMEBREW_PREFIX/bin/brew"
		return 0
	fi
	for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew \
		/home/linuxbrew/.linuxbrew/bin/brew; do
		if [[ -x $candidate ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

setup_homebrew() {
	local brew_path brew_environment
	local installer="$scratch_root/homebrew-install.sh"
	local installer_url=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh

	if brew_path=$(find_homebrew); then
		printf 'UNCHANGED %s (Homebrew)\n' "$brew_path"
	else
		printf 'INSTALL   Homebrew (official installer; standard platform prefix)\n'
		[[ $mode == apply ]] || return 0
		if ! command -v curl >/dev/null 2>&1; then
			printf '%s\n' 'Homebrew installation requires curl; see the prerequisites in README.md.' >&2
			return 1
		fi
		# Download completely before execution and ignore per-user curl settings.
		if ! curl --disable --fail --show-error --location --proto '=https' \
			--tlsv1.2 --output "$installer" "$installer_url"; then
			printf '%s\n' 'Could not download the official Homebrew installer.' >&2
			return 1
		fi
		# Keep the real HOME for ownership and sudo, but isolate Git configuration
		# so GitHub HTTPS clones do not inherit SSH rewrites or disabled TLS checks.
		if ! (
			unset GIT_CONFIG_NOSYSTEM GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS
			unset GIT_CONFIG_COUNT GIT_SSL_NO_VERIFY
			GIT_CONFIG_GLOBAL="$bootstrap_git_config" GIT_TERMINAL_PROMPT=0 \
				/bin/bash "$installer"
		); then
			printf '%s\n' 'Homebrew installation failed; check the installer output, prerequisites, and sudo access.' >&2
			return 1
		fi
		if ! brew_path=$(find_homebrew); then
			printf '%s\n' 'The Homebrew installer finished, but no brew executable was found.' >&2
			return 1
		fi
	fi

	if [[ $mode == apply ]]; then
		if ! HOMEBREW_NO_AUTO_UPDATE=1 "$brew_path" --version >/dev/null; then
			printf 'Homebrew is present but unusable: %s\n' "$brew_path" >&2
			return 1
		fi
		if ! brew_environment=$(HOMEBREW_NO_AUTO_UPDATE=1 "$brew_path" shellenv bash); then
			printf 'Could not load the Homebrew environment: %s\n' "$brew_path" >&2
			return 1
		fi
		eval "$brew_environment"
	fi
}

astronvim_is_installed() {
	[[ $astronvim_detect_root == /* && \
		-d $astronvim_detect_root/lazy/AstroNvim/lua/astronvim && \
		-f $astronvim_detect_root/lazy/AstroNvim/version.txt ]]
}

astronvim_target_is_seedable() {
	if [[ ! -e $astronvim_destination && ! -L $astronvim_destination ]]; then
		return 0
	fi
	[[ -d $astronvim_destination && ! -L $astronvim_destination ]] || return 1
	directory_is_empty "$astronvim_destination"
}

select_backup_root
select_restore_safety_root

if [[ -n $restore_source ]]; then
	# Restoration is self-contained in its backup and must remain available even
	# when platform detection or the current install manifest is broken.
	platform=restore
else
	case "$(uname -s)" in
		Darwin) platform=macos ;;
		Linux) platform=linux ;;
		*)
			printf 'Unsupported platform: %s\n' "$(uname -s)" >&2
			exit 1
			;;
	esac
fi

# Each adjacent pair is a repository-relative source and a HOME-relative
# destination. Keeping this list explicit prevents untracked files and
# platform-only provisioning scripts from leaking into HOME.
manifest=(
	'.bash_profile' '.bash_profile'
	'.bashrc' '.bashrc'
	'.curlrc' '.curlrc'
	'.gdbinit' '.gdbinit'
	'.gitconfig' '.gitconfig'
	'.hushlogin' '.hushlogin'
	'.inputrc' '.inputrc'
	'.tmux.conf' '.tmux.conf'
	'.wgetrc' '.wgetrc'
	'.config/starship.toml' '.config/starship.toml'
	'.gitignore' '.gitignore'
	'.tmux/load-tpm.sh' '.tmux/load-tpm.sh'
)

if [[ $platform == macos ]]; then
	manifest+=(
		'.config/ghostty/config.ghostty'
		'Library/Application Support/com.mitchellh.ghostty/config.ghostty'
	)
fi

# Managed directories are assembled from exact file lists before installation.
# This prevents an ignored editor cache, local override, or other untracked file
# beneath one of these source directories from leaking into HOME.
bash_files=(
	aliases.bash
	completion.bash
	env.bash
	functions.bash
	interactive.bash
	local.bash
)
tmux_layout_files=(
	dev-3cols.sh
	pick-repo.sh
)
nvim_files=(
	init.lua
	lazy-lock.json
	lua/lazy_setup.lua
	lua/plugins/astrocore.lua
	lua/plugins/astrolsp.lua
	lua/plugins/sessions.lua
	lua/polish.lua
)

# Restore manifests are normally generated only for managed destinations, but
# validate untrusted or hand-edited manifests against every local file and the
# private state tree. Ancestors are protected too, so a forged broad target
# cannot erase a local child.
protected_local_paths=(
	.config/extra
	.local/state/dotfiles
)

# A restore manifest is a journal of this installer's own exact destinations,
# not a general-purpose file operation format. This allowlist also prevents an
# apparently unrelated path from reaching a protected overlay through a
# symlink ancestor (for example, config-alias -> .config).
restore_allowed_paths=(
	.bash_profile
	.bashrc
	.curlrc
	.gdbinit
	.gitconfig
	.hushlogin
	.inputrc
	.tmux.conf
	.wgetrc
	.config/starship.toml
	# Keep older Linux Ghostty backups restorable.
	.config/ghostty/config.ghostty
	'Library/Application Support/com.mitchellh.ghostty/config.ghostty'
	.tmux/load-tpm.sh
	.tmux/plugins/tpm
	.local/share/nvim
	.config/dotfiles/shell
	.tmux/layouts
	.config/nvim
	.gitignore
)

same_content() {
	local source_path=$1 destination=$2
	local source_entry destination_entry relative

	if [[ -L $source_path || -L $destination ]]; then
		[[ -L $source_path && -L $destination ]] || return 1
		cmp -s <(readlink "$source_path") <(readlink "$destination")
	elif [[ -d $source_path || -d $destination ]]; then
		[[ -d $source_path && -d $destination ]] || return 1
		same_mode "$source_path" "$destination" || return 1

		# Compare links by their stored text instead of dereferencing them. This
		# also handles two identical dangling links, which `diff -r` does not.
		while IFS= read -r -d '' source_entry; do
			relative=${source_entry#"$source_path"/}
			destination_entry="$destination/$relative"
			if [[ -L $source_entry || -L $destination_entry ]]; then
				[[ -L $source_entry && -L $destination_entry ]] || return 1
				cmp -s <(readlink "$source_entry") \
					<(readlink "$destination_entry") || return 1
			elif [[ -d $source_entry || -d $destination_entry ]]; then
				[[ -d $source_entry && -d $destination_entry ]] || return 1
				same_mode "$source_entry" "$destination_entry" || return 1
			elif [[ -f $source_entry || -f $destination_entry ]]; then
				[[ -f $source_entry && -f $destination_entry ]] || return 1
				cmp -s "$source_entry" "$destination_entry" || return 1
				same_mode "$source_entry" "$destination_entry" || return 1
			else
				# Managed trees contain directories, regular files, and links.
				# Treat any special entry conservatively as different.
				return 1
			fi
		done < <(find "$source_path" -mindepth 1 -print0)

		# The first pass catches changed and missing destination entries; this
		# second pass catches entries that exist only in the destination tree.
		while IFS= read -r -d '' destination_entry; do
			relative=${destination_entry#"$destination"/}
			source_entry="$source_path/$relative"
			[[ -e $source_entry || -L $source_entry ]] || return 1
		done < <(find "$destination" -mindepth 1 -print0)
	elif [[ -f $source_path || -f $destination ]]; then
		[[ -f $source_path && -f $destination ]] || return 1
		cmp -s "$source_path" "$destination" && \
			same_mode "$source_path" "$destination"
	else
		return 1
	fi
}

path_mode() {
	local path=$1 mode
	mode=$(stat -c '%a' "$path" 2>/dev/null) || mode=$(stat -f '%Lp' "$path" 2>/dev/null) || return
	printf '%s\n' "$mode"
}

same_mode() {
	local source_mode destination_mode
	source_mode=$(path_mode "$1") || return 1
	destination_mode=$(path_mode "$2") || return 1
	[[ $source_mode == "$destination_mode" ]]
}

print_mode_difference() {
	local source_path=$1 destination=$2 display_path=$3
	local source_mode destination_mode

	[[ ! -L $source_path && ! -L $destination ]] || return 0
	if [[ -f $source_path && -f $destination ]] || \
		[[ -d $source_path && -d $destination ]]; then
		source_mode=$(path_mode "$source_path") || return
		destination_mode=$(path_mode "$destination") || return
		if [[ $source_mode != "$destination_mode" ]]; then
			printf 'Mode change for %s: %s -> %s\n' \
				"$display_path" "$destination_mode" "$source_mode"
		fi
	fi
}

print_tree_mode_differences() {
	local source_path=$1 destination=$2
	local source_entry destination_entry relative

	print_mode_difference "$source_path" "$destination" "$destination"
	while IFS= read -r -d '' source_entry; do
		relative=${source_entry#"$source_path"/}
		destination_entry="$destination/$relative"
		[[ -e $destination_entry || -L $destination_entry ]] || continue
		print_mode_difference "$source_entry" "$destination_entry" \
			"$destination_entry"
	done < <(find "$source_path" -mindepth 1 \( -type d -o -type f \) -print0)
}

ensure_diff_empty_directory() {
	if [[ -z ${scratch_root:-} ]]; then
		scratch_parent=$(CDPATH='' cd -- "${TMPDIR:-/tmp}" && pwd -P)
		scratch_root=$(mktemp -d "$scratch_parent/dotfiles-bootstrap.XXXXXX")
	fi
	diff_empty_directory="$scratch_root/diff-empty"
	mkdir -p "$diff_empty_directory"
}

format_content_diff() {
	if [[ $diff_color != true ]]; then
		cat
		return
	fi
	# Portable across GNU and BSD diff, including macOS's system tools.
	awk '
		BEGIN { reset = "\033[0m" }
		{
			color = ""
			if ($0 ~ /^(diff |--- |\+\+\+ )/) color = "\033[1m"
			else if ($0 ~ /^@@/) color = "\033[36m"
			else if ($0 ~ /^\+/) color = "\033[32m"
			else if ($0 ~ /^-/) color = "\033[31m"
			if (color != "") printf "%s%s%s\n", color, $0, reset
			else print
		}
	'
}

run_content_diff() {
	local statuses
	if diff "$@" | format_content_diff; then
		return 0
	else
		statuses=("${PIPESTATUS[@]}")
	fi
	(( statuses[1] == 0 )) || return "${statuses[1]}"
	# diff uses status 1 for an ordinary difference and values above 1 for an
	# operational error.
	(( statuses[0] == 1 )) || return "${statuses[0]}"
}

diff_is_external_tree() {
	case $1 in
		.tmux/plugins/tpm|.local/share/nvim) return 0 ;;
		*) return 1 ;;
	esac
}

print_addition_diff() {
	local source_path=$1
	if [[ -d $source_path && ! -L $source_path ]]; then
		ensure_diff_empty_directory
		run_content_diff -ruN "$diff_empty_directory" "$source_path"
	elif [[ -f $source_path && ! -L $source_path ]]; then
		run_content_diff -u /dev/null "$source_path"
	elif [[ -L $source_path ]]; then
		printf '+ symlink -> %s\n' "$(readlink "$source_path")"
	else
		printf '+ unsupported file type: %s\n' "$source_path"
	fi
}

print_removal_diff() {
	local destination=$1 relative=$2
	[[ $show_diff == true ]] || return 0
	if diff_is_external_tree "$relative"; then
		printf 'DIFF      skipped for external generated tree: %s\n' "$destination"
		return 0
	fi
	printf '\nDifference for %s (removal):\n' "$destination"
	if [[ -d $destination && ! -L $destination ]]; then
		ensure_diff_empty_directory
		run_content_diff -ruN "$destination" "$diff_empty_directory"
	elif [[ -f $destination && ! -L $destination ]]; then
		run_content_diff -u "$destination" /dev/null
	elif [[ -L $destination ]]; then
		printf -- '- symlink -> %s\n' "$(readlink "$destination")"
	else
		printf '%s\n' '(target is absent or has an unsupported file type)'
	fi
}

print_target_diff() {
	local source_path=$1 destination=$2 relative=$3
	[[ $show_diff == true ]] || return 0
	if diff_is_external_tree "$relative"; then
		printf 'DIFF      skipped for external generated tree: %s\n' "$destination"
		return 0
	fi
	printf '\nDifference for %s:\n' "$destination"
	if [[ ! -e $destination && ! -L $destination ]]; then
		print_addition_diff "$source_path"
	elif [[ -d $source_path && ! -L $source_path && \
		-d $destination && ! -L $destination ]]; then
		print_tree_mode_differences "$source_path" "$destination"
		run_content_diff -ruN "$destination" "$source_path"
	elif [[ -f $source_path && ! -L $source_path && \
		-f $destination && ! -L $destination ]]; then
		print_mode_difference "$source_path" "$destination" "$destination"
		run_content_diff -u "$destination" "$source_path"
	elif [[ -L $source_path && -L $destination ]]; then
		printf -- '- symlink -> %s\n' "$(readlink "$destination")"
		printf '+ symlink -> %s\n' "$(readlink "$source_path")"
	else
		printf 'Type change from %s to %s\n' "$destination" "$source_path"
		print_removal_diff "$destination" "$relative"
		print_addition_diff "$source_path"
	fi
}

install_target() {
	local source_path=$1 destination=$2 relative_destination=$3
	local backup_path="$backup_root/$relative_destination"
	local stage_path="${destination}.dotfiles-stage.$$"
	local action restore_payload=- source_mode

	validate_home_destination "$destination" "$relative_destination"
	if same_content "$source_path" "$destination"; then
		printf 'UNCHANGED %s\n' "$destination"
		return 0
	fi

	if [[ -e $destination || -L $destination ]]; then
		action=REPLACE
		restore_payload=$relative_destination
		printf 'REPLACE   %s (backup: %s)\n' "$destination" "$backup_path"
	else
		action=INSTALL
		printf 'INSTALL   %s\n' "$destination"
	fi
	print_target_diff "$source_path" "$destination" "$relative_destination"

	if [[ $mode == apply ]]; then
		ensure_home_parent_directories "$destination" "$relative_destination"
		if [[ -e $stage_path || -L $stage_path ]]; then
			printf 'Refusing to overwrite stale staging path: %s\n' "$stage_path" >&2
			return 1
		fi
		if [[ -d $source_path ]]; then
			if ! cp -Rp "$source_path" "$stage_path"; then
				rm -rf -- "$stage_path"
				return 1
			fi
		else
			if ! cp -p "$source_path" "$stage_path"; then
				rm -f -- "$stage_path"
				return 1
			fi
		fi

		if ! ensure_backup_root; then
			if [[ -d $stage_path && ! -L $stage_path ]]; then
				rm -rf -- "$stage_path"
			else
				rm -f -- "$stage_path"
			fi
			return 1
		fi
		if [[ $action == REPLACE ]]; then
			mkdir -p "${backup_path%/*}"
			if ! mv "$destination" "$backup_path"; then
				if [[ -d $stage_path && ! -L $stage_path ]]; then
					rm -rf -- "$stage_path"
				else
					rm -f -- "$stage_path"
				fi
				return 1
			fi
			if ! record_restore_action "$action" "$relative_destination" \
				"$restore_payload"; then
				if [[ ! -e $destination && ! -L $destination ]]; then
					mv "$backup_path" "$destination" 2>/dev/null || true
				else
					printf 'Original target remains at %s\n' "$backup_path" >&2
				fi
				if [[ -d $stage_path && ! -L $stage_path ]]; then
					rm -rf -- "$stage_path"
				else
					rm -f -- "$stage_path"
				fi
				return 1
			fi
		fi

		if [[ -d $stage_path && ! -L $stage_path ]]; then
			if ! mkdir "$destination" 2>/dev/null; then
				printf 'Managed target appeared during installation: %s\n' \
					"$destination" >&2
				rm -rf -- "$stage_path"
				return 1
			fi
			source_mode=$(path_mode "$stage_path") || return 1
			if ! chmod "$source_mode" "$destination"; then
				[[ $action == INSTALL ]] && rmdir "$destination" 2>/dev/null || true
				return 1
			fi
			if [[ $action == INSTALL ]] && \
				! record_restore_action INSTALL "$relative_destination" -; then
				rmdir "$destination" 2>/dev/null || true
				rm -rf -- "$stage_path"
				return 1
			fi
			if ! cp -Rp "$stage_path"/. "$destination"; then
				printf 'Directory copy failed; partial target is journalled: %s\n' \
					"$destination" >&2
				rm -rf -- "$stage_path"
				return 1
			fi
			rm -rf -- "$stage_path"
		else
			if ! ln "$stage_path" "$destination" 2>/dev/null; then
				printf 'Managed target appeared during installation: %s\n' \
					"$destination" >&2
				rm -f -- "$stage_path"
				return 1
			fi
			if [[ $action == INSTALL ]] && \
				! record_restore_action INSTALL "$relative_destination" -; then
				if [[ $destination -ef $stage_path ]]; then
					rm -f -- "$destination"
				fi
				rm -f -- "$stage_path"
				return 1
			fi
			rm -f -- "$stage_path"
		fi
	fi
}

ensure_backup_root() {
	[[ ${backup_ready:-false} == true ]] && return 0
	if [[ ! -e $backup_parent && ! -L $backup_parent ]]; then
		mkdir "$backup_parent"
	fi
	if [[ -L $backup_parent || ! -d $backup_parent ]]; then
		printf 'Backup path is not a normal directory: %s\n' \
			"$backup_parent" >&2
		return 1
	fi
	chmod 700 "$backup_parent"
	if ! mkdir "$backup_root"; then
		printf 'Refusing to reuse an existing backup root: %s\n' \
			"$backup_root" >&2
		return 1
	fi
	chmod 700 "$backup_root"
	printf '%s\n' 'dotfiles-restore-v1' >"$backup_root/restore.manifest"
	chmod 600 "$backup_root/restore.manifest"
	backup_ready=true
}

record_restore_action() {
	local action=$1 relative=$2 payload=$3
	printf '%s\t%s\t%s\n' "$action" "$relative" "$payload" \
		>>"$backup_root/restore.manifest"
}

install_tpm() {
	local existing_tpm

	if existing_tpm=$(find_tpm_path); then
		printf 'UNCHANGED %s (TPM)\n' "$existing_tpm"
		return 0
	fi
	if [[ -e $tpm_destination || -L $tpm_destination ]]; then
		printf 'Refusing to overwrite unusable TPM path: %s\n' \
			"$tpm_destination" >&2
		return 1
	fi

	printf 'INSTALL   %s (clone: %s, version: %s)\n' \
		"$tpm_destination" "$tpm_repository" "$tpm_version"
	[[ $mode == apply ]] || return 0

	validate_home_destination "$tpm_destination" '.tmux/plugins/tpm'
	ensure_home_parent_directories "$tpm_destination" '.tmux/plugins/tpm'
	ensure_backup_root
	if ! mkdir "$tpm_destination" 2>/dev/null; then
		printf 'TPM path appeared during installation: %s\n' \
			"$tpm_destination" >&2
		return 1
	fi
	if ! record_restore_action INSTALL '.tmux/plugins/tpm' -; then
		printf 'Could not record TPM installation; rolling back.\n' >&2
		rmdir "$tpm_destination" 2>/dev/null || true
		return 1
	fi
	if ! cp -Rp "$scratch_root/tpm"/. "$tpm_destination"; then
		printf 'TPM copy failed; the partial installation is journalled for restore: %s\n' \
			"$tpm_destination" >&2
		return 1
	fi
}

check_neovim_version() {
	local version_line parsed major minor

	if ! command -v nvim >/dev/null 2>&1; then
		printf '%s\n' 'AstroNvim installation requires Neovim 0.12.x' >&2
		return 1
	fi
	version_line=$(nvim --version 2>/dev/null | sed -n '1p') || return 1
	parsed=$(printf '%s\n' "$version_line" |
		sed -n 's/^NVIM v\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
	read -r major minor <<<"$parsed"
	if [[ ${major:-} != 0 || ${minor:-} != 12 ]]; then
		printf 'AstroNvim requires Neovim 0.12.x (found: %s)\n' \
			"${version_line:-unknown}" >&2
		return 1
	fi
}

check_git_version() {
	local version_line parsed major minor

	command -v git >/dev/null 2>&1 || return 1
	version_line=$(git --version 2>/dev/null | sed -n '1p') || return 1
	parsed=$(printf '%s\n' "$version_line" |
		sed -n 's/^git version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
	read -r major minor <<<"$parsed"
	[[ -n ${major:-} && -n ${minor:-} ]] || return 1
	(( major > 2 || ( major == 2 && minor >= 19 ) ))
}

run_bootstrap_git() (
	# Do not let a user's global Git configuration or command-scope overrides
	# weaken certificate verification for bootstrap's public HTTPS downloads.
	# The system configuration remains available for administrator-provided CA
	# paths and proxy settings.
	unset GIT_CONFIG_NOSYSTEM GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS
	unset GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL
	unset GIT_SSL_NO_VERIFY
	HOME="$bootstrap_git_home" \
		XDG_CONFIG_HOME="$bootstrap_git_xdg_config" \
		GIT_TERMINAL_PROMPT=0 \
		git "$@"
)

stage_astronvim() {
	local config_home="$scratch_root/astronvim-config"
	local data_home="$scratch_root/astronvim-data"
	local state_home="$scratch_root/astronvim-state"
	local cache_home="$scratch_root/astronvim-cache"
	local runtime_home="$scratch_root/astronvim-runtime"
	local config_dirs="$scratch_root/astronvim-config-dirs"
	local data_dirs="$scratch_root/astronvim-data-dirs"
	local work_dir="$scratch_root/astronvim-work"
	local stage_home="$scratch_root/astronvim-home"
	local install_log="$scratch_root/astronvim-install.log"
	local health_log="$scratch_root/astronvim-health.log"
	local health_marker="$scratch_root/astronvim-health.ok"
	local health_hook_command='lua local ok, message = xpcall(function() dofile(vim.env.DOTFILES_ASTRONVIM_HEALTH_SCRIPT) end, debug.traceback); if not ok then io.stderr:write("AstroNvim health hook failed:\n" .. tostring(message) .. "\n"); vim.cmd "cquit 1" end'
	local staged_data="$data_home/nvim"

	mkdir -p "$config_home" "$data_home" "$state_home" "$cache_home" \
		"$runtime_home" "$config_dirs" "$data_dirs" "$work_dir" "$stage_home"
	chmod 700 "$runtime_home" "$stage_home"
	cp -p "$bootstrap_git_config" "$stage_home/.gitconfig"
	cp -Rp "$scratch_root/nvim" "$config_home/nvim"

	run_staged_nvim() (
		unset VIMINIT EXINIT
		unset GIT_CONFIG_NOSYSTEM GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS
		unset GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL
		unset GIT_SSL_NO_VERIFY
		cd "$work_dir"
		HOME="$stage_home" \
			GIT_TERMINAL_PROMPT=0 \
			XDG_CONFIG_HOME="$config_home" \
			XDG_CONFIG_DIRS="$config_dirs" \
			XDG_DATA_HOME="$data_home" \
			XDG_DATA_DIRS="$data_dirs" \
			XDG_STATE_HOME="$state_home" \
			XDG_CACHE_HOME="$cache_home" \
			XDG_RUNTIME_DIR="$runtime_home" \
			NVIM_APPNAME=nvim \
			NVIM_LOG_FILE="$state_home/nvim.log" \
			DOTFILES_ASTRONVIM_HEALTH_SCRIPT="$scratch_root/astronvim-health.lua" \
			DOTFILES_ASTRONVIM_HEALTH_MARKER="$health_marker" \
			nvim "$@"
	)

	validate_staged_astronvim() {
		local special_entry

		if ! cmp -s "$scratch_root/nvim/lazy-lock.json" \
			"$config_home/nvim/lazy-lock.json"; then
			printf '%s\n' 'AstroNvim installation unexpectedly changed lazy-lock.json' >&2
			return 1
		fi
		if [[ ! -d $staged_data/lazy/lazy.nvim/lua/lazy || \
			! -d $staged_data/lazy/AstroNvim/lua/astronvim || \
			! -f $staged_data/lazy/AstroNvim/version.txt ]]; then
			printf '%s\n' \
				'AstroNvim installation did not produce a complete plugin tree' >&2
			return 1
		fi
		special_entry=$(find "$staged_data" ! -type d ! -type f ! -type l \
			-print) || return 1
		if [[ -n $special_entry ]]; then
			printf '%s\n' \
				'AstroNvim installation produced an unsupported special file' >&2
			return 1
		fi
		if ! validate_staged_symlinks "$staged_data"; then
			printf '%s\n' \
				'AstroNvim installation produced a symlink escaping its data tree' >&2
			return 1
		fi
	}

	printf '%s\n' 'STAGE     AstroNvim locked plugin set'
	if ! run_staged_nvim --headless -n -i NONE \
		'+Lazy! restore' +qa >"$install_log" 2>&1; then
		printf '%s\n' 'AstroNvim plugin installation failed:' >&2
		sed 's/^/  /' "$install_log" >&2
		return 1
	fi
	validate_staged_astronvim || return

	# A normal command-line Lua error can leave Neovim's process status at zero.
	# The pre-init health hook validates after VimEnter and writes a marker only
	# after the complete staged configuration has started successfully.
	if ! run_staged_nvim --headless -n -i NONE \
		--cmd "$health_hook_command" \
		>"$health_log" 2>&1; then
		printf '%s\n' 'AstroNvim startup validation failed:' >&2
		sed 's/^/  /' "$health_log" >&2
		return 1
	fi
	if [[ ! -f $health_marker ]] || \
		[[ $(<"$health_marker") != ok ]]; then
		printf '%s\n' 'AstroNvim startup validation did not complete' >&2
		return 1
	fi
	validate_staged_astronvim || return
	chmod 700 "$staged_data"
}

install_astronvim() {
	local backup_path="$backup_root/$astronvim_relative"
	local action=INSTALL restore_payload=-

	if [[ $astronvim_preinstall_supported != true ]]; then
		printf 'SKIP      AstroNvim preinstall (custom XDG or NVIM_APPNAME setting)\n'
		return 0
	fi
	if astronvim_is_installed; then
		printf 'UNCHANGED %s (AstroNvim)\n' \
			"$astronvim_detect_root/lazy/AstroNvim"
		return 0
	fi
	if ! astronvim_target_is_seedable; then
		printf 'SKIP      AstroNvim preinstall (preserving existing Neovim data: %s)\n' \
			"$astronvim_destination"
		return 0
	fi
	if [[ $astronvim_preinstall_unavailable == true ]]; then
		printf 'SKIP      AstroNvim preinstall (%s)\n' "$astronvim_skip_reason"
		return 0
	fi

	if [[ -e $astronvim_destination ]]; then
		action=REPLACE
		restore_payload=$astronvim_relative
		printf 'REPLACE   %s (AstroNvim; backup: %s)\n' \
			"$astronvim_destination" "$backup_path"
	else
		printf 'INSTALL   %s (AstroNvim)\n' "$astronvim_destination"
	fi
	[[ $mode == apply ]] || return 0

	if [[ ! -d $scratch_root/astronvim-data/nvim ]]; then
		printf '%s\n' 'Staged AstroNvim data is unavailable; re-run bootstrap' >&2
		return 1
	fi
	ensure_home_parent_directories "$astronvim_destination" \
		"$astronvim_relative"
	if ! astronvim_target_is_seedable; then
		printf 'SKIP      AstroNvim preinstall (Neovim data changed during staging)\n'
		return 0
	fi
	ensure_backup_root
	if [[ $action == REPLACE ]]; then
		# Revalidate immediately before taking the empty directory into backup.
		if ! directory_is_empty "$astronvim_destination"; then
			printf 'SKIP      AstroNvim preinstall (Neovim data became non-empty)\n'
			return 0
		fi
		mkdir -p "${backup_path%/*}"
		if ! mv "$astronvim_destination" "$backup_path"; then
			return 1
		fi
		if ! record_restore_action "$action" "$astronvim_relative" \
			"$restore_payload"; then
			if [[ ! -e $astronvim_destination && ! -L $astronvim_destination ]]; then
				mv "$backup_path" "$astronvim_destination" 2>/dev/null || true
			else
				printf 'Original Neovim data remains at %s\n' "$backup_path" >&2
			fi
			return 1
		fi
	fi
	if ! mkdir "$astronvim_destination" 2>/dev/null; then
		if [[ $action == INSTALL ]]; then
			printf 'SKIP      AstroNvim preinstall (Neovim data appeared during staging)\n'
			return 0
		fi
		printf 'Could not claim AstroNvim data path; restore is available in %s\n' \
			"$backup_root" >&2
		return 1
	fi
	if ! chmod 700 "$astronvim_destination"; then
		if [[ $action == INSTALL ]]; then
			rmdir "$astronvim_destination" 2>/dev/null || true
		fi
		return 1
	fi
	if [[ $action == INSTALL ]] && \
		! record_restore_action INSTALL "$astronvim_relative" -; then
		rmdir "$astronvim_destination" 2>/dev/null || true
		return 1
	fi
	if ! cp -Rp "$scratch_root/astronvim-data/nvim"/. \
		"$astronvim_destination"; then
		printf 'AstroNvim copy failed; the partial data is journalled for restore: %s\n' \
			"$astronvim_destination" >&2
		return 1
	fi
}

stage_tree() {
	local source_root=$1 staged_root=$2 file_mode=$3
	shift 3
	local relative source_path staged_path

	case $file_mode in
		644|755) ;;
		*)
			printf 'Unsupported managed-tree file mode: %s\n' "$file_mode" >&2
			return 1
			;;
	esac

	for relative in "$@"; do
		case $relative in
			/*|../*|*/../*|*/..)
				printf 'Unsafe managed-tree path: %s\n' "$relative" >&2
				return 1
				;;
		esac
		source_path="$source_root/$relative"
		if [[ ! -f $source_path ]]; then
			printf 'Managed-tree source is missing: %s\n' "$source_path" >&2
			return 1
		fi
		staged_path="$staged_root/$relative"
		mkdir -p "${staged_path%/*}"
		cp "$source_path" "$staged_path"
		chmod "$file_mode" "$staged_path"
	done

	# Directory modes should not depend on the invoking user's umask.
	find "$staged_root" -type d -exec chmod 755 {} +
}

manifest_file_mode() {
	case $1 in
		.tmux/load-tpm.sh) printf '%s\n' 755 ;;
		*) printf '%s\n' 644 ;;
	esac
}

stage_manifest() {
	local staged_root=$1
	local index=0 source_relative destination_relative
	local source_path staged_path file_mode

	while (( index < ${#manifest[@]} )); do
		source_relative=${manifest[index]}
		destination_relative=${manifest[index + 1]}
		source_path="$repo_dir/$source_relative"
		staged_path="$staged_root/$destination_relative"
		file_mode=$(manifest_file_mode "$destination_relative") || return
		mkdir -p "${staged_path%/*}"
		cp "$source_path" "$staged_path"
		chmod "$file_mode" "$staged_path"
		index=$((index + 2))
	done
	find "$staged_root" -type d -exec chmod 755 {} +
}

safe_relative_path() {
	case $1 in
		''|.|..|/*|../*|*/../*|*/..|./*|*/./*|*/.|*//*|*/ ) return 1 ;;
		*) return 0 ;;
	esac
}

directory_is_empty() {
	local path=$1 entry
	[[ -d $path && ! -L $path && -r $path && -x $path ]] || return 1
	for entry in "$path"/* "$path"/.[!.]* "$path"/..?*; do
		[[ -e $entry || -L $entry ]] && return 1
	done
	return 0
}

validate_home_destination() {
	local destination=$1 relative=$2 parent current component
	local -a components

	if ! safe_relative_path "$relative" || \
		[[ $destination != "$HOME/$relative" ]]; then
		printf 'Unsafe HOME destination: %s\n' "$destination" >&2
		return 1
	fi
	parent=${relative%/*}
	[[ $parent != "$relative" ]] || return 0
	IFS=/ read -r -a components <<<"$parent"
	current=$HOME
	for component in "${components[@]}"; do
		current="$current/$component"
		if [[ -L $current ]]; then
			printf 'Refusing symlink ancestor for managed path: %s\n' \
				"$current" >&2
			return 1
		fi
		if [[ -e $current && ! -d $current ]]; then
			printf 'Managed path ancestor is not a directory: %s\n' \
				"$current" >&2
			return 1
		fi
	done
}

ensure_home_parent_directories() {
	local destination=$1 relative=$2 parent current component
	local -a components

	validate_home_destination "$destination" "$relative"
	parent=${relative%/*}
	[[ $parent != "$relative" ]] || return 0
	IFS=/ read -r -a components <<<"$parent"
	current=$HOME
	for component in "${components[@]}"; do
		current="$current/$component"
		if [[ ! -e $current && ! -L $current ]]; then
			if ! mkdir "$current" 2>/dev/null && \
				[[ ! -d $current || -L $current ]]; then
				printf 'Could not create managed path ancestor: %s\n' \
					"$current" >&2
				return 1
			fi
		fi
		if [[ -L $current || ! -d $current ]]; then
			printf 'Managed path ancestor is not a normal directory: %s\n' \
				"$current" >&2
			return 1
		fi
	done
	validate_home_destination "$destination" "$relative"
}

relative_symlink_stays_in_tree() {
	local link_path=$1 tree_root=$2 stored relative base combined component
	local depth=0
	local -a components

	stored=$(readlink "$link_path") || return 1
	case $stored in
		''|/*) return 1 ;;
	esac
	relative=${link_path#"$tree_root"/}
	[[ $relative != "$link_path" ]] || return 1
	if [[ $relative == */* ]]; then
		base=${relative%/*}
	else
		base=
	fi
	combined=${base:+$base/}$stored
	IFS=/ read -r -a components <<<"$combined"
	for component in "${components[@]}"; do
		case $component in
			''|.) ;;
			..)
				(( depth > 0 )) || return 1
				depth=$((depth - 1))
				;;
			*) depth=$((depth + 1)) ;;
		esac
	done
}

validate_staged_symlinks() {
	local tree_root=$1 link_path
	while IFS= read -r -d '' link_path; do
		relative_symlink_stays_in_tree "$link_path" "$tree_root" || return 1
	done < <(find "$tree_root" -type l -print0)
}

ensure_restore_safety_root() {
	[[ ${restore_safety_ready:-false} == true ]] && return 0
	if [[ -L $restore_safety_parent || \
		( -e $restore_safety_parent && ! -d $restore_safety_parent ) ]]; then
		printf 'Restore safety path is not a normal directory: %s\n' \
			"$restore_safety_parent" >&2
		return 1
	fi
	if [[ ! -e $restore_safety_parent && ! -L $restore_safety_parent ]]; then
		mkdir "$restore_safety_parent"
	fi
	if [[ -L $restore_safety_parent || ! -d $restore_safety_parent ]]; then
		printf 'Restore safety path is not a normal directory: %s\n' \
			"$restore_safety_parent" >&2
		return 1
	fi
	chmod 700 "$restore_safety_parent"
	if ! mkdir "$restore_safety_root"; then
		printf 'Refusing to reuse an existing restore safety root: %s\n' \
			"$restore_safety_root" >&2
		return 1
	fi
	chmod 700 "$restore_safety_root"
	printf '%s\n' 'dotfiles-restore-v1' >"$restore_safety_root/restore.manifest"
	chmod 600 "$restore_safety_root/restore.manifest"
	restore_safety_ready=true
	printf 'Pre-restore safety backup: %s\n' "$restore_safety_root"
}

record_restore_safety_action() {
	local action=$1 relative=$2 payload=$3
	printf '%s\t%s\t%s\n' "$action" "$relative" "$payload" \
		>>"$restore_safety_root/restore.manifest"
}

restore_target() {
	local restore_root=$1 action=$2 relative=$3 payload=$4
	local destination="$HOME/$relative"
	local safety_path="$restore_safety_root/$relative"
	local stage_path="${destination}.dotfiles-restore-stage.$$"
	local source_path='' inverse_action=''

	validate_home_destination "$destination" "$relative"

	case $action in
		INSTALL)
			if [[ ! -e $destination && ! -L $destination ]]; then
				printf 'ABSENT    %s\n' "$destination"
				return 0
			fi
			print_removal_diff "$destination" "$relative"
			ensure_restore_safety_root
			mkdir -p "${safety_path%/*}"
			mv "$destination" "$safety_path"
			if ! record_restore_safety_action REPLACE "$relative" "$relative"; then
				mv "$safety_path" "$destination" || true
				return 1
			fi
			printf 'REMOVE    %s (saved: %s)\n' "$destination" "$safety_path"
			return 0
			;;
		REPLACE) source_path="$restore_root/$payload" ;;
		*)
			printf 'Unsupported restore action: %s\n' "$action" >&2
			return 1
			;;
	esac
	if same_content "$source_path" "$destination"; then
		printf 'UNCHANGED %s\n' "$destination"
		return 0
	fi
	print_target_diff "$source_path" "$destination" "$relative"

	ensure_home_parent_directories "$destination" "$relative"
	if [[ -e $stage_path || -L $stage_path ]]; then
		printf 'Refusing to overwrite stale restore staging path: %s\n' \
			"$stage_path" >&2
		return 1
	fi
	if ! cp -pPR "$source_path" "$stage_path"; then
		return 1
	fi

	ensure_restore_safety_root
	if [[ -e $destination || -L $destination ]]; then
		inverse_action=REPLACE
		mkdir -p "${safety_path%/*}"
		if ! mv "$destination" "$safety_path"; then
			mv "$stage_path" "${stage_path}.failed" 2>/dev/null || true
			return 1
		fi
	else
		inverse_action=INSTALL
	fi

	if ! mv "$stage_path" "$destination"; then
		[[ -e $safety_path || -L $safety_path ]] && \
			mv "$safety_path" "$destination"
		return 1
	fi

	if [[ $inverse_action == REPLACE ]]; then
		payload=$relative
	else
		payload=-
	fi
	if ! record_restore_safety_action "$inverse_action" "$relative" "$payload"; then
		printf 'Could not record restore safety action for %s; rolling back.\n' \
			"$destination" >&2
		if mv "$destination" "$stage_path"; then
			[[ -e $safety_path || -L $safety_path ]] && \
				mv "$safety_path" "$destination"
			printf 'Unrecorded restored copy retained at %s\n' "$stage_path" >&2
		fi
		return 1
	fi

	printf 'RESTORE   %s (from: %s)\n' "$destination" "$source_path"
}

restore_backup() {
	local requested=$1 restore_root manifest_file
	local allowed=false allowed_parent allowed_parent_real restore_parent_real
	local header action relative payload extra existing protected_path allowed_path
	local source_path source_parent index
	local restore_count=0 target_allowed
	local -a restore_actions=() restore_paths=() restore_payloads=()

	if [[ ! -d $requested || -L $requested ]]; then
		printf 'Restore source is not a normal directory: %s\n' "$requested" >&2
		return 1
	fi
	restore_root=$(CDPATH='' cd -- "$requested" && pwd -P) || return
	restore_parent_real=${restore_root%/*}
	for allowed_parent in "$backup_parent" "$restore_safety_parent"; do
		[[ -d $allowed_parent && ! -L $allowed_parent ]] || continue
		allowed_parent_real=$(CDPATH='' cd -- "$allowed_parent" && pwd -P) || continue
		if [[ $restore_parent_real == "$allowed_parent_real" ]]; then
			allowed=true
			break
		fi
	done
	if [[ $allowed != true ]]; then
		printf 'Restore source must be a direct child of %s or %s\n' \
			"$backup_parent" "$restore_safety_parent" >&2
		return 1
	fi

	manifest_file="$restore_root/restore.manifest"
	if [[ ! -f $manifest_file || -L $manifest_file || ! -r $manifest_file ]]; then
		printf 'Restore manifest is missing or unsafe: %s\n' "$manifest_file" >&2
		return 1
	fi

	{
		IFS= read -r header || {
			printf 'Restore manifest is empty: %s\n' "$manifest_file" >&2
			return 1
		}
		if [[ $header != dotfiles-restore-v1 ]]; then
			printf 'Unsupported restore manifest header: %s\n' "$header" >&2
			return 1
		fi

		while IFS=$'\t' read -r action relative payload extra || \
			[[ -n ${action}${relative}${payload}${extra} ]]; do
			if [[ -n $extra ]] || ! safe_relative_path "$relative"; then
				printf 'Unsafe restore manifest entry: %s %s\n' \
					"$action" "$relative" >&2
				return 1
			fi
			target_allowed=false
			for allowed_path in "${restore_allowed_paths[@]}"; do
				if [[ $relative == "$allowed_path" ]]; then
					target_allowed=true
					break
				fi
			done
			if [[ $target_allowed != true ]]; then
				printf 'Restore manifest target is not managed: %s\n' \
					"$relative" >&2
				return 1
			fi
			for protected_path in "${protected_local_paths[@]}"; do
				if [[ $relative == "$protected_path" || \
					$relative == "$protected_path/"* || \
					$protected_path == "$relative/"* ]]; then
					printf 'Restore manifest overlaps protected local path: %s\n' \
						"$relative" >&2
					return 1
				fi
			done
			validate_home_destination "$HOME/$relative" "$relative" || return 1
			case $action in
				INSTALL)
					if [[ $payload != - ]]; then
						printf 'INSTALL restore entry has a payload: %s\n' \
							"$relative" >&2
						return 1
					fi
					;;
				REPLACE)
					if ! safe_relative_path "$payload"; then
						printf 'Unsafe restore payload: %s\n' "$payload" >&2
						return 1
					fi
					source_path="$restore_root/$payload"
					;;
				*)
					printf 'Unknown restore manifest action: %s\n' "$action" >&2
					return 1
					;;
			esac
			if [[ $action != INSTALL && ! -e $source_path && ! -L $source_path ]]; then
				printf 'Restore payload is missing: %s\n' "$source_path" >&2
				return 1
			fi
			if [[ $action != INSTALL ]]; then
				source_parent=$(CDPATH='' cd -- "${source_path%/*}" && pwd -P) || \
					return 1
				case $source_parent in
					"$restore_root"|"$restore_root"/*) ;;
					*)
						printf 'Restore payload escapes its backup: %s\n' \
							"$source_path" >&2
						return 1
						;;
				esac
			fi
			# Bash before 4.4 treats "${empty_array[@]}" as unset under
			# `set -u`; macOS still ships Bash 3.2. The explicit count keeps
			# the empty array out of value expansions altogether.
			if (( restore_count > 0 )); then
				for existing in "${restore_paths[@]}"; do
					if [[ $existing == "$relative" || \
						$existing == "$relative/"* || \
						$relative == "$existing/"* ]]; then
						printf 'Duplicate or overlapping restore path: %s\n' \
							"$relative" >&2
						return 1
					fi
				done
			fi
			restore_actions[restore_count]=$action
			restore_paths[restore_count]=$relative
			restore_payloads[restore_count]=$payload
			restore_count=$((restore_count + 1))
		done
	} <"$manifest_file"

	if (( restore_count == 0 )); then
		printf 'Restore manifest contains no completed actions: %s\n' \
			"$manifest_file" >&2
		return 1
	fi

	printf 'Restore source: %s\nMode: %s\n' "$restore_root" "$mode"
	if [[ $mode == dry-run ]]; then
		for (( index=restore_count - 1; index >= 0; index-- )); do
			action=${restore_actions[index]}
			relative=${restore_paths[index]}
			payload=${restore_payloads[index]}
			case $action in
				INSTALL)
					if [[ -e $HOME/$relative || -L $HOME/$relative ]]; then
						printf 'REMOVE    %s (would save under: %s)\n' \
							"$HOME/$relative" "$restore_safety_root/$relative"
						print_removal_diff "$HOME/$relative" "$relative"
					else
						printf 'ABSENT    %s\n' "$HOME/$relative"
					fi
					;;
				REPLACE)
					if same_content "$restore_root/$payload" "$HOME/$relative"; then
						printf 'UNCHANGED %s\n' "$HOME/$relative"
					else
						printf 'RESTORE   %s (from: %s)\n' \
							"$HOME/$relative" "$restore_root/$payload"
						print_target_diff "$restore_root/$payload" \
							"$HOME/$relative" "$relative"
					fi
					;;
			esac
		done
		printf '\nRestore dry run only. Re-run with --restore "%s" --apply.\n' \
			"$restore_root"
		return 0
	fi

	umask 077
	acquire_operation_lock
	# Another completed apply may have used the initially selected timestamp
	# while this restore was being validated and waiting for the lock.
	select_restore_safety_root
	restore_safety_ready=false
	for (( index=restore_count - 1; index >= 0; index-- )); do
		restore_target "$restore_root" "${restore_actions[index]}" \
			"${restore_paths[index]}" "${restore_payloads[index]}"
	done
	printf '\nRestoration complete. Start a new Bash login shell to test it.\n'
	if [[ $restore_safety_ready == true ]]; then
		printf 'The pre-restore state is under %s\n' "$restore_safety_root"
		printf 'Undo preview: ./bootstrap.sh --restore "%s"\n' \
			"$restore_safety_root"
	else
		printf '%s\n' 'No installed targets needed changing; no safety backup was created.'
	fi
}

if [[ -n $restore_source ]]; then
	restore_backup "$restore_source"
	exit
fi

printf 'Platform: %s\nMode: %s\n' "$platform" "$mode"

tpm_existing_path=
tpm_install_required=false
if tpm_existing_path=$(find_tpm_path); then
	:
elif [[ -e $tpm_destination || -L $tpm_destination ]]; then
	printf 'Refusing to overwrite unusable TPM path: %s\n' \
		"$tpm_destination" >&2
	exit 1
else
	tpm_install_required=true
fi

astronvim_install_required=false
if [[ $astronvim_preinstall_supported == true ]] && \
	! astronvim_is_installed && astronvim_target_is_seedable; then
	astronvim_install_required=true
fi

# Validate every source before changing the first destination.
index=0
while (( index < ${#manifest[@]} )); do
	source_path="$repo_dir/${manifest[index]}"
	if [[ ! -f $source_path ]]; then
		printf 'Manifest source is missing: %s\n' "$source_path" >&2
		exit 1
	fi
	index=$((index + 2))
done
if [[ ! -f $repo_dir/astronvim-health.lua ]]; then
	printf 'AstroNvim health script is missing: %s\n' \
		"$repo_dir/astronvim-health.lua" >&2
	exit 1
fi

scratch_parent=$(CDPATH='' cd -- "${TMPDIR:-/tmp}" && pwd -P)
scratch_root=$(mktemp -d "$scratch_parent/dotfiles-bootstrap.XXXXXX")
bootstrap_git_home="$scratch_root/bootstrap-git-home"
bootstrap_git_xdg_config="$scratch_root/bootstrap-git-config"
bootstrap_git_config="$bootstrap_git_home/.gitconfig"
mkdir -p "$bootstrap_git_home" "$bootstrap_git_xdg_config"
chmod 700 "$bootstrap_git_home" "$bootstrap_git_xdg_config"
(
	umask 077
	printf '%s\n' '[http]' $'\tsslVerify = true' \
		>"$bootstrap_git_config"
)

stage_manifest "$scratch_root/manifest"
stage_tree "$repo_dir/shell" "$scratch_root/shell" 644 "${bash_files[@]}"
mkdir -p "$scratch_root/shell/platform"
cp "$repo_dir/macos/interactive.bash" \
	"$scratch_root/shell/platform/macos.bash"
cp "$repo_dir/linux/interactive.bash" \
	"$scratch_root/shell/platform/linux.bash"
chmod 644 "$scratch_root/shell/platform/macos.bash" \
	"$scratch_root/shell/platform/linux.bash"
chmod 755 "$scratch_root/shell/platform"
stage_tree "$repo_dir/.tmux/layouts" "$scratch_root/tmux-layouts" 755 \
	"${tmux_layout_files[@]}"
stage_tree "$repo_dir/.config/nvim" "$scratch_root/nvim" 644 \
	"${nvim_files[@]}"
cp "$repo_dir/astronvim-health.lua" "$scratch_root/astronvim-health.lua"
chmod 644 "$scratch_root/astronvim-health.lua"

setup_homebrew

if [[ $mode == apply && $tpm_install_required == true ]]; then
	if ! command -v git >/dev/null 2>&1; then
		printf 'TPM installation requires git: %s\n' "$tpm_repository" >&2
		exit 1
	fi
	if ! run_bootstrap_git clone --quiet --branch "$tpm_version" \
		--depth 1 -- "$tpm_repository" "$scratch_root/tpm"; then
		printf 'Could not clone TPM %s from %s\n' \
			"$tpm_version" "$tpm_repository" >&2
		exit 1
	fi
	if [[ ! -f $scratch_root/tpm/tpm || ! -x $scratch_root/tpm/tpm ]]; then
		printf 'Cloned TPM does not contain an executable tpm entrypoint\n' >&2
		exit 1
	fi
	if ! validate_staged_symlinks "$scratch_root/tpm"; then
		printf '%s\n' 'Cloned TPM contains a symlink escaping its repository tree' >&2
		exit 1
	fi
fi

if [[ $mode == apply && $astronvim_install_required == true ]]; then
	if ! command -v nvim >/dev/null 2>&1; then
		astronvim_preinstall_unavailable=true
		astronvim_skip_reason='Neovim is not installed'
	elif ! check_neovim_version 2>/dev/null; then
		astronvim_preinstall_unavailable=true
		astronvim_skip_reason='Neovim 0.12.x is unavailable'
	elif ! check_git_version; then
		astronvim_preinstall_unavailable=true
		astronvim_skip_reason='Git 2.19 or newer is unavailable'
	else
		stage_astronvim
	fi
fi

if [[ $mode == apply ]]; then
	# Backups may contain identities, tokens, or other machine-local values.
	# Keep every newly created directory private.
	umask 077
	backup_parent="$HOME/.local/state/dotfiles/backups"
	if [[ -L $backup_parent || ( -e $backup_parent && ! -d $backup_parent ) ]]; then
		printf 'Backup path is not a normal directory: %s\n' "$backup_parent" >&2
		exit 1
	fi
	acquire_operation_lock
	# Select again inside the apply lock so the root is still unused when its
	# manifest is created.
	select_backup_root
	printf 'Backup root: %s\n' "$backup_root"
	backup_ready=false
fi

if [[ $tpm_install_required == true ]]; then
	install_tpm
else
	printf 'UNCHANGED %s (TPM)\n' "$tpm_existing_path"
fi

install_astronvim

install_target "$scratch_root/shell" \
	"$HOME/.config/dotfiles/shell" '.config/dotfiles/shell'

index=0
while (( index < ${#manifest[@]} )); do
	destination_rel=${manifest[index + 1]}
	source_path="$scratch_root/manifest/$destination_rel"
	destination="$HOME/$destination_rel"

	install_target "$source_path" "$destination" "$destination_rel"
	index=$((index + 2))
done

install_target "$scratch_root/tmux-layouts" \
	"$HOME/.tmux/layouts" '.tmux/layouts'
install_target "$scratch_root/nvim" \
	"$HOME/.config/nvim" '.config/nvim'

if [[ $mode == dry-run ]]; then
	printf '\nDry run only. Re-run with --apply to install this plan.\n'
else
	printf '\nInstallation complete. Run exec bash -l to load the dotfiles and activate Homebrew.\n'
	if [[ ${backup_ready:-false} == true ]]; then
		printf 'Restore backup: %s\n' "$backup_root"
		printf 'Restore preview: ./bootstrap.sh --restore "%s"\n' "$backup_root"
	else
		printf '%s\n' 'No managed targets changed; no restore backup was created.'
	fi
fi

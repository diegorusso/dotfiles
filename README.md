# Diego's cross-platform dotfiles

One Bash-based command-line environment for:

- Raspberry Pi OS and other Debian-family Linux hosts
- work and personal macOS machines, on Intel or Apple Silicon
- Linux development VMs

Shared behavior is kept portable. macOS and Linux commands are loaded only on
their matching platform, while employer-, role-, and machine-specific values
stay in the untracked `~/.config/extra` file.

This repository descends from Mathias Bynens' dotfiles and retains the original
MIT license and attribution in the Git history. Its installation and active
configuration are now specific to this fork.

## Layout

```text
.bash_profile, .bashrc       small Bash entrypoints
shell/                       shared environment and interactive Bash layers
.config/starship.toml        shared Catppuccin Powerline prompt
.config/ghostty/             saved Ghostty terminal settings
.gitconfig, .gitignore       shared Git configuration and global ignore rules
.tmux.conf, .tmux/           portable tmux configuration and layouts
.config/nvim/                complete AstroNvim user configuration
astronvim-health.lua         bootstrap-only AstroNvim startup validator
Brewfile, brew.sh            shared Homebrew CLI packages and bundle helper
macos/                       macOS Homebrew additions, Bash settings, and defaults
linux/                       Linux Bash, system packages, and brew prerequisites
bootstrap.sh                 Homebrew setup and explicit dotfile installer
check.sh                     local static and isolated integration validation
```

## Install or update dotfiles

Clone this fork wherever you keep source repositories:

```bash
git clone git@github.com:diegorusso/dotfiles.git
cd dotfiles
```

Preview the complete installation plan. This is the default and makes no
persistent or home-directory changes:

```bash
./bootstrap.sh
```

Add `-d` (or `--diff`) to include content and permission-mode differences for
changed managed dotfiles while keeping the selected mode unchanged:

```bash
./bootstrap.sh --diff
./bootstrap.sh --apply --diff
```

Restore previews and applies accept the same flag. TPM and AstroNvim plugin
data are summarized rather than dumped as recursive diffs; keeping dry runs
offline means their upstream content is not fetched just to display a diff.

After reviewing it, install Homebrew if needed and the tracked files:

```bash
./bootstrap.sh --apply
```

Bootstrap reuses Homebrew found on `PATH`, under `HOMEBREW_PREFIX`, or in the
standard macOS/Linux locations. If it is missing, apply downloads and runs the
[official Homebrew installer](https://docs.brew.sh/Installation), then loads
`brew shellenv bash` for subsequent bootstrap steps. The installer can request
sudo access and install Apple's Command Line Tools on macOS. Run bootstrap as
your regular user. For unattended installation, use `NONINTERACTIVE=1`; any
required sudo access must already be available.

Homebrew setup happens before the dotfiles are replaced. A download,
installation, or activation failure stops bootstrap. Dry runs only report
whether Homebrew would be installed; they do not download or run it. Brewfile
packages remain a separate step. After bootstrap, start a new Bash login shell
to activate Homebrew automatically:

```bash
exec bash -l
```

Then run `./brew.sh --apply` to install the packages.

Changed targets are moved to a timestamped directory under
`~/.local/state/dotfiles/backups/` before replacement. The installer uses an
explicit manifest and never:

- runs `git pull`;
- copies files outside the explicit file and managed-tree manifests;
- installs Brewfile packages or runs APT;
- changes the login shell;
- runs macOS defaults;
- creates, overwrites, backs up, or restores `~/.config/extra`.

Tracked configuration files are installed with explicit modes rather than
inheriting the checkout's umask: regular files use `0644`, executable helper
scripts use `0755`, and managed configuration directories use `0755`. Private
backup and state directories remain `0700`.

Every applied dotfile change is recorded in a versioned manifest in the backup printed
by bootstrap. Preview a restoration first, then apply it explicitly:

```bash
./bootstrap.sh --restore "$HOME/.local/state/dotfiles/backups/TIMESTAMP"
./bootstrap.sh --restore "$HOME/.local/state/dotfiles/backups/TIMESTAMP" --apply
```

Homebrew and its installer-created files are outside this restore manifest.
Restore neither installs nor removes Homebrew, and does not require it to work.

Restore validates the complete manifest before changing anything and processes
its actions in reverse. The selected backup is never consumed. The current
installed state is moved into a new private directory under
`~/.local/state/dotfiles/restore-safety/`, with its own manifest and an undo
command. Its path is printed before the first managed target changes, then the
undo command is repeated at completion so a partially completed restore can be
inspected and its journalled actions undone. A forced termination in the narrow
window between moving one target and recording that action can leave the item
physically retained but requiring manual recovery from the printed safety
directory. Concurrent apply operations are rejected using an empty
`~/.local/state/dotfiles/bootstrap.lock` directory. If a forced termination
leaves that lock behind, verify no bootstrap process is active before removing
it with `rmdir`. Keep the original shell or SSH session open until a restored
login shell has been tested.

## Bash layers and local settings

The supported interactive shell is Bash 3.2 or newer. Login shells preserve an
existing `~/.profile` and then load the shared environment; aliases, completion,
Starship, and platform helpers are initialized only when the shell is
interactive. `.profile` is never managed or replaced by bootstrap. Homebrew's
richer Bash completion requires Bash 4.2 or newer and is skipped on macOS's
older system Bash.
Bootstrap does not replace macOS's default zsh automatically; select Bash in
the terminal profile or change the login shell manually only where local work
policy permits it.

The shared loader selects `macos/interactive.bash` or
`linux/interactive.bash` from `uname`; bootstrap assembles the platform layers
under `~/.config/dotfiles/shell`. This keeps Finder, `defaults`, and `pbcopy`
behavior off Linux, and Linux networking/desktop assumptions off the Macs.

Use `~/.config/extra` as the single general Bash override for settings that
differ by machine, role, or employer:

```bash
# ~/.config/extra
export WORKSPACE_ROOT="$HOME/work"
alias work='cd "$WORKSPACE_ROOT"'

# Work identity for Git processes started from this shell environment.
export GIT_AUTHOR_EMAIL='work-address@example.com'
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# Optional work-only tmux layouts for prefix + P and prefix + S.
export DOTFILES_TMUX_P_REPO="$HOME/repos/cpython"
export DOTFILES_TMUX_S_REPO="$HOME/repos/ci-scripts"
```

The loader sources this file exactly once and after the shared defaults, so it
can override environment values, aliases, functions, or any other shell
setting. It is loaded by interactive shells and by non-interactive login
shells, but not by ordinary non-interactive command shells. Bootstrap never
creates, replaces, backs up, or restores it. Keep it at mode `0600` if it
contains employer settings, credentials, or secrets.

The shared Starship configuration is the
[Catppuccin Powerline preset](https://starship.rs/presets/catppuccin-powerline),
tracked at `.config/starship.toml` and installed explicitly. Its Powerline and
development symbols require a Nerd Font in the terminal displaying the session.
The macOS package profile installs Hack Nerd Font; for SSH into Linux or the Pi,
configure the font in the client terminal. A desktop Linux VM needs a suitable
font installed and selected locally.

## Git configuration

The tracked Git defaults use `Diego Russo <me@diegor.it>` on every machine. On
a work machine, override the author and committer email from
`~/.config/extra`:

```bash
export GIT_AUTHOR_EMAIL='work-address@example.com'
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
```

These variables affect Git and other programs only when they inherit that shell
environment. A GUI application, editor, service, or automation process started
elsewhere will continue to use the tracked email. They override the effective
identity used for new commits; they do not change `git config user.email`. Git
does not parse `~/.config/extra` itself: Bash sources the file and exports the
variables. Verify the effective values before committing:

```bash
git var GIT_AUTHOR_IDENT
git var GIT_COMMITTER_IDENT
```

All compatibility settings live directly in the shared `.gitconfig`; there is
no generated platform include or separate machine-local Git configuration.
The root `.gitignore` is used by this repository and installed as
`~/.gitignore` for global use. Repository-specific patterns remain in each
repository's own `.gitignore`.

GitHub and Gist use SSH consistently so authentication comes from each
machine's SSH keys or forwarded agent:

- `gh:owner/repository`, `github:owner/repository`, `gst:id`, and `gist:id`
  expand to SSH URLs.
- Existing `https://` and `git://` GitHub or Gist remotes are transparently
  rewritten to SSH.

## Packages

Homebrew manages shared CLI tools on macOS, Ubuntu, and Raspberry Pi OS. The
root `Brewfile` contains Neovim, Starship, and the other shared tools.
Linux uses APT for Bash, bash-completion, curl, Eternal Terminal (`et`), Git,
Git LFS, htop, Python, tmux, and wget; these are listed in `linux/packages.txt`.
`macos/Brewfile` supplies their Homebrew equivalents on macOS, along with
GUI/font casks and Colima/Docker. Linux uses only the root Brewfile.

On Linux, Eternal Terminal's server and systemd unit stay together in the
system package. The packaged unit starts `/usr/bin/etserver` directly and does
not depend on the Homebrew activation in your Bash dotfiles.

`./bootstrap.sh --apply` installs Homebrew when it is missing, using the
official installer's standard prefix (`/home/linuxbrew/.linuxbrew` on Linux).
The shared `shell/env.bash` discovers this location as well as the macOS
prefixes and runs `brew shellenv bash` automatically for Bash login and
interactive shells. After installation, run `exec bash -l` in an existing
terminal to load it; future terminals load it on startup. Use a 64-bit OS on
the Raspberry Pi for ARM64 binary packages.

Before the first bootstrap on Debian, Ubuntu, or Raspberry Pi OS, ensure that
Homebrew's prerequisites are installed. `linux/packages.txt` contains these and
Linux system tools. Review it against the host's configured repositories before
installing. For `et`, follow the
[upstream package instructions](https://github.com/MisterTea/EternalTerminal#installation):
Ubuntu uses the project's PPA, while Debian has a separate upstream repository.
Check `apt-cache policy et` for a candidate matching the host's release and
architecture. If no suitable package is published, including for Raspberry Pi
OS on Trixie, use upstream's
[Debian/Ubuntu package build instructions](https://github.com/MisterTea/EternalTerminal#debianubuntu)
to install a local `.deb` first. Bootstrap does not configure APT repositories.

Once the package sources are ready:

```bash
grep -Ev '^[[:space:]]*(#|$)' linux/packages.txt |
  xargs sudo apt install
```

System curl and Git are needed to install Homebrew. Keeping them, Bash, and
Python under APT avoids requesting a second copy in the Linux Brewfile.
Homebrew can still install its own versions as dependencies of other formulas;
it generally uses its own libraries on Linux. See
[Homebrew on Linux](https://docs.brew.sh/Homebrew-on-Linux). Changing the
manifests does not remove packages already installed by either package manager.

Once Homebrew is available, use the same commands on every machine:

```bash
./brew.sh
./brew.sh --apply
```

The default dry run checks installed dependencies and reports missing ones,
returning a nonzero status when a bundle is incomplete. Apply installs the
shared bundle first and, on macOS, the macOS additions. The old
`./macos/brew.sh` command delegates to this helper.

On Debian-family Linux, both modes report existing commands outside Homebrew,
including system copies later in `PATH`. The check resolves symlinks and asks
`dpkg-query` which installed package owns each executable; it does not assume
that formula, command, and APT package names match. For optional duplicates it
prints `sudo apt-get --simulate remove -- ...`, followed by the corresponding
removal command to use only after testing the Homebrew replacements and
reviewing APT's complete removal list. Neither command is run automatically.

Essential/protected packages, the system shell and Python, Eternal Terminal's
remote-access package, and packages retained in `linux/packages.txt` are
reported with a reason to keep them. Commands with unknown or ambiguous dpkg
ownership receive no APT removal suggestion. macOS skips this APT-specific check.

Homebrew installation is part of bootstrap; Brewfile package provisioning
remains separate. `brew.sh` requires Homebrew on `PATH` and uses
`HOMEBREW_NO_AUTO_UPDATE=1` and `--no-upgrade`. Homebrew may still upgrade a
dependency when required to install a selected formula. The helper does not
start services or change the login shell.

A Brewfile selects packages, not exact versions. This configuration requires
Neovim **0.12.x** on every machine. Check `command -v nvim` and `nvim --version`
after installing the Homebrew formula. Once Homebrew's Neovim is on 0.12.x,
use `brew pin neovim` to prevent routine upgrades from changing the version.
The pin applies to the installed version on that machine; it does not select
0.12 for a fresh installation. Before an intentional upgrade, check
`brew info neovim` and keep the selected release within 0.12.x. Existing APT
installations can remain while the shell selects Homebrew's binaries. See
[Homebrew's pin command](https://docs.brew.sh/Manpage#pin---formula---cask-installed_formulainstalled_cask-)
and
[Homebrew Bundle's version policy](https://docs.brew.sh/Brew-Bundle-and-Brewfile#versions).

## Ghostty

The saved configuration lives in `.config/ghostty/config.ghostty`. Bootstrap
installs it to `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`
on macOS and `~/.config/ghostty/config.ghostty` on Linux, using the usual backup
and restore workflow. These are Ghostty's
[standard configuration locations](https://ghostty.org/docs/config#file-location).

Edit the repository copy, then use `./bootstrap.sh --diff` to preview changes
and `./bootstrap.sh --apply` to install them. If you edit settings through
Ghostty instead, copy the installed file back into the repository to save them.
Bootstrap copies files; it does not keep them linked or synchronize edits back.

## tmux

The configuration targets tmux 3.2 or newer. The generic repository picker is
bound to `prefix` + `R`. It looks beneath
`~/repos` by default, checks for `fzf`, and uses only shell behavior available on
both macOS and Linux.

On `--apply`, bootstrap detects
[TPM](https://github.com/tmux-plugins/tpm) in explicit `TMUX_TPM_PATH` and
`TMUX_PLUGIN_MANAGER_PATH` overrides, its standard user and XDG locations, and
common Homebrew, Linuxbrew, and Linux package locations. If it is absent,
bootstrap stages and validates a clone of the official repository before
installing the pinned v3.1.0 release at `~/.tmux/plugins/tpm`; dry runs never
access the network. Bootstrap requires the TPM entrypoint to be a regular
executable and does not update or replace an existing installation. Press
`prefix` + `I` inside tmux once to install the configured tmux-resurrect and
tmux-continuum plugins.

The work-only `prefix` + `P` and `prefix` + `S` layouts are enabled when their
repository paths are exported from `~/.config/extra`:

```bash
export DOTFILES_TMUX_P_REPO="$HOME/repos/cpython"
export DOTFILES_TMUX_S_REPO="$HOME/repos/ci-scripts"
```

A new tmux server inherits these values automatically. Restarting an existing
server is the safest way to apply them when it is safe to end all sessions. To
keep the server running, execute the following from a client attached to the
session whose environment should provide the bindings, then reload the shared
config. These assignments are deliberately session-scoped; do not add `-g`:

```bash
tmux set-environment DOTFILES_TMUX_P_REPO "$DOTFILES_TMUX_P_REPO"
tmux set-environment DOTFILES_TMUX_S_REPO "$DOTFILES_TMUX_S_REPO"
tmux source-file "$HOME/.tmux.conf"
```

## Neovim

The tracked `.config/nvim` is a complete
[AstroNvim v5.3.15](https://github.com/AstroNvim/AstroNvim/releases/tag/v5.3.15)
user configuration for **Neovim 0.12.x** on macOS, Ubuntu, and Raspberry Pi OS.
It uses the same plugin revisions and settings on every machine. Bootstrap
backs up the whole existing Neovim configuration before replacing it.

Aerial is pinned to 3.1.0 for Neovim 0.12's Tree-sitter API, and all active plugins
use the single `lazy-lock.json`. Plugins used only by older Neovim versions are
removed from the lock file. LSP callbacks use the 0.12 API directly. Older
version fallbacks and the 0.13 development-version workaround are removed;
startup reports a clear error outside the 0.12 release series. The configuration
is validated with Neovim 0.12.5.

When AstroNvim is absent and the standard `~/.local/share/nvim` data location
is absent or empty, `--apply` runs the tracked configuration in isolated
temporary XDG directories and asks Lazy to restore the revisions in
`lazy-lock.json`. Bootstrap then starts the complete configuration through
`VimEnter` and verifies every locked plugin
directory and Git revision before installing the data tree. These downloads
use a private temporary Git home with certificate verification enabled, so
unsafe user-global Git settings are
not inherited. An empty standard Neovim data directory is backed up and
replaced as one reversible target. A non-empty, linked, or otherwise
non-standard data target is preserved, and an existing AstroNvim installation
is never updated or replaced. Dry runs remain offline. A new preinstall
requires Neovim 0.12.x and Git 2.19 or newer; if either is unavailable,
bootstrap still installs the tracked configuration and reports that the plugin
preinstall was skipped.

Custom `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, or `NVIM_APPNAME` namespaces remain
outside bootstrap's restore manifest, so their plugin preinstall is skipped. A
custom data home with the standard `nvim` config namespace will bootstrap on
the first `nvim` launch. Custom config homes or application names need their
own locally managed config; this repository continues to install only
`~/.config/nvim`. Runtime state and caches remain under the normal XDG
state/cache directories and are not managed by bootstrap.

## macOS defaults

The previous large defaults archive mixed current preferences, retired
applications, hardware-specific power settings, and privileged commands. The
replacement contains a small set of reviewed user preferences and defaults to a
dry run:

```bash
./macos/defaults.sh
./macos/defaults.sh --apply
```

Applying first exports the preference domains affected by the shared script
under `~/.local/state/dotfiles/macos-defaults/`. The shared script contains no
`sudo`, power, Bluetooth, firewall, or system-policy changes.

## Validate

Run the local checks before installing or committing:

```bash
./check.sh
```

This checks Bash syntax, Git configuration parsing, package manifest shape,
Homebrew installation/reuse and bundle selection on Linux and macOS, Linux command
ownership and APT removal suggestions, Neovim Lua and lock-file syntax, Starship
configuration parsing, isolated Linux
and macOS bootstrap installation/idempotence, reversible restore and validation
guards, `~/.config/extra` preservation and startup behavior, permission repair,
simulated macOS-defaults backup behavior, whitespace, and ShellCheck when it is
available.

## License

MIT. See [LICENSE-MIT.txt](LICENSE-MIT.txt).

# Diego's cross-platform dotfiles

Shared command-line configuration with Bash on Linux/macOS and native
PowerShell on Windows, for:

- Raspberry Pi OS and other Debian-family Linux hosts
- work and personal macOS machines, on Intel or Apple Silicon
- Linux development VMs
- work and personal Windows machines

Shared behavior is kept portable. macOS and Linux commands are loaded only on
their matching platform, while employer-, role-, and machine-specific values
stay in the untracked `~/.config/extra` file for Bash or
`~/.config/extra.ps1` for PowerShell.

This repository descends from Mathias Bynens' dotfiles and retains the original
MIT license and attribution in the Git history. Its installation and active
configuration are now specific to this fork.

## Layout

```text
.bash_profile, .bashrc       small Bash entrypoints
shell/                       shared environment and interactive Bash layers
.config/starship.toml        shared Catppuccin Powerline prompt
.config/ghostty/             macOS-only Ghostty terminal settings
.gitconfig, .gitignore       shared Git configuration and global ignore rules
.tmux.conf, .tmux/           portable tmux configuration and layouts
.config/zellij/             Zellij layout, repository picker, and device colours
.config/nvim/                complete AstroNvim user configuration
astronvim-health.lua         bootstrap-only AstroNvim startup validator
Brewfile, brew.sh            shared Homebrew CLI packages and bundle helper
macos/                       macOS Homebrew additions, Bash settings, and defaults
linux/                       Linux Bash, system packages, and brew prerequisites
windows/                     native PowerShell, Terminal, WinGet packages, and checks
bootstrap.sh                 Homebrew setup and explicit dotfile installer
bootstrap.ps1                native Windows dotfile installer and restore helper
check.sh                     local static and isolated integration validation
```

## Native Windows

Windows uses PowerShell 7, Windows Terminal, and WinGet. Git, the Catppuccin
Starship prompt, and the complete Neovim configuration share the repository
sources used by Linux and macOS. Windows has its own shell functions and package
profiles. PSMux provides native sessions and the repository/worktree workflow
inside Windows Terminal.

Clone this repository using Git for Windows, then open PowerShell in the checkout.
The package helper also works in the built-in Windows PowerShell 5.1, allowing
it to install PowerShell 7 on a new machine:

```powershell
.\windows\packages.ps1
.\windows\packages.ps1 -Apply
```

Preview only prints commands and stays offline. Apply installs the core WinGet
list in `windows/packages.json`, then installs the standalone Tree-sitter CLI
**0.26.13** from its [official release](https://github.com/tree-sitter/tree-sitter/releases/tag/v0.26.13),
verifying the published SHA-256 digest. The helper selects the ARM64, x64, or x86
binary for the host and retains an existing standalone CLI at 0.26.1 or newer.
The executable lives under `%LOCALAPPDATA%\dotfiles\bin`; the PowerShell layer
adds that directory to `PATH`. Zig supplies a native C compiler for Neovim
parsers; the shell sets `CC=zig cc` and `CXX=zig c++` when these values are unset.
Unversioned WinGet packages use `--no-upgrade`; Neovim explicitly
selects **0.12.5** to satisfy this repository's **0.12.x** requirement. An older
Neovim is upgraded by this step. PSMux explicitly selects **3.3.8**; older
versions lack the command-format support needed by the workspace bindings.
Before upgrading PSMux, the helper checks for running processes from its WinGet
installation. Save your pane work and run `tmux kill-server` from a separate
PowerShell terminal if it asks you to stop PSMux, then retry. Detaching leaves
the servers running, and a hidden standby server can also lock `tmux.exe`.
The helper also provisions Python **3.13** through uv, without changing the
system's Python registration or adding executable links. Workspace launches
use that runtime offline, without project environments or Python dependencies.
Package installation may request elevation through its individual installers.

Optional application profiles add to the core tools:

```powershell
.\windows\packages.ps1 -Profile Work
.\windows\packages.ps1 -Profile Work -Apply
.\windows\packages.ps1 -Profile Personal -Apply
```

Work adds 1Password, Discord, and 7-Zip. Personal adds these plus PowerToys,
Telegram, VLC, and NordVPN. Review the selected list against your employer's
Windows policies before applying it.

Open a new **PowerShell 7** session after package installation, then preview
and apply the dotfiles:

```powershell
.\bootstrap.ps1
.\bootstrap.ps1 -Diff
.\bootstrap.ps1 -Apply
```

Bootstrap installs:

| Configuration | Windows destination |
| --- | --- |
| Git defaults and ignores | `~/.gitconfig`, `~/.gitignore` |
| Shared Starship prompt | `~/.config/starship.toml` |
| PowerShell entrypoint | `$PROFILE.CurrentUserAllHosts` |
| Native shell layer | `~/.config/dotfiles/windows/interactive.ps1` |
| Native PSMux configuration | `~/.psmux.conf` |
| Shared workspace helper | `~/.tmux/layouts/workspace.py` |
| PowerShell workspace entrypoint and agent navigation | `~/.config/dotfiles/windows/workspace/` |
| Shared Neovim configuration | `%LOCALAPPDATA%\nvim` |
| Terminal profile and colours | `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\dotfiles\terminal.json` |

The profile destination comes from PowerShell itself, including redirected
Documents folders. Host-specific PowerShell profiles still run afterward.
The [Terminal fragment](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions)
adds **Dotfiles PowerShell** and its Catppuccin Mocha scheme. Select that profile
as your default in Terminal Settings > Startup. Install **Hack Nerd Font Mono**
from the [official Nerd Fonts downloads](https://www.nerdfonts.com/font-downloads)
to display Starship's symbols correctly. Terminal reads this font from the
fragment when opening the profile.

Bootstrap copies managed files and the Neovim tree, backing up changed targets
under `%LOCALAPPDATA%\dotfiles\backups\TIMESTAMP-ID`. It prints the backup path
and undo command before replacing targets. Preview and repeated applies make
no backup when there are no changes. Restore validates its complete manifest
before applying changes and saves the current state in a new backup, which
can itself be restored:

```powershell
.\bootstrap.ps1 -Restore "$env:LOCALAPPDATA\dotfiles\backups\TIMESTAMP-ID"
.\bootstrap.ps1 -Restore "$env:LOCALAPPDATA\dotfiles\backups\TIMESTAMP-ID" -Apply
```

The optional `-Diff` flag works for restore too. Symlinks, junctions, and
other reparse points that can redirect writes are rejected in managed paths;
OneDrive cloud placeholders are supported. Concurrent applies use
an exclusive file lock, released automatically when the process exits. A forced
termination between moving an original into the backup and recording it in
`restore.json` may require recovering that item manually from `saved` in the
printed backup. Packages and Neovim runtime/plugin data are outside the restore
manifest. Neovim downloads its locked plugins on first launch; an existing plugin
installation can be aligned with `nvim --headless '+Lazy! restore' +qa`.
Custom `XDG_CONFIG_HOME` or `NVIM_APPNAME` configuration namespaces are skipped.

Open a new PowerShell session to activate changes. The shell sets up Starship,
PSReadLine history search and completion, `g`/`vi`/`vim`, `..`/`...`, `mkd`,
`open`, clipboard alias `c`, and a `repos` directory picker using fzf.
Machine-specific settings are sourced last from `~/.config/extra.ps1`:

```powershell
# ~/.config/extra.ps1, created and maintained locally
$env:WORKSPACE_ROOT = Join-Path $HOME 'work'
$env:GIT_AUTHOR_EMAIL = 'work-address@example.com'
$env:GIT_COMMITTER_EMAIL = $env:GIT_AUTHOR_EMAIL
```

The Git identity overrides apply to processes started from that PowerShell
session. Verify them with `git var GIT_AUTHOR_IDENT` and
`git var GIT_COMMITTER_IDENT`. Bootstrap preserves both local override files.

If PowerShell prevents local scripts from running, inspect `Get-ExecutionPolicy
-List` and use an execution policy permitted by your machine's administrator.
Bootstrap does not change execution policy.

Run the native validation from PowerShell 7:

```powershell
.\windows\check.ps1
```

It checks syntax and JSON, offline previews, installation and repeated applies,
restore and its undo, local override preservation, redirected profile paths,
custom editor namespaces, junction rejection, and package selection/failures.
The checks use temporary folders and command doubles for package installers.

### Windows workspaces

After applying packages and dotfiles, open a new PowerShell 7 terminal and run
`psmux new-session -s dev` (or `psmux attach -t dev` to return to that session).
For an already running session, load the installed configuration with
`psmux -t 'dev:' source-file "$HOME/.psmux.conf"`, replacing `dev` with its name.
In existing PowerShell panes, run `. $PROFILE.CurrentUserAllHosts` to load the
updated shell functions; new panes load them automatically.
PSMux loads `~/.psmux.conf`; use **Ctrl+B**, then:

| Key | Action |
| --- | --- |
| `R` | Pick a repository or registered Git worktree; reuse its Neovim / shell / Codex window |
| `T` | Open/reuse the checkout's test shell, without running tests automatically |
| `M` | Open/reuse a native process monitor |
| `L` | Open/reuse the checkout's registered log viewer |
| `A` | Pick a running agent, preview its pane, and jump to it |
| `B` | Toggle the native agent sidebar, preserving the previous pane layout |
| `P` / `S` | Open the optional checkouts configured below |
| `r` | Reload `~/.psmux.conf` |

The shared helper refreshes checkout/branch labels and keeps each worktree's
development, test and log windows separate. From a PSMux PowerShell pane,
`tdev` opens the current checkout, and `tdev 'C:\repos\project'` opens another.
The picker uses `WORKSPACE_ROOT` or `~/repos`; `@repo-root` overrides it.
New development windows start Neovim and Codex after PowerShell loads its
profiles, in the selected checkout. Codex uses `codex resume --last || codex`.
Existing windows are reused without restarting their tools; in an existing
blank agent pane, run that command once. Set `@dev-editor-command` or
`@dev-assistant-command` to a PowerShell command to customize startup (`none`
disables it).
Optional per-machine settings belong in `~/.config/extra.ps1`:

```powershell
$env:WORKSPACE_ROOT = Join-Path $HOME 'repos'
$env:DOTFILES_DEVICE = 'work-windows'
$env:DOTFILES_COLOUR = 'blue' # green, blue, purple, or orange
$env:DOTFILES_TMUX_P_REPO = Join-Path $HOME 'repos/project-one'
$env:DOTFILES_TMUX_S_REPO = Join-Path $HOME 'repos/project-two'
```

Register a log file with `tlogs 'C:\repos\project\runner.log'` from its checkout
pane. The viewer follows appends and rotation; `L` returns to it, and Ctrl+C
returns to its shell. Windows uses explicit registration because Unix's
Ralphex discovery depends on `lsof`. Register the next run's file again if it
changes. Logs remain scoped to the checkout and PSMux server.

The native agent picker/sidebar detects Codex, Claude, OpenCode, Gemini,
Copilot and aider processes descended from PSMux panes. It reports **running**;
ccmux's hook-derived busy/approval state and conversation-aware Resurrect
integration remain specific to the Unix setup. In the sidebar, `j`/`k` select,
Enter jumps, and `q` closes that sidebar. Closing with `B`, `q`, or pane-close
restores the saved pane sizes when the working panes are unchanged. New windows
also receive sidebars while enabled. Detach with Ctrl+B then `d` to keep live
processes running; no Windows save/restore plugin is installed.

Run the real native workspace checks after provisioning:

```powershell
uv run --offline --no-project --python 3.13 -m unittest discover -s tests/tmux -p test_native_windows.py -v
```

These use temporary repositories and a unique PSMux namespace, without starting
agents or modifying live sessions. Set `PSMUX_TEST_EXE` to a portable PSMux
executable to test a newer build without upgrading your installed copy.

## Install or update Linux and macOS dotfiles

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

Diffs use green for additions, red for removals, and cyan for hunk headers when
output goes to a terminal. Redirected or piped output stays plain; set
`NO_COLOR=1` to disable colour in a terminal as well.

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
Git LFS, htop, jq, lsof, Python, tmux, and wget; these are listed in `linux/packages.txt`.
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
shared bundle first and, on macOS, the core `macos/Brewfile`. With no profile
option, only those core packages are checked or installed. Add the appropriate
application bundle explicitly:

```bash
./brew.sh --work --apply
./brew.sh --personal --apply
```

The work profile adds only 1Password, Discord, Fastmail, Hack Nerd Font,
Ghostty, Obsidian, Rectangle, WhatsApp, and The Unarchiver. The personal profile adds the
full personal GUI/font application list. `--work` and `--personal` are mutually
exclusive. The old `./macos/brew.sh` command delegates to this helper.

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
remains separate. `brew.sh` requires Homebrew on `PATH`. Both modes first run
Homebrew's lightweight automatic update so that a newly installed macOS release
is recognised, then use `HOMEBREW_NO_AUTO_UPDATE=1` and `--no-upgrade` while
checking or installing the bundles. Dry runs can therefore update Homebrew's
own code and metadata and may perform Homebrew migrations required by a new
macOS version, but do not install missing Brewfile packages. Homebrew may still
upgrade a dependency during apply mode when required to install a selected
formula. The helper does not start services or change the login shell.

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

The macOS-only configuration lives in `.config/ghostty/config.ghostty`.
On macOS, bootstrap installs it to
`~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`, using the
usual backup and restore workflow. Linux bootstrap skips Ghostty.

Edit the repository copy, then use `./bootstrap.sh --diff` to preview changes
and `./bootstrap.sh --apply` to install them. If you edit settings through
Ghostty instead, copy the installed file back into the repository to save them.
Bootstrap copies files; it does not keep them linked or synchronize edits back.

Use **left Option** for terminal Alt shortcuts. `macos-option-as-alt = left`
keeps right Option available for typing special characters. Ghostty's default
Option+Left/Right word-jump bindings are unbound so Zellij receives the actual
Alt+arrow keys; Cmd+Option+Left/Right still switches Ghostty tabs. See
[Ghostty's Option setting](https://ghostty.org/docs/config/reference#macos-option-as-alt)
and its [Zellij arrow-key guidance](https://github.com/ghostty-org/ghostty/discussions/3207).
Reload the configuration with **Cmd+Shift+,** after applying these settings.

Ghostty advertises `TERM=xterm-256color` for compatibility with standard
macOS and Linux terminal databases. SSH and Eternal Terminal connections
started from a fresh Ghostty shell therefore do not require Ghostty's own
terminal definition on each receiving host. This favours compatibility over
Ghostty-specific capabilities such as styled underlines; see the
[Ghostty terminfo documentation](https://ghostty.org/docs/help/terminfo).

After applying the configuration, reload Ghostty's configuration and open a
new tab or window. Existing shells retain their previous `TERM`. Other
terminal apps keep their own terminal settings; the shared shell files do not
override `TERM` globally.

Inside tmux, `TERM=tmux-256color` describes tmux's virtual terminal rather than
the app connected to it. When connecting onwards from a tmux pane to an older
host without that entry, use `TERM=screen-256color ssh HOST` or
`TERM=screen-256color et HOST` for that connection. Minimal hosts still need a
terminal database providing the selected standard entry.

If your remote startup command ends with `tmux new -A -s ai; exit`, use
`tmux new -A -s ai && exit` so a failed attachment leaves the shell open.

tmux disables terminal passthrough by default. Applications that send terminal
identification queries through passthrough can leave replies such as
`>|ghostty 1.3.1` in the active pane as input. tmux still handles its own
terminal negotiation and clipboard support; features that depend on direct
passthrough, such as some inline graphics protocols, are unavailable. See the
[upstream explanation](https://github.com/tmux/tmux/issues/5530).

## Zellij

Install packages with `./brew.sh --apply` and configuration with
`./bootstrap.sh --apply`. From a fresh shell outside an existing multiplexer,
change to a checkout and run:

```bash
zj                         # Create or reattach to this machine's session.
zj --session development   # New named session.
zj attach development      # Attach to an existing session.
```

Plain `zj` uses the short hostname (`hostname -s`) as the session name, so each
machine reuses its own session. The hostname appears in Zellij's top bar and
the terminal title. Detach with **Ctrl+O, then d**; running `zj` again returns to
the same panes and processes. If the session has stopped, plain `zj` resurrects
it and automatically runs all saved pane commands, including Neovim and Codex,
without the "Press Enter" prompt. This applies to any saved command, so detach
when you want processes to keep running. Explicit arguments keep their usual
behaviour.

The initial layout has three equal columns, left to right: Neovim (`nvim`), a
shell, and one Codex pane running `codex resume --last`. The shell starts focused.
Codex selects the latest interactive conversation in the current directory,
using its normal settings and permissions. On exit or failure, Neovim and Codex
leave an ordinary shell in their pane; neither command automatically loops after exit.
If Codex cannot find a conversation to resume, start `codex` from that shell.
Ordinary new panes and tabs are shells. New panes inherit the focused pane's
current directory, including after `cd` into a subdirectory.

`zj` selects the accent from the existing `DOTFILES_COLOUR` export in
`~/.config/extra`: `blue` (work Mac), `green` (Linux VM), `purple` (personal Mac),
or `orange` (RPi5). Unset or unknown values use green. Bars have dark backgrounds
tinted to the device colour, with bright matching text and coloured mode labels.
The selected tab has a brighter background than inactive tabs. Full pane borders
highlight the focused pane in the device colour. Direct `zellij` launches use the
same layout and shortcuts with the default green accent.

Zellij's default shortcuts are inherited from the installed version. Enter a
mode to see its shortcut hints in the bottom bar; press Esc or Enter to return
to normal mode. **Ctrl+B, then Shift+R** opens the repo picker; **Ctrl+B, then ?**
opens floating shortcut help. In the help pane, use `/` to search and `q` to close.
From a Bash prompt inside Zellij, `zrepo` opens the same picker.
Use **Ctrl+G** to lock/unlock Zellij's shortcuts when Neovim or another program
needs those keys.

| Shortcut | Action |
| --- | --- |
| Ctrl+B, then `R` | Repository/worktree picker; switch to its existing tab or open a new three-pane tab |
| Ctrl+B, then `M` | Open/reuse the `monitor` tab: htop, kernel logs, and a shell |
| Ctrl+B, then `?` | Floating shortcut reference; `q` closes it and `/` searches |
| Ctrl+P, then `r` / `d` | Split right / down, inheriting the focused pane's directory |
| Ctrl+P, then arrows or `h/j/k/l` | Focus a pane; Esc returns to normal mode |
| Ctrl+P, then `f` / `x` | Zoom / close the pane (Zellij closes without a confirmation prompt) |
| Ctrl+T, then `n` / `r` / `1`…`9` | New shell tab / rename tab / select a tab |
| Ctrl+T, then `x` | Close the tab and all its panes without confirmation |
| Ctrl+N | Resize mode |
| Ctrl+S | Scroll mode; `s` starts a search |
| Ctrl+O, then `w` / `d` | Session manager / detach |

The help pane shows the custom bindings above the installed Zellij defaults.
The defaults are also available with `zellij setup --dump-config | less`.

The picker searches `~/repos` and Git's registered worktrees, including
worktrees outside that directory. Set `DOTFILES_REPO_ROOT` in `~/.config/extra`
for another repository parent. Selecting an open checkout switches to its tab,
using pane directories so renamed tabs and repository subdirectories still
match. Separate worktrees keep separate tabs. A checkout without an open tab
gets a new tab with one Codex pane; plain splits and new shell tabs never start
another agent.

**Ctrl+B, then Shift+M** opens a `monitor` tab: `htop` fills the left half,
with kernel logs above an empty shell in the right half. Repeating the shortcut
returns to the tab named `monitor`. The log pane starts focused so you can enter
your sudo password if prompted. Linux follows the kernel log with `sudo dmesg -wH`;
macOS uses `sudo log stream --style compact --predicate 'process == "kernel"'`.
Stopping either command leaves a shell in its pane, without restarting it.

Inside Zellij, Bash starts one background Ralphex watcher per session. Every
five seconds it checks running Ralphex processes and their open output logs.
If the repository is already open in a pane, it adds a floating `:logs` pane
to that tab, preferring a tab for the runner's exact worktree when available.
It starts hidden so your keyboard focus and tiled layout stay intact. Press
**Alt+F** or **Ctrl+P, then w** to show/hide floating panes in the tab.
The viewer follows new output, rotated logs, and subsequent runs without
starting another agent. Closing the pane keeps it closed for that run,
including after the watcher restarts. Ctrl+C leaves a shell; a later run can
open a fresh viewer without interrupting that shell.
The watcher uses Python 3 and `lsof`, and shares detection and streaming code
with the installed tmux helper without requiring a tmux server. Its state and
diagnostic log live under `${XDG_STATE_HOME:-~/.local/state}/dotfiles-zellij`.

Existing sessions retain their layouts. Use a new session to try this setup.
Run `./tests/check-zellij.sh` for disposable integration checks with fake Neovim
and Codex commands; the tests do not start a real conversation. The picker uses
Bash 3.2+, Git, fzf, jq, and Zellij directly; it does not require Python or tmux.

## tmux

The Unix configuration targets tmux 3.2 or newer on macOS and Linux, with Python
3.9+, Git and fzf. Keep using the existing session and pane shortcuts; each
checkout has reusable `dev`, `logs` and `tests` windows. The development layout
is still Neovim / shell / Codex in three equal columns. Native Windows uses
PSMux and the [Windows workspace entrypoints](#windows-workspaces).

| Shortcut (after Ctrl+B) | Action |
| --- | --- |
| `R` | Pick a repository or any registered Git worktree, including those outside `~/repos` |
| `M` | Open/reuse the system monitor (`htop`, falling back to `top`) |
| `L` | Open/reuse Ralphex logs for this exact checkout |
| `T` | Open/reuse a shell for this checkout's test commands |
| `A` | Open the ccmux agent picker with live status and pane preview |
| `B` | Toggle ccmux's optional sidebar |
| `r` | Reload the installed tmux configuration |
| `Ctrl+S` / `Ctrl+R` | Save / restore through tmux-resurrect |

The picker starts beneath `~/repos` (`@repo-root` changes that root) and lists
Git's registered worktrees, with checkout and branch labels. Branch labels in
window names and pane borders refresh automatically. Reopening a checkout
reuses its existing development window even after Resurrect loses custom tmux
options. Two repositories with the same folder name remain separate.

A single background watcher discovers Ralphex processes and their open output
logs. If that repository is already open, it adds a `:logs` window for the
runner's exact worktree without moving your focus or starting another agent.
The log follows appends, rotation and subsequent runs. Finished logs remain
visible. Ctrl+C stops the viewer for that run; `L` explicitly restarts it. If
you close a log window, it stays closed until the next run. `T` opens a shell;
it does not infer or execute a repository's test suite.

Install packages with `./brew.sh --apply` and dotfiles with
`./bootstrap.sh --apply`. Once per host, configure Codex status tracking:

```bash
ccmux setup --agent codex
```

[ccmux](https://github.com/epilande/ccmux) tracks agents on that host. Newly
started Codex sessions load its hooks; review/trust the hooks if Codex asks.
Existing agents remain running and can appear through process detection, but
need their next launch for authoritative conversation matching. The default
is the popup; the sidebar is optional and consumes pane width. Use `B` to toggle
it with layout preservation: closing it with `B`, `q`, or tmux's pane-close
shortcut restores each window's previous pane sizes. New windows opened while
the sidebar is enabled are covered too. If working panes were added or removed
while it was open, their changed layout is preserved. Calling
`ccmux sidebar --toggle` directly bypasses the initial layout snapshot.
Notifications retain ccmux's default off setting.

Resurrect's save hook records `codex resume <conversation-id>` for each
identified Codex pane, with its checkout path. If the ID cannot be verified,
restore opens Codex's resume picker instead of choosing a conversation. Normal
new development windows retain `codex resume --last || codex`, scoped by Codex
to that checkout. Neovim's existing Resession plugin restores its saved editor
session from the checkout directory. This restores saved conversations and
editor sessions; it does not checkpoint an in-flight agent turn, unsaved
buffers, or a running test process. Detaching tmux keeps live processes intact.

Run `./tests/check-tmux.sh` for the focused isolated-server checks. Helper state
lives under `${XDG_STATE_HOME:-~/.local/state}/dotfiles-tmux` and is not tracked.
To customize launches without editing a helper, set `@dev-editor-command`,
`@dev-assistant-command` or `@monitor-command` in tmux (`none` disables a tool).

Personalise tmux on each device using the local `~/.config/extra` file:

```bash
export DOTFILES_DEVICE="LINUX-VM"  # Optional; defaults to the short hostname.
export DOTFILES_COLOUR="green"
```

Suggested settings for the four devices:

| Device | `DOTFILES_DEVICE` | `DOTFILES_COLOUR` |
| --- | --- | --- |
| Work Mac | `WORK-MAC` | `blue` |
| Linux VM | `LINUX-VM` | `green` |
| Personal Mac | `PERSONAL-MAC` | `purple` |
| Raspberry Pi 5 | `RPI5` | `orange` |

The label appears beside the session name in the status bar and in the terminal
window/tab title where supported. The status bar, active window, and active pane
border share the chosen accent. With no label, tmux uses its host's short
hostname; an unset or unknown colour defaults to green. Colours use a consistent
256-colour palette. These settings describe the machine running tmux, including
when you connect to it over SSH or mosh.

New sessions and attachments inherit these values from the connecting shell.
After editing `~/.config/extra`, apply them to an already attached session with:

```bash
source "$HOME/.config/extra"
tmux set-environment DOTFILES_DEVICE "${DOTFILES_DEVICE:-}"
tmux set-environment DOTFILES_COLOUR "${DOTFILES_COLOUR:-}"
tmux source-file "$HOME/.tmux.conf"
```

tmux refreshes the session's `PATH` from the shell when you create or attach to
a session, so the picker can find Homebrew's `fzf`. After changing your shell's
`PATH` while already attached, update the running session and reload the config:

```bash
tmux set-environment PATH "$PATH"
tmux source-file "$HOME/.tmux.conf"
```

On `--apply`, bootstrap detects
[TPM](https://github.com/tmux-plugins/tpm) in explicit `TMUX_TPM_PATH` and
`TMUX_PLUGIN_MANAGER_PATH` overrides, its standard user and XDG locations, and
common Homebrew, Linuxbrew, and Linux package locations. If it is absent,
bootstrap stages and validates a clone of the official repository before
installing the pinned v3.1.0 release at `~/.tmux/plugins/tpm`; dry runs never
access the network. Bootstrap requires the TPM entrypoint to be a regular
executable and does not update or replace an existing installation.

When tmux starts or its configuration is reloaded, the loader uses TPM to
install missing configured plugins before loading them. Existing plugins are
left at their installed versions; no update or network access is needed when
all plugins are present. The first startup needs GitHub access. If installation
fails, tmux still starts with the available plugins and retries on the next
configuration reload or server startup. You can also press `prefix` + `I` to
retry manually. Bootstrap previews only discover TPM and never install plugins.

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

In interactive Bash shells, `vi` and `vim` are aliases for `nvim`.

The tracked `.config/nvim` is a complete
[AstroNvim v6.1.0](https://github.com/AstroNvim/AstroNvim/releases/tag/v6.1.0)
user configuration for **Neovim 0.12.x** on macOS, Ubuntu, and Raspberry Pi OS.
It uses the same plugin revisions and settings on every machine. Bootstrap
backs up the whole existing Neovim configuration before replacing it.

AstroNvim supplies the Neovim 0.12-compatible Tree-sitter and Aerial defaults;
there is no local Tree-sitter compatibility patch. AstroCore handles parser
installation, highlighting, indentation, and textobject mappings. AstroLSP
uses `vim.lsp.config` and manages native code lenses. Your clangd options,
disabled format on save, diagnostics preferences, and directory sessions are
preserved. All active plugins use the single `lazy-lock.json`; plugins removed
by AstroNvim 6 are removed from the lock. Startup reports a clear error outside
the Neovim 0.12 release series.

The shared Brewfile includes `tree-sitter-cli`, which is required to compile
downloaded parsers. Use version 0.26.1 or newer, with a C compiler, `curl`, and
`tar` available. Linux's `build-essential` package and macOS's Command Line
Tools provide the compiler. Check `tree-sitter --version`; an old npm wrapper
earlier on `PATH` can shadow the Homebrew binary (`command -v tree-sitter`).

To upgrade an existing v5 installation, quit Neovim and run from this checkout:

```bash
brew install tree-sitter-cli
./bootstrap.sh --apply
nvim --headless '+Lazy! restore' +qa
```

Then reopen Neovim. Lazy restores the locked v6 plugins; AstroCore automatically
downloads missing language parsers. Let the first parser installations finish
before opening code files. The default parsers are Bash, C, Lua, Markdown,
Markdown inline, Python, Query, Vim, and Vimdoc. Additional supported languages
are installed when their files are opened. The upgrade preserves existing
sessions and plugin data; it does not require deleting Neovim directories.

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
configuration parsing, isolated Zellij and tmux sessions, isolated Linux
and macOS bootstrap installation/idempotence, reversible restore and validation
guards, `~/.config/extra` preservation and startup behavior, permission repair,
simulated macOS-defaults backup behavior, whitespace, and ShellCheck when it is
available.

After installing the locked v6 plugins and default parsers and opening a code
file once to finish completion setup, run the full editor regression with:

```bash
DOTFILES_NVIM_TEST_DATA="$HOME/.local/share/nvim" ./check.sh
```

This copies the plugins, parsers, and Mason registry into temporary XDG
directories, verifies their locked revisions, and tests full startup, Markdown
code fences and edits, Lua textobject movement, LSP preferences, and directory
session restore. A temporary test overlay disables background Mason registry
refreshes. The installed environment remains
untouched. Without `DOTFILES_NVIM_TEST_DATA`,
the runtime integration is reported as skipped.

## License

MIT. See [LICENSE-MIT.txt](LICENSE-MIT.txt).

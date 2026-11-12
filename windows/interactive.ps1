$env:STARSHIP_CONFIG = Join-Path $HOME '.config/starship.toml'
$env:EDITOR = 'nvim'
$env:VISUAL = 'nvim'

# WinGet's portable command links may be missing from an existing session PATH.
if ($env:LOCALAPPDATA) {
    foreach ($dotfilesWindowsBin in @('dotfiles/bin', 'Microsoft/WinGet/Links')) {
        $dotfilesWindowsLinks = Join-Path $env:LOCALAPPDATA $dotfilesWindowsBin
        if ((Test-Path -LiteralPath $dotfilesWindowsLinks -PathType Container) -and
            $dotfilesWindowsLinks -notin ($env:PATH -split ';')) {
            if ($dotfilesWindowsBin -eq 'dotfiles/bin') {
                $env:PATH = "$dotfilesWindowsLinks;$env:PATH"
            } else {
                $env:PATH += ";$dotfilesWindowsLinks"
            }
        }
    }
    Remove-Variable dotfilesWindowsLinks, dotfilesWindowsBin
}

if (-not $env:CC -and (Get-Command zig -ErrorAction SilentlyContinue)) { $env:CC = 'zig cc' }
if (-not $env:CXX -and (Get-Command zig -ErrorAction SilentlyContinue)) { $env:CXX = 'zig c++' }

Set-Alias g git
Set-Alias vi nvim
Set-Alias vim nvim
Set-Alias c Set-Clipboard

function .. { Set-Location .. }
function ... { Set-Location ../.. }
function .... { Set-Location ../../.. }
function l { Get-ChildItem @args }
function la { Get-ChildItem -Force @args }

function mkd {
    param([Parameter(Mandatory)][string]$Path)
    [IO.Directory]::CreateDirectory($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)) | Out-Null
    Set-Location -LiteralPath $Path
}

function open {
    param([string]$Path = '.')
    Invoke-Item -LiteralPath $Path
}

function repos {
    $root = if ($env:WORKSPACE_ROOT) { $env:WORKSPACE_ROOT } else { Join-Path $HOME 'repos' }
    if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
        Set-Location -LiteralPath $root
        return
    }
    $selected = Get-ChildItem -LiteralPath $root -Directory | Select-Object -ExpandProperty FullName | fzf
    if ($selected) { Set-Location -LiteralPath $selected }
}

function tdev {
    param([string]$Path = (Get-Location).Path)
    & (Join-Path $HOME '.config/dotfiles/windows/workspace/workspace.ps1') dev $Path
}

function tlogs {
    param([string]$Log)
    & (Join-Path $HOME '.config/dotfiles/windows/workspace/workspace.ps1') logs -Log $Log
}

function zj {
    $colour = if ($env:DOTFILES_COLOUR -in @('green', 'blue', 'purple', 'orange')) { $env:DOTFILES_COLOUR } else { 'green' }
    $colour = $colour.ToLowerInvariant()
    $env:DOTFILES_ZELLIJ_SHELL = Join-Path $PSHOME 'pwsh.exe'
    $passthrough = @('options', 'setup', 'web', 'action', 'ac', 'list-sessions', 'ls', 'list-aliases', 'la',
                     'watch', 'w', 'kill-session', 'k', 'delete-session', 'd', 'kill-all-sessions', 'ka',
                     'delete-all-sessions', 'da', 'run', 'r', 'plugin', 'p', 'edit', 'e', 'pipe', 'subscribe',
                     'help', '--version', '-V', '--help', '-h')
    $valueOptions = @('--max-panes', '--data-dir', '-s', '--session', '-l', '--layout', '--layout-string',
                      '-n', '--new-session-with-layout', '-c', '--config', '--config-dir')
    $command = $null
    for ($i = 0; $i -lt $args.Count; $i++) {
        if ($args[$i] -in $valueOptions) { $i++; continue }
        if ($args[$i] -like '-*') { continue }
        $command = $args[$i]
        break
    }
    if ($command -in $passthrough -or @($args | Where-Object { $_ -in @('--version', '-V', '--help', '-h') }).Count) {
        & zellij @args
        return
    }
    $launchArguments = if ($args.Count) { @($args) } else { @('attach', '--create', '--force-run-commands', [Environment]::MachineName) }
    $session = if (-not $args.Count) { [Environment]::MachineName }
               elseif ($args[0] -in @('attach', 'a')) { @($args | Select-Object -Skip 1 | Where-Object { $_ -notlike '-*' }) | Select-Object -First 1 }
               elseif ($args[0] -in @('--session', '-s')) { $args[1] }
    if ($session) { & (Join-Path $HOME '.config/dotfiles/windows/zellij/workspace.ps1') prepare-resurrection $session }
    & zellij @launchArguments options --theme "dotfiles-$colour" --default-shell $env:DOTFILES_ZELLIJ_SHELL
}

function zrepo {
    & (Join-Path $HOME '.config/dotfiles/windows/zellij/workspace.ps1') pick
}

# Capture runs automatically; resolve the executable directly inside the helper,
# bypassing this function. Native programs invoked elsewhere remain untouched.
function ralphex {
    & (Join-Path $HOME '.config/dotfiles/windows/zellij/workspace.ps1') run-ralphex @args
}

# PSReadLine is loaded by interactive console hosts, including Windows Terminal.
# Prompt and line editor setup is limited to hosts with PSReadLine loaded.
if (Get-Module PSReadLine) {
    Set-PSReadLineOption -EditMode Emacs -BellStyle None
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
    if ((Get-Module PSReadLine).Version -ge [version]'2.1') {
        Set-PSReadLineOption -PredictionSource History
    }
    if (Get-Command starship -ErrorAction SilentlyContinue) {
        Invoke-Expression (& starship init powershell)
    }
}

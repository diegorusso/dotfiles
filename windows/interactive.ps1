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

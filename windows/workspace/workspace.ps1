#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('pick', 'dev', 'tests', 'logs', 'monitor', 'watch', 'refresh', 'agents', 'sidebar', 'sidebar-add', 'sidebar-save', 'sidebar-restore', 'shortcut')]
    [string]$Action = 'pick',
    [string]$Argument,
    [string]$Log,
    [string]$WorkspaceScript = (Join-Path $HOME '.tmux/layouts/workspace.py')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'Use the Bash tmux entrypoints on macOS and Linux.' }
foreach ($dependency in @('psmux', 'uv', 'git')) {
    if (-not (Get-Command $dependency -ErrorAction SilentlyContinue)) { throw "Workspace requires $dependency. Run windows/packages.ps1 -Apply." }
}
$muxArguments = if ($env:DOTFILES_MUX_NAMESPACE) { @('-L', $env:DOTFILES_MUX_NAMESPACE) } else { @() }
$version = & psmux --version
if (($version -join "`n") -notmatch 'psmux ([0-9]+\.[0-9]+\.[0-9]+)' -or [version]$Matches[1] -lt [version]'3.3.8') {
    throw 'Workspace requires PSMux 3.3.8 or newer. Run windows/packages.ps1 -Apply.'
}
if (-not (Test-Path -LiteralPath $WorkspaceScript -PathType Leaf)) { throw "Missing workspace helper: $WorkspaceScript. Run bootstrap.ps1 -Apply." }
$env:PYTHONUTF8 = '1'
$pythonArguments = @('run', '--offline', '--no-project', '--python', '3.13')
if ($Action -eq 'pick') {
    if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) { throw 'Repository picker requires fzf.' }
    $root = $Argument
    if (-not $root) { $root = & psmux @muxArguments show-options -gqv '@repo-root' }
    if (-not $root) { $root = if ($env:WORKSPACE_ROOT) { $env:WORKSPACE_ROOT } else { Join-Path $HOME 'repos' } }
    $rows = @(& uv @pythonArguments $WorkspaceScript list $root)
    if ($LASTEXITCODE -ne 0) { throw 'Could not list repositories and worktrees.' }
    $selected = $rows | fzf --delimiter="`t" --with-nth=2.. --prompt='Repo / worktree> ' --reverse
    if (-not $selected) { return }
    $Action = 'dev'
    $Argument = ($selected -split "`t", 2)[0]
} elseif ($Action -eq 'shortcut') {
    if ($Argument -notin @('P', 'S')) { throw 'Shortcut must be P or S.' }
    $Argument = [Environment]::GetEnvironmentVariable("DOTFILES_TMUX_${Argument}_REPO")
    if (-not $Argument) { throw 'Set DOTFILES_TMUX_P_REPO or DOTFILES_TMUX_S_REPO in ~/.config/extra.ps1.' }
    $Action = 'dev'
}
if ($Action -in @('agents', 'sidebar', 'sidebar-add', 'watch')) {
    $script = Join-Path $PSScriptRoot 'native-agents.py'
    $helperArguments = @($script, $Action, '--workspace', $WorkspaceScript)
} else {
    $helperArguments = @($WorkspaceScript, $Action)
}
if ($Argument) { $helperArguments += $Argument }
if ($Log) { $helperArguments += @('--log', $Log) }
& uv @pythonArguments @helperArguments
if ($LASTEXITCODE -ne 0) { throw "Workspace $Action failed (exit $LASTEXITCODE)." }

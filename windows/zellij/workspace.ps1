#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Position=0)][string]$Action,
      [Parameter(Position=1, ValueFromRemainingArguments)][string[]]$Arguments)

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false
$env:PYTHONUTF8 = '1'
$env:PYTHONDONTWRITEBYTECODE = '1'
$helper = Join-Path $PSScriptRoot 'workspace.py'
if ($Action -eq 'run-saved') {
    $saved = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Arguments[0])) | ConvertFrom-Json
    & $saved[0] @($saved | Select-Object -Skip 1)
    return
}
if ($Action -in @('nvim', 'codex')) {
    if ($Action -eq 'nvim') { & nvim } else { & codex resume --last }
    return # -NoExit keeps this profiled PowerShell usable after exit, failure, or Ctrl+C.
}
if ($Action -eq 'help') {
    @('Custom shortcuts: Ctrl+B R = repo picker; Ctrl+B M = monitor; Ctrl+B ? = help', '') +
        @(& zellij setup --dump-config) | fzf --no-sort --reverse --prompt='Search shortcuts> ' | Out-Null
    return
}
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { throw 'Install the Windows packages first (uv and Python 3.13 are required).' }
& uv run --offline --no-project --python 3.13 $helper $Action @Arguments
if ($LASTEXITCODE -ne 0) { Write-Error "Zellij workspace $Action failed (exit $LASTEXITCODE)." }

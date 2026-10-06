#requires -Version 5.1
# WinGet's portable installer removes the old aliases before replacing them.
# A running server (including the hidden warm server) locks its executable.
function Get-PsmuxPackageVersion {
    param([string]$PackageDirectory)

    foreach ($name in @('psmux.exe', 'pmux.exe', 'tmux.exe')) {
        $executable = Join-Path $PackageDirectory $name
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { continue }
        try {
            $output = @(& $executable --version 2>&1) -join "`n"
            if ($LASTEXITCODE -eq 0 -and $output -match '(?m)^(?:psmux|pmux|tmux) ([0-9]+\.[0-9]+\.[0-9]+)') {
                return [version]$Matches[1]
            }
        } catch { }
    }
    return $null
}

function Assert-PsmuxPackageUnlocked {
    param(
        [version]$RequiredVersion,
        [string]$PackageDirectory = (Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Packages/marlocarlo.psmux_Microsoft.Winget.Source_8wekyb3d8bbwe')
    )

    $executables = @('psmux.exe', 'pmux.exe', 'tmux.exe') | ForEach-Object { Join-Path $PackageDirectory $_ }
    $running = @(Get-Process -Name psmux, pmux, tmux -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -in $executables })
    if (-not $running.Count) { return }
    $installedVersion = Get-PsmuxPackageVersion -PackageDirectory $PackageDirectory
    if ($installedVersion -and $installedVersion -ge $RequiredVersion) { return }

    $processIds = ($running | ForEach-Object Id) -join ', '
    throw "PSMux upgrade to $RequiredVersion is blocked by running processes (PID $processIds). Save work in your PSMux panes, then run 'tmux kill-server' from a separate PowerShell terminal and retry. Detaching leaves servers running; a hidden standby server can also hold the executable open. No sessions were stopped by this helper."
}

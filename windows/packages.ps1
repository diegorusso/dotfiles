#requires -Version 5.1
<#
.SYNOPSIS
Preview native Windows packages; use -Apply to install them.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [ValidateSet('Core', 'Work', 'Personal')][string]$Profile = 'Core'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This package helper supports native Windows only.'
}
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'packages.json') -Raw | ConvertFrom-Json
$packages = @($manifest.core)
if ($Profile -ne 'Core') { $packages += @($manifest.($Profile.ToLowerInvariant())) }
foreach ($package in $packages) {
    if ($package.id -notmatch '^[A-Za-z0-9][A-Za-z0-9.+_-]*$' -or
        ($package.PSObject.Properties['version'] -and $package.version -notmatch '^0\.12\.[0-9]+$')) {
        throw 'Invalid Windows package manifest entry.'
    }
}

Write-Output "Package profile: $Profile"
foreach ($package in $packages) {
    $installArguments = @('install', '--id', $package.id, '--exact', '--source', 'winget')
    if ($package.PSObject.Properties['version']) {
        $installArguments += @('--version', $package.version)
    } else {
        $installArguments += '--no-upgrade'
    }
    Write-Output ('winget ' + ($installArguments -join ' '))
}
& (Join-Path $PSScriptRoot 'tree-sitter.ps1')
if (-not $Apply) {
    Write-Output 'Preview only. Re-run with -Apply to install packages.'
    return
}
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'WinGet is required. Install or update Microsoft App Installer, then retry.'
}

# WinGet uses nonzero HRESULTs for successful no-change outcomes.
$wingetNoChangeExitCodes = @(
    -1978335189 # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE (0x8A15002B)
    -1978335135 # APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED (0x8A150061)
)
foreach ($package in $packages) {
    $installArguments = @('install', '--id', $package.id, '--exact', '--source', 'winget',
        '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
    if ($package.PSObject.Properties['version']) {
        $installArguments += @('--version', $package.version)
    } else {
        $installArguments += '--no-upgrade'
    }
    & winget @installArguments
    $installExitCode = $LASTEXITCODE
    if ($installExitCode -in $wingetNoChangeExitCodes) {
        Write-Output "UNCHANGED $($package.id)"
    } elseif ($installExitCode -ne 0) {
        throw "WinGet failed for $($package.id) (exit $installExitCode)."
    }
}

# Installers update registry PATH values; retain this process's existing additions.
foreach ($scope in @('Machine', 'User')) {
    foreach ($entry in ([Environment]::GetEnvironmentVariable('Path', $scope) -split ';')) {
        if ($entry -and $entry -notin ($env:PATH -split ';')) { $env:PATH += ";$entry" }
    }
}
& (Join-Path $PSScriptRoot 'tree-sitter.ps1') -Apply

if (Get-Command nvim -ErrorAction SilentlyContinue) {
    $version = @(& nvim --version)[0]
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^NVIM v0\.12\.') {
        throw "Neovim 0.12.x is required; found: $version. Check which nvim is first on PATH."
    }
}
Write-Output 'Packages installed. Start a new PowerShell 7 terminal before bootstrap.'

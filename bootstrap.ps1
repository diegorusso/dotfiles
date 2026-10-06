#requires -Version 7.0
<#
.SYNOPSIS
Preview native Windows dotfiles. Use -Apply to install or -Restore to undo a backup.
.DESCRIPTION
Packages are installed separately with windows/packages.ps1. The optional path
parameters support isolated validation and redirected user folders.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Diff,
    [string]$Restore,
    [string]$UserHome = $HOME,
    [string]$LocalAppData = $env:LOCALAPPDATA,
    [string]$ProfilePath = $PROFILE.CurrentUserAllHosts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'Use bootstrap.sh on macOS and Linux.' }

function Get-AbsolutePath([string]$Path) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "Expected an absolute path: $Path" }
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
}

function Test-CloudPlaceholder([string]$Path) {
    # Cloud placeholders are reparse points too, but do not redirect path names.
    # Read the tag directly so only the documented CLOUD family is permitted.
    if (-not ('Dotfiles.WindowsPath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Dotfiles {
    public static class WindowsPath {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct FindData {
            public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh;
            public uint WriteLow, WriteHigh, SizeHigh, SizeLow, Tag, Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string Alternate;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstFileW(string path, out FindData data);
        [DllImport("kernel32.dll")] private static extern bool FindClose(IntPtr handle);
        public static uint ReparseTag(string path) {
            FindData data;
            IntPtr handle = FindFirstFileW(path, out data);
            if (handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try { return data.Tag; } finally { FindClose(handle); }
        }
    }
}
'@
    }
    return ([Dotfiles.WindowsPath]::ReparseTag($Path) -band 0xffff0fffL) -eq 0x9000001aL
}

function Assert-NormalPath([string]$Path) {
    # Check ancestors before enumerating a tree: junctions must never redirect writes.
    $current = $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
                -not (Test-CloudPlaceholder $current)) {
                throw "Refusing a link or reparse point: $current"
            }
        }
        $parent = Split-Path -LiteralPath $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-NormalTree([string]$Path) {
    Assert-NormalPath $Path
    if (Test-Path -LiteralPath $Path -PathType Container) {
        foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
                -not (Test-CloudPlaceholder $item.FullName)) {
                throw "Refusing a linked item in managed tree: $($item.FullName)"
            }
        }
    }
}

function Get-TreeSignature([string]$Path) {
    $root = Get-Item -LiteralPath $Path -Force
    if (-not $root.PSIsContainer) {
        return 'FILE ' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    'DIRECTORY'
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($Path, $item.FullName)
        if ($item.PSIsContainer) { "D $relative" } else {
            "F $relative " + (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        }
    }
}

function Test-SameContent([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Destination)) { return $false }
    $left = @(Get-TreeSignature $Source)
    $right = @(Get-TreeSignature $Destination)
    return ($left.Count -eq $right.Count -and ($left -join "`n") -ceq ($right -join "`n"))
}

function Write-TargetDiff([string]$Source, [string]$Destination) {
    if (-not $Diff) { return }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warning 'Install Git to display content differences.'
        return
    }
    $old = if (Test-Path -LiteralPath $Destination) { $Destination } else { '/dev/null' }
    $new = if ($Source) { $Source } else { '/dev/null' }
    $oldTree = Test-Path -LiteralPath $old -PathType Container
    $newTree = Test-Path -LiteralPath $new -PathType Container
    # Git cannot compare a missing tree (/dev/null) with a directory directly.
    if ($oldTree -ne $newTree) {
        if ($oldTree) {
            foreach ($file in Get-ChildItem -LiteralPath $old -File -Force -Recurse) {
                & git --no-pager diff --no-index -- $file.FullName /dev/null
                if ($LASTEXITCODE -gt 1) { throw "Could not display differences for $($file.FullName)" }
            }
        } elseif ($old -ne '/dev/null') {
            & git --no-pager diff --no-index -- $old /dev/null
            if ($LASTEXITCODE -gt 1) { throw "Could not display differences for $old" }
        }
        if ($newTree) {
            foreach ($file in Get-ChildItem -LiteralPath $new -File -Force -Recurse) {
                & git --no-pager diff --no-index -- /dev/null $file.FullName
                if ($LASTEXITCODE -gt 1) { throw "Could not display differences for $($file.FullName)" }
            }
        } elseif ($new -ne '/dev/null') {
            & git --no-pager diff --no-index -- /dev/null $new
            if ($LASTEXITCODE -gt 1) { throw "Could not display differences for $new" }
        }
        return
    }
    & git --no-pager diff --no-index -- $old $new
    if ($LASTEXITCODE -gt 1) { throw "Could not display differences for $Destination" }
}

$UserHome = Get-AbsolutePath $UserHome
$LocalAppData = Get-AbsolutePath $LocalAppData
$ProfilePath = Get-AbsolutePath $ProfilePath
if ([IO.Path]::GetExtension($ProfilePath) -ne '.ps1') { throw 'ProfilePath must name a PowerShell .ps1 file.' }
foreach ($root in @($UserHome, $LocalAppData)) {
    if ($root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')) {
        throw 'A user or application data folder cannot be a drive root.'
    }
}
$stateRoot = Join-Path $LocalAppData 'dotfiles'
$backupParent = Join-Path $stateRoot 'backups'
$roots = @{ Home = $UserHome; LocalAppData = $LocalAppData; Profile = $ProfilePath }
$targets = [ordered]@{
    gitconfig = @{ Source = Join-Path $PSScriptRoot '.gitconfig'; Destination = Join-Path $UserHome '.gitconfig' }
    gitignore = @{ Source = Join-Path $PSScriptRoot '.gitignore'; Destination = Join-Path $UserHome '.gitignore' }
    starship = @{ Source = Join-Path $PSScriptRoot '.config/starship.toml'; Destination = Join-Path $UserHome '.config/starship.toml' }
    profile = @{ Source = Join-Path $PSScriptRoot 'windows/profile.ps1'; Destination = $ProfilePath }
    powershell = @{ Source = Join-Path $PSScriptRoot 'windows/interactive.ps1'; Destination = Join-Path $UserHome '.config/dotfiles/windows/interactive.ps1' }
    workspace = @{ Source = Join-Path $PSScriptRoot 'windows/workspace'; Destination = Join-Path $UserHome '.config/dotfiles/windows/workspace' }
    tmuxhelper = @{ Source = Join-Path $PSScriptRoot '.tmux/layouts/workspace.py'; Destination = Join-Path $UserHome '.tmux/layouts/workspace.py' }
    psmux = @{ Source = Join-Path $PSScriptRoot 'windows/psmux.conf'; Destination = Join-Path $UserHome '.psmux.conf' }
    terminal = @{ Source = Join-Path $PSScriptRoot 'windows/terminal.json'; Destination = Join-Path $LocalAppData 'Microsoft/Windows Terminal/Fragments/dotfiles/terminal.json' }
    nvim = @{ Source = Join-Path $PSScriptRoot '.config/nvim'; Destination = Join-Path $LocalAppData 'nvim' }
}

# Local overrides and the checkout must never be managed destinations.
$protected = @((Join-Path $UserHome '.config/extra'), (Join-Path $UserHome '.config/extra.ps1'), $PSScriptRoot, $stateRoot)
$destinations = @()
foreach ($target in $targets.Values) {
    $target.Destination = Get-AbsolutePath $target.Destination
    foreach ($path in $protected + $destinations) {
        if ($target.Destination -eq $path -or $target.Destination.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $path.StartsWith($target.Destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Managed destination overlaps another target or protected path: $($target.Destination)"
        }
    }
    $destinations += $target.Destination
    Assert-NormalTree $target.Destination
}
Assert-NormalPath $backupParent

$operations = [Collections.Generic.List[hashtable]]::new()
if ($Restore) {
    $restoreRoot = Get-AbsolutePath $Restore
    if ((Split-Path -LiteralPath $restoreRoot) -ne $backupParent) {
        throw "Restore source must be a direct child of $backupParent"
    }
    Assert-NormalTree $restoreRoot
    $manifestPath = Join-Path $restoreRoot 'restore.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.Version -ne 'dotfiles-windows-v1') { throw 'Unsupported Windows restore manifest.' }
    foreach ($key in $roots.Keys) {
        if ($manifest.Roots[$key] -ne $roots[$key]) { throw 'Backup belongs to different destination folders.' }
    }
    $seen = @{}
    foreach ($entry in $manifest.Entries) {
        if (-not $targets.Contains($entry.Id) -or $seen.ContainsKey($entry.Id) -or
            $entry.Action -notin @('INSTALL', 'REPLACE')) { throw 'Invalid Windows restore entry.' }
        $seen[$entry.Id] = $true
        $source = $null
        if ($entry.Action -eq 'REPLACE') {
            $source = Join-Path $restoreRoot "saved/$($entry.Id)"
            if (-not (Test-Path -LiteralPath $source)) { throw "Missing restore payload: $source" }
            Assert-NormalTree $source
        }
        $operations.Insert(0, @{ Id = $entry.Id; Source = $source; Destination = $targets[$entry.Id].Destination })
    }
    if ($operations.Count -eq 0) { throw 'Restore manifest contains no changes.' }
} else {
    foreach ($id in $targets.Keys) {
        $target = $targets[$id]
        if (-not (Test-Path -LiteralPath $target.Source)) { throw "Missing source: $($target.Source)" }
        Assert-NormalTree $target.Source
        # Preserve custom Neovim namespaces rather than install an unused configuration.
        if ($id -eq 'nvim' -and ($env:XDG_CONFIG_HOME -or ($env:NVIM_APPNAME -and $env:NVIM_APPNAME -ne 'nvim'))) {
            Write-Output 'SKIP      Neovim: XDG_CONFIG_HOME or NVIM_APPNAME selects a custom configuration.'
            continue
        }
        $operations.Add(@{ Id = $id; Source = $target.Source; Destination = $target.Destination })
    }
}

function Save-Journal {
    $temporary = Join-Path $script:backupRoot 'restore.json.tmp'
    $json = $script:journal | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($temporary, $json + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination (Join-Path $script:backupRoot 'restore.json') -Force
}

function Set-ManagedTarget([hashtable]$Operation) {
    $source = $Operation.Source
    $destination = $Operation.Destination
    Assert-NormalTree $destination
    if ($source -and (Test-SameContent $source $destination)) {
        Write-Output "UNCHANGED $destination"
        return
    }
    $exists = Test-Path -LiteralPath $destination
    if (-not $source -and -not $exists) { Write-Output "ABSENT    $destination"; return }
    Write-TargetDiff $source $destination
    $action = if ($source) { 'INSTALL' } else { 'REMOVE' }
    if (-not $Apply) { Write-Output "$action   $destination"; return }

    if (-not $script:backupRoot) {
        $script:backupRoot = Join-Path $backupParent ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory((Join-Path $script:backupRoot 'saved')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $script:backupRoot 'staged')) | Out-Null
        $script:journal = @{ Version = 'dotfiles-windows-v1'; Roots = $roots; Entries = @() }
        Save-Journal
        Write-Output "Backup: $script:backupRoot"
        Write-Output "Undo preview: .\bootstrap.ps1 -Restore '$script:backupRoot'"
    }
    $saved = Join-Path $script:backupRoot "saved/$($Operation.Id)"
    $staged = Join-Path $script:backupRoot "staged/$($Operation.Id)"
    if ($source) {
        Assert-NormalTree $source
        Copy-Item -LiteralPath $source -Destination $staged -Recurse -Force
    }
    Assert-NormalPath $destination
    [IO.Directory]::CreateDirectory((Split-Path -LiteralPath $destination)) | Out-Null
    if ($exists) { Move-Item -LiteralPath $destination -Destination $saved }
    $entry = @{ Id = $Operation.Id; Action = $(if ($exists) { 'REPLACE' } else { 'INSTALL' }) }
    $script:journal.Entries += $entry
    try {
        # Journal before installing so an interrupted apply has a usable undo command.
        Save-Journal
        if ($source) { Move-Item -LiteralPath $staged -Destination $destination }
    } catch {
        if ($exists -and -not (Test-Path -LiteralPath $destination)) {
            Move-Item -LiteralPath $saved -Destination $destination
            $script:journal.Entries = @($script:journal.Entries | Where-Object { $_.Id -ne $Operation.Id })
            Save-Journal
        }
        throw
    }
    Write-Output "$action   $destination"
}

$script:backupRoot = $null
$script:journal = $null
$lock = $null
try {
    if ($Apply) {
        Assert-NormalPath $stateRoot
        [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
        $lockPath = Join-Path $stateRoot 'bootstrap.lock'
        Assert-NormalPath $lockPath
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    Write-Output ('Mode: ' + $(if ($Apply) { 'apply' } else { 'preview' }))
    foreach ($operation in $operations) { Set-ManagedTarget $operation }
} finally {
    if ($lock) { $lock.Dispose() }
}
if (-not $Apply) { Write-Output 'Preview only. Re-run with -Apply to use this plan.' } else {
    Write-Output 'Complete. Open a new PowerShell 7 session to load the profile.'
    if ($script:backupRoot) { Write-Output "Undo preview: .\bootstrap.ps1 -Restore '$script:backupRoot'" }
}
if (-not $Restore -and (Get-Command nvim -ErrorAction SilentlyContinue)) {
    $version = @(& nvim --version)[0]
    if ($version -notmatch '^NVIM v0\.12\.') {
        Write-Warning "The shared editor configuration requires Neovim 0.12.x; found: $version. Run windows/packages.ps1 -Apply."
    }
}

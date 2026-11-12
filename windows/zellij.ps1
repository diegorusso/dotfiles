#requires -Version 5.1
<# Preview or install the upstream native Windows release, never a namesake package. #>
[CmdletBinding()]
param([switch]$Apply, [string]$LocalAppData = $env:LOCALAPPDATA)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Native Windows only.' }
$version = '0.45.1'
# Upstream currently publishes x64 Windows builds; Windows 11 ARM64 uses x64 emulation.
$architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($architecture -notin @('AMD64', 'ARM64')) { throw "Zellij upstream has no release for $architecture." }
$url = "https://github.com/zellij-org/zellij/releases/download/v$version/zellij-x86_64-pc-windows-msvc.zip"
# Published at https://github.com/zellij-org/zellij/releases/expanded_assets/v0.45.1
$archiveHash = 'b854e7b223e67d0705c5f685ef50541c38a57981b13624d09c92bed419b6f80d'
$binaryHash = '7c34f38921e6884873a9922bfdd4907f4d68fd0a2dd930ce357e4c7cb23f6f42'
if (-not [IO.Path]::IsPathRooted($LocalAppData)) { throw 'LOCALAPPDATA must be absolute.' }
$destination = Join-Path ([IO.Path]::GetFullPath($LocalAppData)) 'dotfiles/bin/zellij.exe'
Write-Output "Zellij $version (upstream x64): $url -> $destination"
if (-not $Apply) { return }
$current = $destination
while ($current) {
    if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing a linked Zellij installation path: $current"
    }
    $current = Split-Path -LiteralPath $current
}
if (Test-Path -LiteralPath $destination) {
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $binaryHash) {
        Write-Output "UNCHANGED $destination"
        return
    }
    throw "A different executable exists at $destination. Move it aside before installing the verified upstream release."
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-zellij-install-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    $archive = Join-Path $scratch 'zellij.zip'
    Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $archiveHash) { throw 'Zellij archive checksum mismatch.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entry = @($zip.Entries | Where-Object FullName -eq 'zellij.exe')
        if ($entry.Count -ne 1) { throw 'Expected exactly one upstream zellij.exe.' }
        $staged = Join-Path $scratch 'zellij.exe'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry[0], $staged)
    } finally { $zip.Dispose() }
    if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne $binaryHash -or
        (& $staged --version) -ne "zellij $version") { throw 'Zellij executable verification failed.' }
    [IO.Directory]::CreateDirectory((Split-Path -LiteralPath $destination)) | Out-Null
    [IO.File]::Copy($staged, $destination, $false)
    Write-Output "INSTALLED $destination"
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ((Split-Path -LiteralPath $resolved).TrimEnd('\') -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unsafe installer cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

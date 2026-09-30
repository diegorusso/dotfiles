#requires -Version 5.1
<#
.SYNOPSIS
Preview or install the standalone Tree-sitter CLI from its official release.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$LocalAppData = $env:LOCALAPPDATA
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Native Windows only.' }
$version = '0.26.13'
# Published digests: github.com/tree-sitter/tree-sitter/releases/expanded_assets/v0.26.13
$digests = @{
    ARM64 = 'c4306ddb015aca7fd01504cfb6ac5fc449d285d50a4c60f051ef648bb303a4c9'
    AMD64 = 'c167ecf331ecd5d067cf96f612f404d7d8ebd08569b142939fcc264211f8cd9a'
    x86 = '87f0cdf9e6e5f2e2df857bea6f00f9e02f185804b45c0bae97b17bf77764731f'
}
$architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$assetArchitecture = switch ($architecture) { 'ARM64' { 'arm64' }; 'AMD64' { 'x64' }; 'x86' { 'x86' }; default { throw "Unsupported CPU: $architecture" } }
$url = "https://github.com/tree-sitter/tree-sitter/releases/download/v$version/tree-sitter-cli-windows-$assetArchitecture.zip"
if (-not [IO.Path]::IsPathRooted($LocalAppData)) { throw 'LOCALAPPDATA must be an absolute path.' }
$bin = Join-Path ([IO.Path]::GetFullPath($LocalAppData)) 'dotfiles/bin'
$destination = Join-Path $bin 'tree-sitter.exe'
Write-Output "Tree-sitter $version ($assetArchitecture): $url -> $destination"
if (-not $Apply) { return }

# Retain an adequate standalone executable supplied by another package manager.
# npm's .cmd launcher cannot be spawned directly by Neovim's native job API.
$existingCommand = Get-Command tree-sitter -ErrorAction SilentlyContinue
if ($existingCommand -and ($existingCommand.CommandType -eq 'Function' -or $existingCommand.Source.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase))) {
    $existingVersion = @(& $existingCommand --version)[0]
    if ($LASTEXITCODE -eq 0 -and $existingVersion -match '^tree-sitter ([0-9]+\.[0-9]+\.[0-9]+)' -and
        [version]$Matches[1] -ge [version]'0.26.1') {
        Write-Output "UNCHANGED $($existingCommand.Name): $existingVersion"
        return
    }
}

$current = $bin
while ($current) {
    if (Test-Path -LiteralPath $current) {
        if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing a linked tool installation directory: $current"
        }
    }
    $current = Split-Path -LiteralPath $current
}
if (Test-Path -LiteralPath $destination) {
    if ((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Tree-sitter destination is linked.' }
    $installedVersion = @(& $destination --version)[0]
    if ($LASTEXITCODE -eq 0 -and $installedVersion -match '^tree-sitter 0\.26\.13(?:\s|$)') {
        Write-Output "UNCHANGED $destination"
        return
    }
    throw "A different Tree-sitter already exists at $destination. Move it aside before installing $version."
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-tree-sitter-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
try {
    $archive = Join-Path $scratch 'tree-sitter.zip'
    Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $digests[$architecture]) {
        throw 'Tree-sitter archive checksum does not match the official release.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $binary = @($zip.Entries | Where-Object { $_.FullName -eq 'tree-sitter.exe' })
        if ($binary.Count -ne 1) { throw 'Archive does not contain the expected Tree-sitter executable.' }
        $staged = Join-Path $scratch 'tree-sitter.exe'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($binary[0], $staged)
    } finally { $zip.Dispose() }
    [IO.Directory]::CreateDirectory($bin) | Out-Null
    # Copy without overwrite, even if another installer creates the destination.
    [IO.File]::Copy($staged, $destination, $false)
    Write-Output "INSTALLED $destination"
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ((Split-Path -LiteralPath $resolved).TrimEnd('\') -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unsafe download cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

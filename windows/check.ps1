#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run this check on native Windows.' }
$repo = Split-Path -LiteralPath $PSScriptRoot

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

foreach ($file in @(Join-Path $repo 'bootstrap.ps1') + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -Recurse | Select-Object -ExpandProperty FullName)) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
    Assert ($errors.Count -eq 0) "PowerShell syntax error in $file`: $errors"
}
$terminal = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'terminal.json') -Raw | ConvertFrom-Json
Assert ($terminal.profiles[0].commandline -eq 'pwsh.exe -NoLogo') 'Terminal must launch native PowerShell.'
Write-Output 'PASS PowerShell syntax and Terminal JSON'

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-windows-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$previousXdg = $env:XDG_CONFIG_HOME
$previousAppName = $env:NVIM_APPNAME
$previousPath = $env:PATH
try {
    $env:XDG_CONFIG_HOME = $null
    $env:NVIM_APPNAME = $null
    $user = Join-Path $scratch 'user with spaces'
    $appData = Join-Path $user 'AppData/Local'
    $profileFile = Join-Path $scratch 'redirected documents/PowerShell/profile.ps1'
    $arguments = @{ UserHome = $user; LocalAppData = $appData; ProfilePath = $profileFile }
    $bootstrap = Join-Path $repo 'bootstrap.ps1'
    & $bootstrap @arguments | Out-Null
    Assert (-not (Test-Path -LiteralPath $user)) 'Preview created the user directory.'
    Assert (-not (Test-Path -LiteralPath $profileFile)) 'Preview created a profile.'
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $diff = @(& $bootstrap @arguments -Diff)
        Assert (@($diff | Where-Object { $_ -like '*init.lua*' }).Count -gt 0) 'New Neovim tree was absent from the diff.'
        Assert (-not (Test-Path -LiteralPath $user)) 'Diff preview created the user directory.'
    }
    [IO.Directory]::CreateDirectory((Join-Path $user '.config')) | Out-Null
    [IO.Directory]::CreateDirectory((Split-Path -LiteralPath $profileFile)) | Out-Null
    [IO.File]::WriteAllText((Join-Path $user '.gitconfig'), 'original git config')
    [IO.File]::WriteAllText($profileFile, 'original redirected profile')
    [IO.File]::WriteAllText((Join-Path $user '.config/extra.ps1'), '$env:DOTFILES_TEST_EXTRA = "local"')
    [IO.File]::WriteAllText((Join-Path $user '.config/extra'), 'local bash override')
    & $bootstrap @arguments -Apply | Out-Null
    $backupParent = Join-Path $appData 'dotfiles/backups'
    $backups = @(Get-ChildItem -LiteralPath $backupParent -Directory)
    Assert ($backups.Count -eq 1) 'Expected one install backup.'
    $backup = $backups[0].FullName
    Assert ([IO.File]::ReadAllText((Join-Path $user '.gitconfig')) -eq [IO.File]::ReadAllText((Join-Path $repo '.gitconfig'))) 'Git config was not installed.'
    Assert (Test-Path -LiteralPath (Join-Path $appData 'nvim/init.lua')) 'Neovim configuration missing.'
    Assert (Test-Path -LiteralPath (Join-Path $user '.psmux.conf')) 'Native multiplexer configuration missing.'
    Assert (Test-Path -LiteralPath (Join-Path $user '.tmux/layouts/workspace.py')) 'Shared workspace helper missing.'
    Assert (Test-Path -LiteralPath (Join-Path $user '.config/dotfiles/windows/workspace/native-agents.py')) 'Native agent helper missing.'
    Assert (Test-Path -LiteralPath (Join-Path $appData 'Microsoft/Windows Terminal/Fragments/dotfiles/terminal.json')) 'Terminal fragment missing.'
    Assert ([IO.File]::ReadAllText((Join-Path $user '.config/extra')) -eq 'local bash override') 'Bash override changed.'
    Assert ([IO.File]::ReadAllText((Join-Path $user '.config/extra.ps1')) -eq '$env:DOTFILES_TEST_EXTRA = "local"') 'PowerShell override changed.'
    & $bootstrap @arguments -Apply | Out-Null
    Assert (@(Get-ChildItem -LiteralPath $backupParent -Directory).Count -eq 1) 'Repeated apply created a backup.'
    & $bootstrap @arguments -Restore $backup | Out-Null
    Assert ([IO.File]::ReadAllText($profileFile) -ne 'original redirected profile') 'Restore preview changed the profile.'
    & $bootstrap @arguments -Restore $backup -Apply | Out-Null
    Assert ([IO.File]::ReadAllText($profileFile) -eq 'original redirected profile') 'Redirected profile was not restored.'
    Assert ([IO.File]::ReadAllText((Join-Path $user '.gitconfig')) -eq 'original git config') 'Git config was not restored.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $appData 'nvim'))) 'Restore retained newly installed editor config.'
    $safety = @(Get-ChildItem -LiteralPath $backupParent -Directory | Where-Object FullName -ne $backup)[0].FullName
    & $bootstrap @arguments -Restore $safety -Apply | Out-Null
    Assert (Test-Path -LiteralPath (Join-Path $appData 'nvim/init.lua')) 'Undoing a restore failed.'
    Write-Output 'PASS offline preview, install, idempotence, restore, and restore undo'

    $manifestFile = Join-Path $backup 'restore.json'
    $validManifest = [IO.File]::ReadAllText($manifestFile)
    $tampered = $validManifest | ConvertFrom-Json -AsHashtable
    $tampered.Entries[0].Id = '../extra.ps1'
    [IO.File]::WriteAllText($manifestFile, ($tampered | ConvertTo-Json -Depth 8))
    $rejected = $false
    try { & $bootstrap @arguments -Restore $backup -Apply | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Unsafe restore manifest was accepted.'
    [IO.File]::WriteAllText($manifestFile, $validManifest)
    $env:XDG_CONFIG_HOME = Join-Path $scratch 'custom config'
    $preview = @(& $bootstrap @arguments)
    Assert (@($preview | Where-Object { $_ -like 'SKIP*Neovim*' }).Count -eq 1) 'Custom Neovim namespace was not preserved.'
    $env:XDG_CONFIG_HOME = $null

    $linkedUser = Join-Path $scratch 'linked user'
    $outside = Join-Path $scratch 'outside managed paths'
    [IO.Directory]::CreateDirectory($linkedUser) | Out-Null
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    $junction = Join-Path $linkedUser '.config'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    $rejected = $false
    try {
        & $bootstrap -UserHome $linkedUser -LocalAppData (Join-Path $linkedUser 'AppData/Local') -ProfilePath (Join-Path $linkedUser 'Documents/PowerShell/profile.ps1') -Apply | Out-Null
    } catch { $rejected = $true }
    Assert $rejected 'Managed directory junction was accepted.'
    Assert (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 0) 'Installer followed the junction.'
    # Remove the verified junction itself before recursively cleaning the test root.
    Remove-Item -LiteralPath $junction -Force
    Write-Output 'PASS local overrides, custom editor namespace, and restore/path guards'

    # These command doubles verify package selection and failure propagation offline.
    $global:DotfilesPackageCalls = [Collections.Generic.List[string]]::new()
    function global:winget {
        $global:DotfilesPackageCalls.Add('winget ' + ($args -join ' '))
        $global:LASTEXITCODE = 0
    }
    function global:tree-sitter {
        $global:DotfilesPackageCalls.Add('tree-sitter ' + ($args -join ' '))
        $global:LASTEXITCODE = 0
        'tree-sitter 0.26.13'
    }
    function global:nvim {
        $global:LASTEXITCODE = 0
        'NVIM v0.12.5'
    }
    function global:uv {
        $global:DotfilesPackageCalls.Add('uv ' + ($args -join ' '))
        $global:LASTEXITCODE = 0
    }
    function global:psmux {
        $global:LASTEXITCODE = 0
        'psmux 3.3.8'
    }
    $helper = Join-Path $PSScriptRoot 'packages.ps1'
    & $helper -Profile Work | Out-Null
    Assert ($global:DotfilesPackageCalls.Count -eq 0) 'Package preview invoked an installer.'
    & $helper -Profile Work -Apply | Out-Null
    Assert (@($global:DotfilesPackageCalls | Where-Object { $_ -like '*AgileBits.1Password*' }).Count -eq 1) 'Work profile omitted its applications.'
    Assert (@($global:DotfilesPackageCalls | Where-Object { $_ -like '*VideoLAN.VLC*' }).Count -eq 0) 'Work profile selected personal applications.'
    Assert (@($global:DotfilesPackageCalls | Where-Object { $_ -like '*Neovim.Neovim*--version 0.12.*' }).Count -eq 1) 'Neovim version was not selected explicitly.'
    Assert (@($global:DotfilesPackageCalls | Where-Object { $_ -like '*marlocarlo.psmux*--version 3.3.8*' }).Count -eq 1) 'PSMux version was not selected explicitly.'
    Assert (@($global:DotfilesPackageCalls | Where-Object { $_ -eq 'uv python install --no-bin --no-registry 3.13' }).Count -eq 1) 'Workspace Python runtime was not provisioned.'
    Assert (@($global:DotfilesPackageCalls | Where-Object { $_ -like 'tree-sitter --version' }).Count -eq 1) 'Existing standalone CLI was not detected.'

    $previousLocalAppData = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = Join-Path $scratch 'package preflight'
        $muxDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Packages/marlocarlo.psmux_Microsoft.Winget.Source_8wekyb3d8bbwe'
        $global:DotfilesMuxProcessCalls = 0
        $global:DotfilesMuxProcesses = @(
            [pscustomobject]@{ Id = 101; Path = (Join-Path $muxDirectory 'tmux.exe') },
            [pscustomobject]@{ Id = 102; Path = (Join-Path $muxDirectory 'psmux.exe') },
            [pscustomobject]@{ Id = 103; Path = (Join-Path $muxDirectory 'pmux.exe') }
        )
        function Get-Process {
            $global:DotfilesMuxProcessCalls++
            $global:DotfilesMuxProcesses
        }
        $global:DotfilesPackageCalls.Clear()
        & $helper | Out-Null
        Assert ($global:DotfilesMuxProcessCalls -eq 0) 'Preview inspected live multiplexer processes.'
        $failure = $null
        try { & $helper -Apply | Out-Null } catch { $failure = $_.Exception.Message }
        Assert ($failure -like '*PSMux upgrade*blocked*PID 101, 102, 103*tmux kill-server*') "Locked or partially removed PSMux did not give recovery instructions: $failure"
        Assert ($global:DotfilesPackageCalls.Count -eq 0) 'An installer ran before the locked-package preflight.'

        . (Join-Path $PSScriptRoot 'psmux-package.ps1')
        $global:DotfilesMuxVersion = [version]'3.3.4'
        function Get-PsmuxPackageVersion { $global:DotfilesMuxVersion }
        $rejected = $false
        try { Assert-PsmuxPackageUnlocked -RequiredVersion '3.3.8' } catch { $rejected = $true }
        Assert $rejected 'A locked older multiplexer was allowed to upgrade.'
        $global:DotfilesMuxVersion = [version]'3.3.8'
        Assert-PsmuxPackageUnlocked -RequiredVersion '3.3.8'
        $global:DotfilesMuxVersion = [version]'3.3.4'
        $global:DotfilesMuxProcesses = @([pscustomobject]@{ Id = 104; Path = (Join-Path $scratch 'portable/tmux.exe') })
        Assert-PsmuxPackageUnlocked -RequiredVersion '3.3.8'
        Write-Output 'PASS PSMux upgrade locks, partial-install recovery, offline preview, and unaffected installations'
    } finally {
        $env:LOCALAPPDATA = $previousLocalAppData
        Remove-Item Function:\Get-Process, Function:\Get-PsmuxPackageVersion, Function:\Assert-PsmuxPackageUnlocked -ErrorAction SilentlyContinue
        Remove-Variable DotfilesMuxProcessCalls, DotfilesMuxProcesses, DotfilesMuxVersion -Scope Global -ErrorAction SilentlyContinue
    }
    foreach ($skipCode in @(-1978335135, -1978335189)) {
        $global:DotfilesWingetSkipCode = $skipCode
        $global:DotfilesPackageCalls.Clear()
        function global:winget {
            $global:DotfilesPackageCalls.Add('winget ' + ($args -join ' '))
            $global:LASTEXITCODE = $global:DotfilesWingetSkipCode
        }
        $result = @(& $helper -Apply)
        Assert (@($result | Where-Object { $_ -eq 'UNCHANGED Microsoft.PowerShell' }).Count -eq 1) "Existing PowerShell was not skipped for exit $skipCode."
        Assert (@($global:DotfilesPackageCalls | Where-Object { $_ -like 'winget *zig.zig*' }).Count -eq 1) "Package installation did not continue after exit $skipCode."
    }
    . (Join-Path $PSScriptRoot 'interactive.ps1')
    Assert ($env:EDITOR -eq 'nvim') 'PowerShell did not select Neovim.'
    Assert ($env:STARSHIP_CONFIG -eq (Join-Path $HOME '.config/starship.toml')) 'PowerShell did not select the shared prompt.'
    $newDirectory = Join-Path $scratch 'native shell directory'
    $previousLocation = Get-Location
    try {
        mkd $newDirectory
        Assert ((Get-Location).Path -eq $newDirectory) 'mkd did not enter the literal directory.'
    } finally { Set-Location -LiteralPath $previousLocation.Path }
    function global:winget { $global:LASTEXITCODE = 42 }
    $rejected = $false
    try { & $helper -Apply | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Package helper ignored installation failure.'
    Write-Output 'PASS native shell setup, package selection, already-installed results, and failure handling'
} finally {
    $env:XDG_CONFIG_HOME = $previousXdg
    $env:NVIM_APPNAME = $previousAppName
    $env:PATH = $previousPath
    Remove-Item Function:\winget, Function:\tree-sitter, Function:\nvim, Function:\uv, Function:\psmux -ErrorAction SilentlyContinue
    Remove-Variable DotfilesPackageCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable DotfilesWingetSkipCode -Scope Global -ErrorAction SilentlyContinue
    # The generated path must remain an immediate child of the system temp folder.
    $resolved = [IO.Path]::GetFullPath($scratch)
    Assert ((Split-Path -LiteralPath $resolved).TrimEnd('\') -eq [IO.Path]::GetTempPath().TrimEnd('\')) 'Unsafe test cleanup path.'
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Output 'All native Windows checks passed.'

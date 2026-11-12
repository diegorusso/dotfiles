# PowerShell 7 entrypoint, installed to $PROFILE.CurrentUserAllHosts.
$dotfilesWindowsLayer = Join-Path $HOME '.config/dotfiles/windows/interactive.ps1'
if (Test-Path -LiteralPath $dotfilesWindowsLayer -PathType Leaf) {
    . $dotfilesWindowsLayer
}

# Machine and employer settings are local and run after shared defaults.
$dotfilesWindowsExtra = Join-Path $HOME '.config/extra.ps1'
if (Test-Path -LiteralPath $dotfilesWindowsExtra -PathType Leaf) {
    . $dotfilesWindowsExtra
}
Remove-Variable dotfilesWindowsLayer, dotfilesWindowsExtra -ErrorAction SilentlyContinue

if ($env:ZELLIJ_SESSION_NAME) {
    $env:DOTFILES_ZELLIJ_SHELL = Join-Path $PSHOME 'pwsh.exe'
    # PowerShell's provider location and the native process cwd are separate.
    # Synchronize at cd/pushd/popd, independently of later host-specific prompts.
    [Environment]::CurrentDirectory = (Get-Location).ProviderPath
    function global:Set-Location {
        Microsoft.PowerShell.Management\Set-Location @args
        if ((Get-Location).Provider.Name -eq 'FileSystem') {
            [Environment]::CurrentDirectory = (Get-Location).ProviderPath
        }
    }
    function global:Push-Location {
        Microsoft.PowerShell.Management\Push-Location @args
        if ((Get-Location).Provider.Name -eq 'FileSystem') {
            [Environment]::CurrentDirectory = (Get-Location).ProviderPath
        }
    }
    function global:Pop-Location {
        Microsoft.PowerShell.Management\Pop-Location @args
        if ((Get-Location).Provider.Name -eq 'FileSystem') {
            [Environment]::CurrentDirectory = (Get-Location).ProviderPath
        }
    }
    $dotfilesZellijHelper = Join-Path $HOME '.config/dotfiles/windows/zellij/workspace.ps1'
    if (Test-Path -LiteralPath $dotfilesZellijHelper) { & $dotfilesZellijHelper start }
    Remove-Variable dotfilesZellijHelper
}

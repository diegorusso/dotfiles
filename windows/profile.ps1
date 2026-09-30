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

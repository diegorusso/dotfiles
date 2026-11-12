# Generate only the platform-specific parts; palettes and layout geometry remain shared.
function Get-ZellijWindowsFiles([string]$Repository, [string]$Wrapper, [string]$Shell) {
    $quote = { param($value) ConvertTo-Json -InputObject ($value -replace '\\', '/') -Compress }
    $shellKdl = & $quote $Shell
    $wrapperKdl = & $quote $Wrapper
    $source = Join-Path $Repository '.config/zellij'
    $config = Get-Content -LiteralPath (Join-Path $source 'config.kdl') -Raw
    $config = ($config -split "`r?`n" | ForEach-Object {
        if ($_ -match '^\s+Run "bash"') {
            $action = if ($_ -match 'pick-repo.sh') { 'pick' } elseif ($_ -match 'open-monitor.sh') { 'monitor' } else { 'help' }
            "            Run $shellKdl `"-NoLogo`" `"-File`" $wrapperKdl `"$action`" {"
        } elseif ($_ -match 'name "Shortcuts') { '                name "Shortcuts (Esc to close, type to search)"' }
        else { $_ }
    }) -join "`n"
    $config += "`ndefault_shell $shellKdl`nsession_serialization true`n"
    $files = [ordered]@{ 'config.kdl' = $config }
    foreach ($layout in @('repo', 'monitor')) {
        $text = Get-Content -LiteralPath (Join-Path $source "layouts/$layout.kdl") -Raw
        $text = $text.Replace('command="bash"', "command=$shellKdl")
        $text = ($text -split "`r?`n" | ForEach-Object {
            if ($_ -match '^\s+args "-c"') {
                $action = if ($_ -match 'codex resume') { 'codex' } elseif ($_ -match 'nvim;') { 'nvim' }
                          elseif ($_ -match 'htop;') { 'processes' } else { 'events' }
                "            args `"-NoLogo`" `"-NoExit`" `"-File`" $wrapperKdl `"$action`""
            } else { $_ }
        }) -join "`n"
        $text = $text.Replace('name="htop"', 'name="processes"').Replace('name="dmesg"', 'name="System events"')
        $text = $text.Replace('// macOS dmesg cannot follow new messages; stream its kernel log instead.', '// Follow the native Windows System event log.')
        $files["layouts/$layout.kdl"] = $text
    }
    return $files
}

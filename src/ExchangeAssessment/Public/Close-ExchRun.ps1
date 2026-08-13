<#
Closes the run context and writes integrity manifest.
#>

function Close-ExchRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    try { Stop-Transcript | Out-Null }
    catch {
        Write-ExchLog -Level 'WARN' -Message 'Stop-Transcript failed or not running' -Data @{ error = $_.Exception.Message } -LogPath $Run.LogPath
    }

    $manifest = Get-ExchFileHashManifest -FolderPath $Run.RunFolder
    $manifestPath = Join-Path $Run.RunFolder 'hash-manifest.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding UTF8

    Write-ExchLog -Level 'INFO' -Message 'Run closed' -Data @{ runId=$Run.RunId; manifestPath=$manifestPath; finishedUtc=(Get-Date).ToUniversalTime().ToString('o') } -LogPath $Run.LogPath
    return $manifestPath
}

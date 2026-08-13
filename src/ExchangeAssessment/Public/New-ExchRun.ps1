<#
Creates a new Exchange Assessment run context.
#>

function New-ExchRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputRoot,
        [Parameter()][ValidatePattern('^[a-zA-Z0-9\-_\.]{0,64}$')][string]$TenantHint = 'tenant'
    )

    $runId = [guid]::NewGuid().ToString()
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $runFolder = Join-Path $OutputRoot "$TenantHint-$ts-$runId"

    New-Item -ItemType Directory -Path $runFolder -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $runFolder 'evidence') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $runFolder 'logs') -Force | Out-Null

    $logPath = Join-Path $runFolder 'logs\run.jsonl'
    $transcriptPath = Join-Path $runFolder 'logs\transcript.txt'

    Start-Transcript -Path $transcriptPath -Force | Out-Null

    Write-ExchLog -Level 'INFO' -Message 'Run created' -Data @{ runId=$runId; tenantHint=$TenantHint; runFolder=$runFolder } -LogPath $logPath

    [pscustomobject]@{
        RunId          = $runId
        TenantHint     = $TenantHint
        RunFolder      = $runFolder
        EvidenceFolder = (Join-Path $runFolder 'evidence')
        LogPath        = $logPath
        TranscriptPath = $transcriptPath
        StartedUtc     = (Get-Date).ToUniversalTime()
    }
}

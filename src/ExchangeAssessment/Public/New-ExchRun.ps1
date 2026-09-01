<#
Creates a new Exchange Assessment run context.

The run context carries everything a collector needs that is not Exchange data: where to write,
where to log, the merged threshold configuration, and the switches the caller asked for.
#>

function New-ExchRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputRoot,
        [Parameter()][ValidatePattern('^[a-zA-Z0-9\-_\.]{0,64}$')][string]$TenantHint = 'tenant',
        # A .psd1 whose keys are merged over Config/Thresholds.psd1, so a client baseline can
        # differ from the default without editing the module.
        [Parameter()][string]$ConfigPath,
        # Emit every inventory row into assessment.json instead of summarising the sections
        # whose size scales with the organisation.
        [Parameter()][switch]$FullInventory,
        [Parameter()][switch]$IncludeExchangeOnline
    )

    $runId = [guid]::NewGuid().ToString()
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $runFolder = Join-Path $OutputRoot "$TenantHint-$ts-$runId"

    New-Item -ItemType Directory -Path $runFolder -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $runFolder 'evidence') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $runFolder 'logs') -Force | Out-Null

    $logPath = Join-Path $runFolder 'logs\run.jsonl'
    $transcriptPath = Join-Path $runFolder 'logs\transcript.txt'

    $config = Import-ExchConfiguration -ConfigPath $ConfigPath

    Start-Transcript -Path $transcriptPath -Force | Out-Null

    Write-ExchLog -Level 'INFO' -Message 'Run created' -Data @{
        runId      = $runId
        tenantHint = $TenantHint
        runFolder  = $runFolder
        configPath = if ($ConfigPath) { $ConfigPath } else { 'default' }
    } -LogPath $logPath

    [pscustomobject]@{
        RunId          = $runId
        TenantHint     = $TenantHint
        RunFolder      = $runFolder
        EvidenceFolder = (Join-Path $runFolder 'evidence')
        LogPath        = $logPath
        TranscriptPath = $transcriptPath
        StartedUtc     = (Get-Date).ToUniversalTime()
        Config         = $config
        ConfigPath     = $ConfigPath
        # Every failure recorded by Write-ExchError lands here as well as in the log, so the
        # report can say what could not be read rather than quietly omitting it.
        Errors         = (New-Object System.Collections.Generic.List[object])
        Flags          = @{
            FullInventory         = [bool]$FullInventory.IsPresent
            IncludeExchangeOnline = [bool]$IncludeExchangeOnline.IsPresent
        }
    }
}

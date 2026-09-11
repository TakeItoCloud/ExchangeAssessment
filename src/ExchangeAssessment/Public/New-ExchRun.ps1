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
        # A .psd1 replacing Config/BuildTable.psd1 for this run, so a newer copy of Microsoft's
        # build list can be used without editing the module.
        [Parameter()][string]$BuildTablePath,
        # A .psd1 replacing Config/PrereqTable.psd1 for this run, so a newer reading of the
        # Exchange Server SE prerequisites can be used without editing the module.
        [Parameter()][string]$PrereqTablePath,
        # Emit every inventory row into assessment.json instead of summarising the sections
        # whose size scales with the organisation.
        [Parameter()][switch]$FullInventory,
        [Parameter()][switch]$IncludeExchangeOnline,
        # Exchange Online authentication. Interactive needs only the UPN; app-only needs the
        # app id, the certificate thumbprint and the tenant. None of these is written to the run
        # folder - only the authentication mode and the organisation are recorded.
        [Parameter()][string]$CloudUserPrincipalName,
        [Parameter()][string]$CloudAppId,
        [Parameter()][string]$CloudCertificateThumbprint,
        [Parameter()][string]$CloudOrganization,
        [Parameter()][switch]$CloudManagedIdentity,
        [Parameter()][string]$CloudManagedIdentityAccountId
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

    if ($BuildTablePath -and -not (Test-Path -LiteralPath $BuildTablePath)) {
        throw "BuildTablePath not found: $BuildTablePath"
    }

    if ($PrereqTablePath -and -not (Test-Path -LiteralPath $PrereqTablePath)) {
        throw "PrereqTablePath not found: $PrereqTablePath"
    }

    Start-Transcript -Path $transcriptPath -Force | Out-Null

    Write-ExchLog -Level 'INFO' -Message 'Run created' -Data @{
        runId      = $runId
        tenantHint = $TenantHint
        runFolder  = $runFolder
        configPath = if ($ConfigPath) { $ConfigPath } else { 'default' }
        buildTablePath = if ($BuildTablePath) { $BuildTablePath } else { 'default' }
        prereqTablePath = if ($PrereqTablePath) { $PrereqTablePath } else { 'default' }
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
        BuildTablePath = $BuildTablePath
        PrereqTablePath = $PrereqTablePath
        # Every failure recorded by Write-ExchError lands here as well as in the log, so the
        # report can say what could not be read rather than quietly omitting it.
        Errors         = (New-Object System.Collections.Generic.List[object])
        CloudAuth      = @{
            UserPrincipalName        = $CloudUserPrincipalName
            AppId                    = $CloudAppId
            CertificateThumbprint    = $CloudCertificateThumbprint
            Organization             = $CloudOrganization
            ManagedIdentity          = [bool]$CloudManagedIdentity.IsPresent
            ManagedIdentityAccountId = $CloudManagedIdentityAccountId
        }
        Cloud          = (New-ExchCloudState -Prefix ([string](Get-ExchThreshold -Run ([pscustomobject]@{ Config = $config }) -Name 'Cloud.CommandPrefix' -Default 'Cloud')))
        Flags          = @{
            FullInventory         = [bool]$FullInventory.IsPresent
            IncludeExchangeOnline = [bool]$IncludeExchangeOnline.IsPresent
        }
    }
}

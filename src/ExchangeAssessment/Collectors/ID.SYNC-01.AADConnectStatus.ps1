<#
ID.SYNC-01 - AAD Connect synchronization health (local best-effort).
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_ID_SYNC_01_AADConnectStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'ID.SYNC-01'

    $svc = $null
    $scheduler = $null
    $errors = New-Object System.Collections.Generic.List[string]

    try { $svc = Get-Service -Name 'ADSync' -ErrorAction Stop }
    catch { $errors.Add('ADSync service not found or inaccessible: ' + $_.Exception.Message) | Out-Null }

    try {
        if (Get-Module -ListAvailable ADSync) {
            Import-Module ADSync -ErrorAction Stop
            $scheduler = Get-ADSyncScheduler -ErrorAction Stop
        }
        else {
            $errors.Add('ADSync module not available on this host.') | Out-Null
        }
    }
    catch {
        $errors.Add('Get-ADSyncScheduler failed: ' + $_.Exception.Message) | Out-Null
    }

    $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'identity/aad-connect.json' -ContentObject ([ordered]@{
        service   = $svc
        scheduler = $scheduler
        errors    = @($errors)
    })

    $outcome = 'Unknown'
    $sev = 'Medium'
    $suff = if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }
    $rat = 'AAD Connect signals captured (local host).'

    $recent = $null
    try {
        if ($scheduler -and $scheduler.LastSyncTime) {
            $recent = ((Get-Date) - [datetime]$scheduler.LastSyncTime).TotalHours
        }
    } catch { }

    if ($svc -and $svc.Status -eq 'Running' -and $null -ne $recent -and $recent -le 2) {
        $outcome = 'Compliant'
        $sev = 'Low'
        $rat = 'ADSync running and recent sync within 2 hours.'
    }
    elseif ($svc -and $svc.Status -eq 'Running' -and $null -ne $recent -and $recent -gt 2) {
        $outcome = 'PartiallyCompliant'
        $sev = 'Medium'
        $rat = 'ADSync running but last sync older than 2 hours.'
    }
    elseif ($svc -and $svc.Status -ne 'Running') {
        $outcome = 'NonCompliant'
        $sev = 'High'
        $rat = 'ADSync service not running.'
    }
    elseif (-not $svc) {
        $outcome = 'Unknown'
        $sev = 'High'
        $rat = 'ADSync service not found on this host (may run elsewhere).'
    }

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence @($evidencePath) `
        -Remediation 'Verify AAD Connect is installed, running, and syncing on the designated server; resolve scheduler errors.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{ serviceStatus = if($svc){$svc.Status}else{$null}; lastSyncHours=$recent } `
        -Meta @{ dataSources = @{ AADConnect = @{ state= if($errors.Count -gt 0){'Partial'} else {'Success'} ; reason = if($errors.Count -gt 0){'One or more sync signals missing'} else {''} } }; evaluationStatus = 'Complete' }
}

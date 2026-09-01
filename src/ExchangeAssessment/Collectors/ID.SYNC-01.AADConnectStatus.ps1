<#
ID.SYNC-01 - Directory synchronisation health.

Best-effort and local: the ADSync service runs on its own server, which is usually not an
Exchange server. Where the service is not present on this host, that is reported as
"not assessed from here" rather than as a failure - the alternative would be to fail every
organisation whose sync server is elsewhere.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_ID_SYNC_01_AADConnectStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'ID.SYNC-01'

    $maxAgeHours = [int](Get-ExchThreshold -Run $Run -Name 'DirectorySync.MaxSyncAgeHours' -Default 3)
    $errors = New-Object System.Collections.Generic.List[string]

    $service = $null
    try { $service = Get-Service -Name 'ADSync' -ErrorAction Stop }
    catch {
        $errors.Add("ADSync service not present on $($env:COMPUTERNAME)") | Out-Null
        $null = Write-ExchError -Run $Run -Context 'Get-Service ADSync' -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
    }

    $scheduler = $null
    if ($service) {
        try {
            if (Get-Module -ListAvailable -Name ADSync -ErrorAction SilentlyContinue) {
                Import-Module ADSync -ErrorAction Stop
                $scheduler = Get-ADSyncScheduler -ErrorAction Stop
            }
            else { $errors.Add('ADSync PowerShell module not available') | Out-Null }
        }
        catch {
            $errors.Add("Get-ADSyncScheduler failed: $($_.Exception.Message)") | Out-Null
            $null = Write-ExchError -Run $Run -Context 'Get-ADSyncScheduler' -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
        }
    }

    $lastSync = $null
    $syncAgeHours = $null
    if ($scheduler) {
        try {
            if ($scheduler.LastSyncCycleStartTime) {
                $lastSync = [datetime]$scheduler.LastSyncCycleStartTime
                $syncAgeHours = [math]::Round(((Get-Date) - $lastSync).TotalHours, 2)
            }
        }
        catch { $errors.Add('LastSyncCycleStartTime unreadable') | Out-Null }
    }

    $row = [pscustomobject]@{
        Host                 = [string]$env:COMPUTERNAME
        ServicePresent       = [bool]$service
        ServiceStatus        = $(if ($service) { [string]$service.Status } else { 'Not installed' })
        SyncCycleEnabled     = $(if ($scheduler) { [bool]$scheduler.SyncCycleEnabled } else { '' })
        StagingModeEnabled   = $(if ($scheduler) { [bool]$scheduler.StagingModeEnabled } else { '' })
        AllowedSyncCycleInterval = $(if ($scheduler) { [string]$scheduler.AllowedSyncCycleInterval } else { '' })
        LastSyncCycleStartTime   = $lastSync
        SyncAgeHours         = $syncAgeHours
        Notes                = (@($errors.ToArray()) -join '; ')
    }

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'identity/aad-connect.json' -ContentObject ([ordered]@{
        state  = $row
        scheduler = $scheduler
        errors = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'identity.directory-sync' -Title 'Directory Synchronisation' -Area 'Identity' `
            -Columns @('Host', 'ServicePresent', 'ServiceStatus', 'SyncCycleEnabled', 'StagingModeEnabled', 'AllowedSyncCycleInterval', 'LastSyncCycleStartTime', 'SyncAgeHours', 'Notes') `
            -Rows @($row)
    )

    if (-not $service) {
        $finding = New-ExchControlFinding -Control $control -Severity 'Info' -Outcome 'Unknown' -Sufficiency 'SoftFail' `
            -Rationale ("The ADSync service is not installed on {0}, so directory synchronisation health could not be assessed from this host. Entra Connect usually runs on a dedicated server." -f $env:COMPUTERNAME) `
            -Evidence @($evidence) `
            -Remediation 'Run this assessment on the Entra Connect server as well, or check synchronisation health from the Entra admin centre. If the organisation is not synchronised to Entra ID, no action is needed.' `
            -Metrics @{ servicePresent = $false; assessedHost = [string]$env:COMPUTERNAME } `
            -Meta @{ dataSources = @{ ADSync = @{ state = 'NotPresent'; reason = 'ADSync service not installed on the assessed host' } }; evaluationStatus = 'NotApplicable' }

        return New-ExchCollectorResult -Sections $sections -Findings @($finding)
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ([string]$service.Status -ne 'Running') {
        $problems.Add(("The ADSync service is {0}, so directory synchronisation has stopped" -f $service.Status)) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    elseif ($null -eq $syncAgeHours) {
        $problems.Add('The ADSync service is running but the last sync cycle time could not be read') | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif ($syncAgeHours -gt $maxAgeHours) {
        $problems.Add(("The last synchronisation cycle started {0} hours ago, beyond the {1} hour threshold" -f $syncAgeHours, $maxAgeHours)) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    else {
        $outcomes.Add('Compliant') | Out-Null
    }

    if ($scheduler -and -not $scheduler.SyncCycleEnabled) {
        $problems.Add('The synchronisation cycle is disabled in the scheduler') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($scheduler -and $scheduler.StagingModeEnabled) {
        $problems.Add('The server is in staging mode, so it is not exporting changes to Entra ID') | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Medium' }
        'Unknown'            { 'Medium' }
        default              { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else { ("The ADSync service is running and the last synchronisation cycle started {0} hours ago, within the {1} hour threshold." -f $syncAgeHours, $maxAgeHours) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Start the ADSync service, re-enable the sync cycle, and investigate any connector run errors so that directory changes reach Entra ID.' `
        -Metrics @{
            servicePresent = $true
            serviceStatus  = [string]$service.Status
            syncAgeHours   = $syncAgeHours
            thresholdHours = $maxAgeHours
        } `
        -Meta @{ dataSources = @{ ADSync = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

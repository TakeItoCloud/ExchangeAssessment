<#
CLD.MIG-01 - Exchange Online migration endpoints and batches.

Relevant while a hybrid organisation is moving mailboxes, and worth knowing afterwards too: a
migration batch left in a failed state, or move requests that never completed, are the usual
reason a "finished" migration still has mailboxes on-premises.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_CLD_MIG_01_TenantMigration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'CLD.MIG-01'

    $state = Get-ExchCloudState -Run $Run
    if ($null -eq $state -or -not $state.Connected) {
        return New-ExchCollectorResult -Findings @(New-ExchCloudUnavailableFinding -Control $control -Run $Run)
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $endpoints = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-MigrationEndpoint' -Errors $errors -ControlId $control.controlId)
    $batches   = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-MigrationBatch'    -Errors $errors -ControlId $control.controlId)
    $moves     = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-MoveRequest'       -Errors $errors -ControlId $control.controlId)

    $maxAgeDays = [int](Get-ExchThreshold -Run $Run -Name 'Cloud.MaxMigrationBatchAgeDays' -Default 30)
    $now = Get-Date

    $endpointRows = foreach ($e in $endpoints) {
        [pscustomobject]@{
            Identity                = [string]$e.Identity
            EndpointType            = [string](Get-ExchCloudProperty -Object $e -Name 'EndpointType')
            RemoteServer            = [string](Get-ExchCloudProperty -Object $e -Name 'RemoteServer')
            MaxConcurrentMigrations = [string](Get-ExchCloudProperty -Object $e -Name 'MaxConcurrentMigrations')
            MaxConcurrentIncrementalSyncs = [string](Get-ExchCloudProperty -Object $e -Name 'MaxConcurrentIncrementalSyncs')
            Username                = [string](Get-ExchCloudProperty -Object $e -Name 'Username')
        }
    }

    $batchRows = foreach ($b in $batches) {
        $created = Get-ExchCloudProperty -Object $b -Name 'CreationDateTime'
        $ageDays = $null
        if ($created) {
            try { $ageDays = [math]::Round(($now - [datetime]$created).TotalDays, 1) } catch { $ageDays = $null }
        }
        [pscustomobject]@{
            Identity        = [string]$b.Identity
            Status          = [string](Get-ExchCloudProperty -Object $b -Name 'Status')
            TotalCount      = [string](Get-ExchCloudProperty -Object $b -Name 'TotalCount')
            ActiveCount     = [string](Get-ExchCloudProperty -Object $b -Name 'ActiveCount')
            FailedCount     = [string](Get-ExchCloudProperty -Object $b -Name 'FailedCount')
            SyncedCount     = [string](Get-ExchCloudProperty -Object $b -Name 'SyncedCount')
            CreationDateTime= (ConvertTo-ExchFlatValue -Value $created)
            AgeDays         = $ageDays
        }
    }

    $moveRows = foreach ($m in $moves) {
        [pscustomobject]@{
            DisplayName    = [string](Get-ExchCloudProperty -Object $m -Name 'DisplayName')
            Status         = [string](Get-ExchCloudProperty -Object $m -Name 'Status')
            BatchName      = [string](Get-ExchCloudProperty -Object $m -Name 'BatchName')
            RemoteHostName = [string](Get-ExchCloudProperty -Object $m -Name 'RemoteHostName')
            Direction      = [string](Get-ExchCloudProperty -Object $m -Name 'Direction')
            Suspend        = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $m -Name 'Suspend'))
        }
    }

    $endpointArr = @($endpointRows)
    $batchArr    = @($batchRows)
    $moveArr     = @($moveRows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'cloud/migration.json' -ContentObject ([ordered]@{
        migrationEndpoints = $endpointArr
        migrationBatches   = $batchArr
        moveRequests       = $moveArr
        errors             = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'cloud.migration-endpoints' -Title 'Exchange Online Migration Endpoints' -Area 'Cloud' `
            -Columns @('Identity', 'EndpointType', 'RemoteServer', 'MaxConcurrentMigrations', 'MaxConcurrentIncrementalSyncs', 'Username') -Rows $endpointArr

        New-ExchInventorySection -Run $Run -Key 'cloud.migration-batches' -Title 'Migration Batches' -Area 'Cloud' `
            -Columns @('Identity', 'Status', 'TotalCount', 'ActiveCount', 'SyncedCount', 'FailedCount', 'CreationDateTime', 'AgeDays') -Rows $batchArr

        New-ExchInventorySection -Run $Run -Key 'cloud.move-requests' -Title 'Move Requests' -Area 'Cloud' `
            -Columns @('DisplayName', 'Status', 'BatchName', 'RemoteHostName', 'Direction', 'Suspend') -Rows $moveArr -HighCardinality
    )

    if ($endpointArr.Count -eq 0 -and $batchArr.Count -eq 0 -and $moveArr.Count -eq 0) {
        $rationale = 'No migration endpoints, batches or move requests exist in the tenant, so no mailbox migration is in progress.'
        if ($errors.Count -gt 0) { $rationale += (" Some migration cmdlets could not be read: {0}." -f ($errors -join '; ')) }

        $finding = New-ExchControlFinding -Control $control -Severity 'Info' `
            -Outcome $(if ($errors.Count -gt 0) { 'Unknown' } else { 'Compliant' }) `
            -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
            -Rationale $rationale `
            -Evidence @($evidence) `
            -Remediation 'No action required. A hybrid organisation that intends to move mailboxes will need a migration endpoint before it can.' `
            -Metrics @{ migrationEndpoints = 0; migrationBatches = 0; moveRequests = 0 } `
            -Meta @{ dataSources = @{ ExchangeOnline = @{ state = 'Success'; reason = 'No migration activity' } }; evaluationStatus = 'Complete' }

        return New-ExchCollectorResult -Sections $sections -Findings @($finding)
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    $failedBatches = @($batchArr | Where-Object { [string]$_.Status -match 'Failed' })
    if ($failedBatches.Count -gt 0) {
        $problems.Add(("{0} migration batches are in a Failed state: {1}" -f $failedBatches.Count, `
            (($failedBatches | ForEach-Object { $_.Identity }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    $withFailures = @($batchArr | Where-Object { $_.FailedCount -and [int]$_.FailedCount -gt 0 })
    if ($withFailures.Count -gt 0) {
        $problems.Add(("{0} migration batches contain failed mailboxes: {1}" -f $withFailures.Count, `
            (($withFailures | ForEach-Object { "$($_.Identity) ($($_.FailedCount) failed)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    $stale = @($batchArr | Where-Object { $null -ne $_.AgeDays -and $_.AgeDays -gt $maxAgeDays -and [string]$_.Status -notmatch 'Completed|Removing' })
    if ($stale.Count -gt 0) {
        $problems.Add(("{0} migration batches have been open for more than {1} days without completing: {2}" -f $stale.Count, $maxAgeDays, `
            (($stale | ForEach-Object { "$($_.Identity) ($($_.AgeDays)d, $($_.Status))" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $failedMoves = @($moveArr | Where-Object { [string]$_.Status -match 'Failed' })
    if ($failedMoves.Count -gt 0) {
        $problems.Add(("{0} move requests are Failed and those mailboxes have not moved: {1}" -f $failedMoves.Count, `
            (($failedMoves | Select-Object -First 10 | ForEach-Object { $_.DisplayName }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    $suspendedMoves = @($moveArr | Where-Object { $_.Suspend -eq $true })
    if ($suspendedMoves.Count -gt 0) {
        $problems.Add(("{0} move requests are suspended and will not complete until resumed" -f $suspendedMoves.Count)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($errors.Count -gt 0) {
        $problems.Add(("Some migration configuration could not be read: {0}" -f ($errors -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Medium' }
        'Unknown'            { 'Medium' }
        default              { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else { ("{0} migration endpoints, {1} batches and {2} move requests are present, none failed or stalled." -f `
                        $endpointArr.Count, $batchArr.Count, $moveArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Work the failure report on each failed batch and move request, resume anything suspended deliberately, and remove completed batches so the remaining work is visible.' `
        -Metrics @{
            migrationEndpoints = $endpointArr.Count
            migrationBatches   = $batchArr.Count
            failedBatches      = $failedBatches.Count
            moveRequests       = $moveArr.Count
            failedMoves        = $failedMoves.Count
        } `
        -Meta @{ dataSources = @{ ExchangeOnline = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

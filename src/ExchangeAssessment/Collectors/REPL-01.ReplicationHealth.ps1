<#
REPL-01 - Mailbox replication and client connectivity health.

Where MB.DB-01 and DAG-01 report the shape of high availability, this reports whether it is
actually working right now: Test-ReplicationHealth on every DAG member, and MAPI connectivity
against every mounted database.

Both cmdlets are read-only probes. Test-Mailflow is deliberately not used - it sends live
messages, which this assessment will not do.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_REPL_01_ReplicationHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'REPL-01'

    $errors = New-Object System.Collections.Generic.List[string]
    $dags = @(Invoke-ExchQuery -Label 'Get-DatabaseAvailabilityGroup' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-DatabaseAvailabilityGroup -ErrorAction Stop })

    $members = @($dags | ForEach-Object { @($_.Servers) } | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)

    $passing = @(Get-ExchThreshold -Run $Run -Name 'Replication.PassingResults' -Default @('Passed'))
    $ignored = @(Get-ExchThreshold -Run $Run -Name 'Replication.IgnoredChecks' -Default @())

    $replicationRows = New-Object System.Collections.Generic.List[object]
    foreach ($member in $members) {
        foreach ($check in @(Invoke-ExchQuery -Label ("Test-ReplicationHealth on {0}" -f $member) -Errors $errors -Run $Run -ControlId $control.controlId -Script { Test-ReplicationHealth -Identity $member -ErrorAction Stop })) {
            $checkName = [string]$check.Check
            if ($ignored -contains $checkName) { continue }
            $result = [string]$check.Result
            $replicationRows.Add([pscustomobject]@{
                Server  = $member
                Check   = $checkName
                Result  = $result
                Passed  = ($passing -contains $result)
                Error   = [string]$check.Error
            }) | Out-Null
        }
    }

    $mapiRows = New-Object System.Collections.Generic.List[object]
    $mapiNotTested = New-Object System.Collections.Generic.List[string]
    foreach ($db in @(Invoke-ExchQuery -Label 'Get-MailboxDatabase' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-MailboxDatabase -Status -ErrorAction Stop })) {
        # A database measured as dismounted is skipped; MB.DB-01 reports it. One whose Mounted
        # state did not come back is not tested either: its Information Store did not answer the
        # status read, and a MAPI test against it can only wait for the same timeout. (REPL-01
        # took 647 seconds on the second live run; how much of that was these tests and how much
        # Test-ReplicationHealth was not recorded.) It is named as not tested instead.
        # The database is passed by name, a string: over the Exchange Management Shell's remote
        # session $db.Identity is a deserialized ADObjectId that -Database cannot bind -
        # measured on the first live run, which logged 20 failures of exactly that form.
        $dbName = [string](Get-ExchObjectValue -InputObject $db -Name 'Name' -Default '')
        if (-not $dbName) { continue }
        $mounted = Get-ExchObjectBool -InputObject $db -Name 'Mounted'
        if ($mounted -eq $false) { continue }
        if ($null -eq $mounted) { $mapiNotTested.Add($dbName) | Out-Null; continue }
        foreach ($result in @(Invoke-ExchQuery -Label ("Test-MAPIConnectivity on {0}" -f $dbName) -Errors $errors -Run $Run -ControlId $control.controlId -Script { Test-MAPIConnectivity -Database $dbName -ErrorAction Stop })) {
            $mapiRows.Add([pscustomobject]@{
                Database = $dbName
                Server   = [string]$result.Server
                Result   = [string]$result.Result
                Latency  = (ConvertTo-ExchFlatValue -Value $result.Latency)
                Passed   = ([string]$result.Result -match 'Success')
                Error    = [string]$result.Error
            }) | Out-Null
        }
    }

    $replArr = @($replicationRows.ToArray())
    $mapiArr = @($mapiRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'mailbox/replication-health.json' -ContentObject ([ordered]@{
        replicationChecks = $replArr
        mapiConnectivity  = $mapiArr
        mapiNotTested     = @($mapiNotTested.ToArray())
        dagMembers        = $members
        errors            = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'mailbox.replication-health' -Title 'Replication Health Checks' -Area 'Mailbox' `
            -Columns @('Server', 'Check', 'Result', 'Passed', 'Error') -Rows $replArr -HighCardinality

        New-ExchInventorySection -Run $Run -Key 'mailbox.mapi-connectivity' -Title 'MAPI Connectivity' -Area 'Mailbox' `
            -Columns @('Database', 'Server', 'Result', 'Latency', 'Passed', 'Error') -Rows $mapiArr
    )

    if ($members.Count -eq 0 -and $mapiArr.Count -eq 0) {
        $reason = if ($errors.Count -gt 0) {
            "Neither replication health nor MAPI connectivity could be tested: $($errors -join '; ')"
        }
        else {
            'There are no DAG members and no mounted databases answered a MAPI connectivity test, so there was nothing to probe.'
        }
        return New-ExchCollectorResult -Sections $sections -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason -Severity 'Medium' `
                -Remediation 'Run from an Exchange Management Shell with rights to run Test-ReplicationHealth and Test-MAPIConnectivity.'
        )
    }

    $failedChecks = @($replArr | Where-Object { -not $_.Passed })
    $failedMapi   = @($mapiArr | Where-Object { -not $_.Passed })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($failedChecks.Count -gt 0) {
        $byServer = $failedChecks | Group-Object Server | ForEach-Object {
            "{0}: {1}" -f $_.Name, (($_.Group | ForEach-Object { "$($_.Check)=$($_.Result)" }) -join ', ')
        }
        $problems.Add(("{0} replication health checks failed across {1} DAG members - {2}" -f `
            $failedChecks.Count, @($failedChecks | ForEach-Object { $_.Server } | Sort-Object -Unique).Count, ($byServer -join '; '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    if ($failedMapi.Count -gt 0) {
        $problems.Add(("{0} mounted databases did not answer a MAPI connectivity test, so clients cannot reach them: {1}" -f `
            $failedMapi.Count, (($failedMapi | ForEach-Object { "$($_.Database) on $($_.Server)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    if ($mapiNotTested.Count -gt 0) {
        $problems.Add(("{0} databases returned no status from their Information Store, so MAPI connectivity was not tested on them: {1}" -f `
            $mapiNotTested.Count, ($mapiNotTested -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($errors.Count -gt 0) {
        $problems.Add(("Some probes could not be run: {0}" -f ($errors -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant' { 'High' }
        'Unknown'      { 'Medium' }
        default        { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else { ("All {0} replication health checks across {1} DAG members passed, and {2} mounted databases answered MAPI connectivity tests." -f `
                        $replArr.Count, $members.Count, $mapiArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0 -or $mapiNotTested.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Work each failing replication check on the server that reported it, starting with cluster and quorum checks, then log replay and content index. A database that fails MAPI connectivity is not serving clients and takes priority over everything else here.' `
        -Metrics @{
            dagMembers        = $members.Count
            checksRun         = $replArr.Count
            checksFailed      = $failedChecks.Count
            databasesProbed   = $mapiArr.Count
            databasesNotTested = $mapiNotTested.Count
            mapiFailures      = $failedMapi.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

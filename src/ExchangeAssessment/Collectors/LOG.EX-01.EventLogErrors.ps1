<#
LOG.EX-01 - Recent Exchange-related event log errors.

Counts and groups rather than failing on the first event. A healthy Exchange organisation
produces some error events; what matters is volume and repetition, so the thresholds and the
known-noise event IDs live in configuration.

Local host only. The finding says so, rather than implying the whole organisation was checked.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_LOG_EX_01_EventLogErrors {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'LOG.EX-01'

    $hoursBack   = [int](Get-ExchThreshold -Run $Run -Name 'EventLog.HoursBack' -Default 24)
    $maxEvents   = [int](Get-ExchThreshold -Run $Run -Name 'EventLog.MaxEvents' -Default 500)
    $providers   = @(Get-ExchThreshold -Run $Run -Name 'EventLog.Providers' -Default @('MSExchange*'))
    $noiseIds    = @(Get-ExchThreshold -Run $Run -Name 'EventLog.NoiseEventIds' -Default @())
    $warnCount   = [int](Get-ExchThreshold -Run $Run -Name 'EventLog.ErrorCountWarning'  -Default 1)
    $critCount   = [int](Get-ExchThreshold -Run $Run -Name 'EventLog.ErrorCountCritical' -Default 25)

    $events = @()
    try {
        $filter = @{ LogName = @('Application', 'System'); Level = 1, 2; StartTime = (Get-Date).AddHours(-$hoursBack) }
        $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $maxEvents -ErrorAction Stop)
    }
    catch {
        # Get-WinEvent throws when the filter matches nothing, which is a clean result, not a failure.
        if ($_.Exception.Message -match 'No events were found') { $events = @() }
        else {
            $null = Write-ExchError -Run $Run -Context 'Get-WinEvent Application/System' -ErrorRecord $_ -ControlId $control.controlId
            $reason = "The Application and System event logs could not be queried on $($env:COMPUTERNAME): $($_.Exception.Message)"
            return New-ExchCollectorResult -Findings @(
                New-ExchUnavailableFinding -Control $control -Reason $reason -DataSource 'Events' `
                    -Remediation 'Run the assessment with local administrative rights on the Exchange server so the event logs can be read.'
            )
        }
    }

    $matched = New-Object System.Collections.Generic.List[object]
    # Not $event: that is a PowerShell automatic variable, and assigning to it is both a lint
    # failure and a real hazard inside an event-handling scope.
    foreach ($logEntry in $events) {
        $provider = [string]$logEntry.ProviderName
        $isExchange = $false
        foreach ($pattern in $providers) {
            if ($provider -like $pattern) { $isExchange = $true; break }
        }
        if (-not $isExchange) { continue }

        $message = [string]$logEntry.Message
        if ($message.Length -gt 1024) { $message = $message.Substring(0, 1024) }

        $matched.Add([pscustomobject]@{
            TimeCreated = $logEntry.TimeCreated
            Level       = [string]$logEntry.LevelDisplayName
            EventId     = [int]$logEntry.Id
            Provider    = $provider
            Log         = [string]$logEntry.LogName
            Machine     = [string]$logEntry.MachineName
            IsKnownNoise= ($noiseIds -contains [int]$logEntry.Id)
            Message     = $message
        }) | Out-Null
    }

    $all         = @($matched.ToArray())
    $significant = @($all | Where-Object { -not $_.IsKnownNoise })

    $grouped = $significant | Group-Object -Property Provider, EventId | ForEach-Object {
        $first = $_.Group | Select-Object -First 1
        [pscustomobject]@{
            Provider  = $first.Provider
            EventId   = $first.EventId
            Level     = $first.Level
            Count     = $_.Count
            FirstSeen = ($_.Group | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated
            LastSeen  = ($_.Group | Sort-Object TimeCreated | Select-Object -Last 1).TimeCreated
            Message   = $first.Message
        }
    }
    $groupedArr = @($grouped | Sort-Object -Property Count -Descending)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'logs/exchange-event-errors.json' -ContentObject ([ordered]@{
        host        = [string]$env:COMPUTERNAME
        windowHours = $hoursBack
        events      = $all
        grouped     = $groupedArr
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'monitoring.event-summary' -Title 'Exchange Event Errors by Provider and Id' -Area 'Monitoring' `
            -Columns @('Provider', 'EventId', 'Level', 'Count', 'FirstSeen', 'LastSeen', 'Message') `
            -Rows $groupedArr

        New-ExchInventorySection -Run $Run -Key 'monitoring.events' -Title 'Exchange Event Errors' -Area 'Monitoring' `
            -Columns @('TimeCreated', 'Level', 'EventId', 'Provider', 'Log', 'Machine', 'IsKnownNoise', 'Message') `
            -Rows $all -HighCardinality
    )

    $total = $significant.Count
    $distinct = $groupedArr.Count
    $truncated = ($events.Count -ge $maxEvents)

    $outcome = 'Compliant'
    $severity = 'Low'
    $rationale = ("No significant Exchange-related error or critical events were logged on {0} in the last {1} hours." -f $env:COMPUTERNAME, $hoursBack)

    if ($total -ge $critCount) {
        $outcome = 'NonCompliant'
        $severity = 'High'
        $rationale = ("{0} Exchange-related error or critical events across {1} distinct provider/event-id pairs were logged on {2} in the last {3} hours, at or above the critical threshold of {4}. Most frequent: {5}." -f `
            $total, $distinct, $env:COMPUTERNAME, $hoursBack, $critCount, `
            ((($groupedArr | Select-Object -First 3) | ForEach-Object { "$($_.Provider) id $($_.EventId) x$($_.Count)" }) -join ', '))
    }
    elseif ($total -ge $warnCount) {
        $outcome = 'PartiallyCompliant'
        $severity = 'Medium'
        $rationale = ("{0} Exchange-related error or critical events across {1} distinct provider/event-id pairs were logged on {2} in the last {3} hours. Most frequent: {4}." -f `
            $total, $distinct, $env:COMPUTERNAME, $hoursBack, `
            ((($groupedArr | Select-Object -First 3) | ForEach-Object { "$($_.Provider) id $($_.EventId) x$($_.Count)" }) -join ', '))
    }

    if ($truncated) {
        $rationale += (" The event query hit its cap of {0} events, so the true count may be higher." -f $maxEvents)
    }
    $rationale += ' Only the local host was examined.'

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($truncated) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Work through the most frequent provider and event-id pairs first; recurring errors from the same component usually share one root cause. Add genuinely benign event ids to EventLog.NoiseEventIds in the threshold configuration so they stop counting.' `
        -Metrics @{
            host              = [string]$env:COMPUTERNAME
            windowHours       = $hoursBack
            significantEvents = $total
            distinctPairs     = $distinct
            noiseFiltered     = ($all.Count - $total)
            queryTruncated    = $truncated
        } `
        -Meta @{ dataSources = @{ Events = @{ state = 'Success'; reason = 'Local host only' } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

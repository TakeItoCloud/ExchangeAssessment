<#
TR.QUE-01 - Transport queue depth and age, across every transport server.

Get-Queue with no -Server qualifier implies the local server, so a single call reports one
server's backlog while the rationale reads as if it covered the organisation. The transport
servers are therefore enumerated and each one is queried by name; a server that could not be
queried is named in the finding and makes the control SoftFail, because partial coverage must
never read as clean.

Get-QueueDigest is deliberately not used instead: it only returns queues holding ten or more
messages, its data is one to two minutes old, it excludes subscribed Edge Transport servers, and
it does not carry the retry age or LastError this control reports.

A point-in-time read. A queue with a few messages in it is normal; a queue that is deep, old, or
in Retry is mail that is not being delivered right now. The finding says explicitly that this is
one sample, because a queue that is draining looks the same as one that is stuck if you only
look once.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_TR_QUE_01_TransportQueue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'TR.QUE-01'

    $errors = New-Object System.Collections.Generic.List[string]

    # Scope first. Without this the collector reports the local server's queues and calls them
    # the organisation's.
    $transportServers = @(Invoke-ExchQuery -Label 'Get-TransportService' -Errors $errors -Run $Run -ControlId $control.controlId `
        -Script { Get-TransportService -ErrorAction Stop })

    if ($transportServers.Count -eq 0) {
        $reason = if ($errors.Count -gt 0) {
            "The transport servers could not be enumerated, so no queue could be attributed to a server and mail flow backlog was not assessed: {0}" -f ($errors -join '; ')
        }
        else {
            'Get-TransportService returned no servers, so there was no transport server whose queues could be read.'
        }
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Severity 'Medium' -Reason $reason `
                -Remediation 'Run from an Exchange Management Shell with rights to read the transport service and its queues on each Exchange server.'
        )
    }

    $queried   = New-Object System.Collections.Generic.List[string]
    $answered  = New-Object System.Collections.Generic.List[string]
    $unreached = New-Object System.Collections.Generic.List[string]
    $queues    = New-Object System.Collections.Generic.List[object]

    foreach ($service in $transportServers) {
        $serverName = [string](Get-ExchObjectValue -InputObject $service -Name 'Name' -Default '')
        if (-not $serverName) { $serverName = [string](Get-ExchObjectValue -InputObject $service -Name 'Identity' -Default '') }
        if (-not $serverName) {
            $errors.Add('A transport service entry carried no server name, so its queues could not be read.') | Out-Null
            continue
        }

        $queried.Add($serverName) | Out-Null
        $before = $errors.Count
        $serverQueues = @(Invoke-ExchQuery -Label ("Get-Queue on {0}" -f $serverName) -Errors $errors -Run $Run -ControlId $control.controlId `
            -Script { Get-Queue -Server $serverName -ErrorAction Stop })

        if ($errors.Count -gt $before) { $unreached.Add($serverName) | Out-Null; continue }

        $answered.Add($serverName) | Out-Null
        foreach ($queue in $serverQueues) {
            $queues.Add([pscustomobject]@{ Server = $serverName; Queue = $queue }) | Out-Null
        }
    }

    if ($answered.Count -eq 0) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Severity 'Medium' `
                -Reason ("None of the {0} transport servers returned queue data, so mail flow backlog was not assessed: {1}" -f $queried.Count, ($errors -join '; ')) `
                -Remediation 'Run from an Exchange Management Shell with rights to read queues on each transport server.'
        )
    }

    $warnDepth   = [int](Get-ExchThreshold -Run $Run -Name 'Transport.QueueLengthWarning'  -Default 100)
    $critDepth   = [int](Get-ExchThreshold -Run $Run -Name 'Transport.QueueLengthCritical' -Default 500)
    $maxAgeHours = [double](Get-ExchThreshold -Run $Run -Name 'Transport.MaxQueueAgeHours' -Default 4)
    $now = Get-Date

    $rows = foreach ($entry in $queues) {
        $q = $entry.Queue
        $lastRetry = Get-ExchObjectValue -InputObject $q -Name 'LastRetryTime'
        $ageHours = $null
        try {
            if ($lastRetry) { $ageHours = [math]::Round(($now - [datetime]$lastRetry).TotalHours, 2) }
        }
        catch { $ageHours = $null }

        [pscustomobject]@{
            Server          = $entry.Server
            Identity        = [string](Get-ExchObjectValue -InputObject $q -Name 'Identity' -Default '')
            DeliveryType    = [string](Get-ExchObjectValue -InputObject $q -Name 'DeliveryType' -Default '')
            Status          = [string](Get-ExchObjectValue -InputObject $q -Name 'Status' -Default '')
            MessageCount    = [int](Get-ExchObjectValue -InputObject $q -Name 'MessageCount' -Default 0)
            NextHopDomain   = [string](Get-ExchObjectValue -InputObject $q -Name 'NextHopDomain' -Default '')
            LastError       = (Get-ExchTruncatedText -Text ([string](Get-ExchObjectValue -InputObject $q -Name 'LastError' -Default '')) -Length 300)
            LastRetryTime   = $lastRetry
            RetryAgeHours   = $ageHours
            IsValid         = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $q -Name 'IsValid'))
        }
    }
    $queueArr = @($rows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'transport/queues.json' -ContentObject ([ordered]@{
        sampledUtc       = (Get-Date).ToUniversalTime().ToString('o')
        serversQueried   = @($queried.ToArray())
        serversAnswered  = @($answered.ToArray())
        serversUnreached = @($unreached.ToArray())
        queues           = $queueArr
        errors           = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'transport.queues' -Title 'Transport Queues' -Area 'Transport' `
            -Columns @('Server', 'Identity', 'DeliveryType', 'Status', 'MessageCount', 'NextHopDomain', 'RetryAgeHours', 'LastRetryTime', 'LastError', 'IsValid') `
            -Rows $queueArr -HighCardinality
    )

    # Poison and Submission always exist and are not backlogs in themselves.
    $delivery = @($queueArr | Where-Object { $_.Identity -notmatch 'Poison$|Submission$' })
    $deep     = @($delivery | Where-Object { $_.MessageCount -gt $critDepth })
    $growing  = @($delivery | Where-Object { $_.MessageCount -gt $warnDepth -and $_.MessageCount -le $critDepth })
    $retrying = @($delivery | Where-Object { $_.Status -match 'Retry' })
    $suspended= @($delivery | Where-Object { $_.Status -match 'Suspended' })
    $stale    = @($delivery | Where-Object { $null -ne $_.RetryAgeHours -and $_.RetryAgeHours -gt $maxAgeHours })
    $poison   = @($queueArr | Where-Object { $_.Identity -match 'Poison$' -and $_.MessageCount -gt 0 })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($deep.Count -gt 0) {
        $problems.Add(("{0} queues hold more than {1} messages: {2}" -f $deep.Count, $critDepth, `
            (($deep | ForEach-Object { "{0}={1}" -f (Get-ExchQueueLabel -Row $_), $_.MessageCount }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($retrying.Count -gt 0) {
        $problems.Add(("{0} queues are in Retry, so mail to those destinations is not being delivered: {1}" -f $retrying.Count, `
            (($retrying | ForEach-Object { "{0} -> {1} ({2} msgs)" -f (Get-ExchQueueLabel -Row $_), $_.NextHopDomain, $_.MessageCount }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($suspended.Count -gt 0) {
        $problems.Add(("{0} queues are Suspended and will not drain until resumed: {1}" -f $suspended.Count, `
            (($suspended | ForEach-Object { Get-ExchQueueLabel -Row $_ }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($poison.Count -gt 0) {
        $problems.Add(("The poison message queue holds {0} messages, which are blocked and need manual review" -f `
            (($poison | Measure-Object -Property MessageCount -Sum).Sum))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($stale.Count -gt 0) {
        $problems.Add(("{0} queues last retried more than {1} hours ago" -f $stale.Count, $maxAgeHours)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($growing.Count -gt 0) {
        $problems.Add(("{0} queues hold more than {1} messages" -f $growing.Count, $warnDepth)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($unreached.Count -gt 0) {
        $problems.Add(("{0} of {1} transport servers did not return their queues, so their backlog is unknown: {2}" -f `
            $unreached.Count, $queried.Count, (($unreached.ToArray()) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif ($errors.Count -gt 0) {
        $problems.Add(("Some queue data could not be read: {0}" -f ($errors -join '; '))) | Out-Null
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

    $total = ($queueArr | Measure-Object -Property MessageCount -Sum).Sum
    $scope = "{0} of {1} transport servers returned queue data ({2})." -f $answered.Count, $queried.Count, (($answered.ToArray()) -join ', ')
    $rationale = if ($problems.Count -gt 0) { $scope + ' ' + ($problems -join '. ') + '.' }
                 else { "{0} {1} queues hold {2} messages in total, none in Retry or Suspended." -f $scope, $queueArr.Count, $total }
    $rationale += ' This is a single sample: a queue that is draining and one that is stuck look the same from one reading.'

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0 -or $unreached.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Work the queues in Retry first - the LastError column names the reason, usually DNS, a smart host, or a remote server refusing the connection. Resume suspended queues once the cause is understood, and review the poison queue by hand.' `
        -Metrics @{
            serversQueried  = $queried.Count
            serversAnswered = $answered.Count
            queueCount      = $queueArr.Count
            totalMessages   = $total
            deepQueues      = $deep.Count
            retryingQueues  = $retrying.Count
            suspendedQueues = $suspended.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0 -or $unreached.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchQueueLabel {
    <#
    Names a queue for the rationale, server first.

    Get-Queue already returns an identity of the form <Server>\<queue>, so the server is only
    prefixed when it is not there already - which keeps the label right whether the identity
    came back qualified or not.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Row)

    $server   = [string](Get-ExchObjectValue -InputObject $Row -Name 'Server' -Default '')
    $identity = [string](Get-ExchObjectValue -InputObject $Row -Name 'Identity' -Default '')

    if (-not $server) { return $identity }
    if (-not $identity) { return $server }
    if ($identity.StartsWith(($server + '\'), [System.StringComparison]::OrdinalIgnoreCase)) { return $identity }

    return ('{0}\{1}' -f $server, $identity)
}

<#
TR.QUE-01 - Transport queue depth and age.

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
    $queues = @(Invoke-ExchQuery -Label 'Get-Queue' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-Queue -ErrorAction Stop })

    if ($queues.Count -eq 0 -and $errors.Count -gt 0) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Severity 'Medium' `
                -Reason ("Transport queues could not be read, so mail flow backlog was not assessed: {0}" -f ($errors -join '; ')) `
                -Remediation 'Run from an Exchange Management Shell on a server holding the Transport service, with rights to read queues.'
        )
    }

    $warnDepth   = [int](Get-ExchThreshold -Run $Run -Name 'Transport.QueueLengthWarning'  -Default 100)
    $critDepth   = [int](Get-ExchThreshold -Run $Run -Name 'Transport.QueueLengthCritical' -Default 500)
    $maxAgeHours = [double](Get-ExchThreshold -Run $Run -Name 'Transport.MaxQueueAgeHours' -Default 4)
    $now = Get-Date

    $rows = foreach ($q in $queues) {
        $ageHours = $null
        try {
            if ($q.LastRetryTime) { $ageHours = [math]::Round(($now - [datetime]$q.LastRetryTime).TotalHours, 2) }
        }
        catch { $ageHours = $null }

        [pscustomobject]@{
            Identity        = [string]$q.Identity
            DeliveryType    = [string]$q.DeliveryType
            Status          = [string]$q.Status
            MessageCount    = [int]$q.MessageCount
            NextHopDomain   = [string]$q.NextHopDomain
            LastError       = (Get-ExchTruncatedText -Text ([string]$q.LastError) -Length 300)
            LastRetryTime   = $q.LastRetryTime
            RetryAgeHours   = $ageHours
            IsValid         = (ConvertTo-ExchFlatValue -Value $q.IsValid)
        }
    }
    $queueArr = @($rows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'transport/queues.json' -ContentObject ([ordered]@{
        sampledUtc = (Get-Date).ToUniversalTime().ToString('o')
        queues     = $queueArr
        errors     = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'transport.queues' -Title 'Transport Queues' -Area 'Transport' `
            -Columns @('Identity', 'DeliveryType', 'Status', 'MessageCount', 'NextHopDomain', 'RetryAgeHours', 'LastRetryTime', 'LastError', 'IsValid') `
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
            (($deep | ForEach-Object { "$($_.Identity)=$($_.MessageCount)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($retrying.Count -gt 0) {
        $problems.Add(("{0} queues are in Retry, so mail to those destinations is not being delivered: {1}" -f $retrying.Count, `
            (($retrying | ForEach-Object { "$($_.NextHopDomain) ($($_.MessageCount) msgs)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($suspended.Count -gt 0) {
        $problems.Add(("{0} queues are Suspended and will not drain until resumed: {1}" -f $suspended.Count, `
            (($suspended | ForEach-Object { $_.Identity }) -join ', '))) | Out-Null
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
    if ($errors.Count -gt 0) {
        $problems.Add(("Some queues could not be read: {0}" -f ($errors -join '; '))) | Out-Null
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
    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else { ("{0} queues hold {1} messages in total, none in Retry or Suspended." -f $queueArr.Count, $total) }
    $rationale += ' This is a single sample: a queue that is draining and one that is stuck look the same from one reading.'

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Work the queues in Retry first - the LastError column names the reason, usually DNS, a smart host, or a remote server refusing the connection. Resume suspended queues once the cause is understood, and review the poison queue by hand.' `
        -Metrics @{
            queueCount     = $queueArr.Count
            totalMessages  = $total
            deepQueues     = $deep.Count
            retryingQueues = $retrying.Count
            suspendedQueues= $suspended.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

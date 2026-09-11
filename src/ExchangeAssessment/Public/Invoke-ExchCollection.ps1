<#
Runs the collectors named in the registry, in dependency order.

Returns everything the reports need: the inventory sections, the findings, and an honest record
of which collectors ran, which were skipped and which failed. A collector that throws does not
stop the run, but it is never silently lost either - the full error detail goes to the log, and
the control becomes an Unknown/HardFail finding naming the failure, so a gap in the assessment
is visible in the output rather than only in the log.

Two sections are added by the run itself: one row per collector with its status and duration,
and one row per error recorded anywhere in the run.
#>

function Invoke-ExchCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][switch]$SkipDomainQueries,
        # Mailbox inventory enumerates every mailbox, which is the one collector whose cost
        # scales with the size of the organisation.
        [Parameter()][switch]$SkipMailboxInventory,
        # DNS lookups leave the network. Some assessments are run where that is not allowed.
        [Parameter()][switch]$SkipDnsQueries,
        # The greenfield deployment checks contact the servers named in the deployment config,
        # which are not Exchange servers yet. Skip them where that contact is not wanted.
        [Parameter()][switch]$SkipDeploymentChecks
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $findings = New-Object System.Collections.Generic.List[object]
    $sections = New-Object System.Collections.Generic.List[object]
    $ran      = New-Object System.Collections.Generic.List[string]
    $skipped  = New-Object System.Collections.Generic.List[string]
    $failed   = New-Object System.Collections.Generic.List[object]
    $status   = New-Object System.Collections.Generic.List[object]
    $results  = @{}

    $skipFlags = @{
        SkipDomainQueries    = [bool]$SkipDomainQueries.IsPresent
        SkipMailboxInventory = [bool]$SkipMailboxInventory.IsPresent
        SkipDnsQueries       = [bool]$SkipDnsQueries.IsPresent
        SkipDeploymentChecks = [bool]$SkipDeploymentChecks.IsPresent
    }
    $includeCloud = Get-ExchRunFlag -Run $Run -Name 'IncludeExchangeOnline'

    try { Assert-ExchLocalShell -Run $Run }
    catch { $null = Write-ExchError -Run $Run -Context 'Exchange Management Shell detection' -ErrorRecord $_ }

    $registry = Get-ExchCollectorOrder
    Write-ExchEvent -Run $Run -Level INFO -Message 'Collection started' -Data @{ collectors = @($registry).Count }

    # Connect to the tenant once, before any cloud collector runs. A failure here is reported by
    # each cloud control rather than stopping the on-premises assessment.
    $cloudConnected = $false
    if ($includeCloud) {
        $Run.Cloud = Connect-ExchOnlineSession -Run $Run
        $cloudConnected = [bool]$Run.Cloud.Connected
    }

    foreach ($entry in $registry) {

        if ($entry.SkipFlag -and $skipFlags.ContainsKey($entry.SkipFlag) -and $skipFlags[$entry.SkipFlag]) {
            $skipped.Add($entry.Id) | Out-Null
            $status.Add((New-ExchCollectorStatusRow -Entry $entry -Status 'Skipped' -Detail $entry.SkipFlag)) | Out-Null
            Write-ExchEvent -Run $Run -Level WARN -Message 'Collector skipped' -Data @{ controlId = $entry.Id; reason = $entry.SkipFlag }
            continue
        }

        if ($entry.Cloud -and -not $includeCloud) {
            $skipped.Add($entry.Id) | Out-Null
            $status.Add((New-ExchCollectorStatusRow -Entry $entry -Status 'Skipped' -Detail 'Exchange Online not requested')) | Out-Null
            Write-ExchEvent -Run $Run -Level INFO -Message 'Collector skipped' -Data @{ controlId = $entry.Id; reason = 'Exchange Online not requested' }
            continue
        }

        $started = Get-Date
        Write-ExchEvent -Run $Run -Level DEBUG -Message 'Collector started' -Data @{ controlId = $entry.Id; function = $entry.Function }

        try {
            $arguments = @{ Run = $Run }
            if (@($entry.Requires).Count -gt 0) {
                $upstream = @{}
                foreach ($req in @($entry.Requires)) {
                    if ($results.ContainsKey($req)) { $upstream[$req] = $results[$req] }
                }
                $arguments['Upstream'] = $upstream
            }

            $raw = & $entry.Function @arguments
            $result = ConvertTo-ExchCollectorResult -InputObject $raw

            $results[$entry.Id] = $result
            foreach ($s in $result.sections) { $sections.Add($s) | Out-Null }
            foreach ($f in $result.findings) { $findings.Add($f) | Out-Null }
            $ran.Add($entry.Id) | Out-Null

            $seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 2)
            $status.Add((New-ExchCollectorStatusRow -Entry $entry -Status 'Ran' -Seconds $seconds `
                -Detail ("{0} sections, {1} findings" -f @($result.sections).Count, @($result.findings).Count))) | Out-Null

            Write-ExchEvent -Run $Run -Level INFO -Message 'Collector finished' -Data @{
                controlId = $entry.Id
                seconds   = $seconds
                sections  = @($result.sections).Count
                findings  = @($result.findings).Count
            }
        }
        catch {
            $seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 2)
            $record = Write-ExchError -Run $Run -Context ("{0} collector" -f $entry.Id) -ErrorRecord $_ -ControlId $entry.Id `
                -Data @{ function = $entry.Function; seconds = $seconds }

            $message = [string]$_.Exception.Message
            $failed.Add([pscustomobject]@{ controlId = $entry.Id; error = $message }) | Out-Null
            $status.Add((New-ExchCollectorStatusRow -Entry $entry -Status 'Failed' -Seconds $seconds -Detail $message)) | Out-Null

            # A collector that fell over is a gap in the assessment, and the report has to say so.
            $findings.Add((New-ExchCollectorFailureFinding -ControlId $entry.Id -Area $entry.Area -Message $message -Detail $record.detail)) | Out-Null
        }
    }

    $statusArr = @($status.ToArray())
    $sections.Add((New-ExchInventorySection -Run $Run -Key 'run.collectors' -Title 'Collector Run Status' -Area 'Run' `
        -Columns @('ControlId', 'Area', 'Status', 'Seconds', 'Detail') -Rows $statusArr)) | Out-Null

    $errorRows = @(Get-ExchRunErrorRow -Run $Run)
    $sections.Add((New-ExchInventorySection -Run $Run -Key 'run.errors' -Title 'Errors Recorded During the Run' -Area 'Run' `
        -Columns @('TimestampUtc', 'ControlId', 'Context', 'Severity', 'ExceptionType', 'Message', 'ScriptName', 'LineNumber', 'FullyQualifiedErrorId', 'InnerExceptions') `
        -Rows $errorRows -HighCardinality)) | Out-Null

    if ($cloudConnected) { Disconnect-ExchOnlineSession -Run $Run }

    Write-ExchEvent -Run $Run -Level INFO -Message 'Collection finished' -Data @{
        ran = $ran.Count; skipped = $skipped.Count; failed = $failed.Count; errors = @($errorRows).Count
    }

    [pscustomobject]@{
        Findings = $findings.ToArray()
        Sections = $sections.ToArray()
        Ran      = $ran.ToArray()
        Skipped  = $skipped.ToArray()
        Failed   = $failed.ToArray()
        Status   = $statusArr
        Errors   = $errorRows
    }
}

function New-ExchCollectorStatusRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][ValidateSet('Ran', 'Skipped', 'Failed')][string]$Status,
        [Parameter()][double]$Seconds = 0,
        [Parameter()][string]$Detail = ''
    )

    [pscustomobject]@{
        ControlId = [string]$Entry.Id
        Area      = [string]$Entry.Area
        Status    = $Status
        Seconds   = $Seconds
        Detail    = $Detail
    }
}

function Get-ExchRunErrorRow {
    <#
    Flattens the run's error list into report rows. Everything needed to diagnose a failure
    without re-running the assessment is here; the untruncated detail stays in run.jsonl.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $list = Get-ExchRunErrorList -Run $Run
    if ($null -eq $list) { return @() }

    foreach ($record in $list) {
        $detail = $record.detail
        [pscustomobject]@{
            TimestampUtc          = $record.timestampUtc
            ControlId             = $record.controlId
            Context               = $record.context
            Severity              = $record.severity
            ExceptionType         = $(if ($detail) { $detail.exceptionType } else { '' })
            Message               = $(if ($detail) { $detail.message } else { '' })
            ScriptName            = $(if ($detail) { Split-Path -Path ([string]$detail.scriptName) -Leaf } else { '' })
            LineNumber            = $(if ($detail) { $detail.lineNumber } else { 0 })
            FullyQualifiedErrorId = $(if ($detail) { $detail.fullyQualifiedErrorId } else { '' })
            InnerExceptions       = $(if ($detail) { (@($detail.innerExceptions | ForEach-Object { "$($_.type): $($_.message)" }) -join ' | ') } else { '' })
        }
    }
}

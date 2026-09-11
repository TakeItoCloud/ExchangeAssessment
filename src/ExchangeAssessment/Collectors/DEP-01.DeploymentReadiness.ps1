<#
DEP-01 - Greenfield deployment readiness roll-up.

The greenfield counterpart of UPG-01, in its shape: it measures nothing itself, reads the finding
each upstream control produced, keeps one row per prerequisite with the upstream rationale as the
detail, and turns them into one verdict. Invoke-ExchCollection hands it the results of the controls
its registry row names in Requires:

  ENV.VERS-01  the directory-side prerequisites - forest and domain functional levels, the Exchange
               schema and Active Directory preparation, and the Schema Master. DEP-01 does not
               re-derive any of them; it reads ENV.VERS-01's finding.
  DEP.TGT-01   target server prerequisites
  DEP.NET-01   network reachability, probed from each target server
  DEP.WIT-01   file share witness prerequisites
  DEP.NAME-01  the planned names are free
  DEP.VOL-01   database and log volumes

NOT REQUIRED, DELIBERATELY: EX.CH-01 and ENV.OS-01. UPG-01 requires both; this control must not. Both
read the servers Get-ExchangeServer returns, so both depend on an existing Exchange organisation -
which is precisely what a greenfield deployment does not have. Requiring them would make every
greenfield run report a missing Exchange organisation as a deployment prerequisite that could not be
assessed. The asymmetry with UPG-01 is the point; do not "fix" it.

Fail closed, and stricter than UPG-01. UPG-01 hands 'Unknown' for a missing upstream to
Get-ExchWorstOutcome, whose rule is that Unknown only wins when there is nothing else, so there a
Compliant outvotes an Unknown. Here any prerequisite that could not be assessed makes the verdict
Unknown by itself, and Get-ExchWorstOutcome only ever combines the outcomes of prerequisites that
were measured. A Compliant the upstream control itself marked as not fully sufficient - SoftFail or
HardFail, meaning part of what it covers was not assessed - is not counted as passed either.

A prerequisite that could not be assessed has one of these causes, each with its own message:

  DidNotRun   no result from the control reached DEP-01 - it was skipped (-SkipDomainQueries skips
              ENV.VERS-01) or it failed before returning a result; run.collectors.csv says which
  NoFinding   the control ran and returned no finding under its own control id
  Reported    the control ran and reported Unknown, or Compliant with a sufficiency other than Pass,
              and its own rationale is the cause

The rationale is written in three groups, always all three, an empty one written as a measured zero:
measured and passed; measured and did not pass; could not be assessed, with the cause of each. That
split is what a client readiness section is written from.

A Compliant DEP-01 means every prerequisite this tool checks was measured and met. It does not mean
Exchange Setup will succeed: Setup runs its own readiness checks, and this tool checks only what its
controls name.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_DEP_01_DeploymentReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][hashtable]$Upstream = @{}
    )

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'DEP-01'
    $prerequisites = @(Get-ExchDeploymentReadinessPrerequisite)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($prereq in $prerequisites) {
        $rows.Add((Resolve-ExchReadinessPrerequisite -Upstream $Upstream -Prerequisite $prereq)) | Out-Null
    }
    $rowArr = @($rows.ToArray())

    $passed      = @($rowArr | Where-Object { $_.Group -eq 'Passed' })
    $notPassed   = @($rowArr | Where-Object { $_.Group -eq 'NotPassed' })
    $notAssessed = @($rowArr | Where-Object { $_.Group -eq 'NotAssessed' })

    # Fail closed. Get-ExchWorstOutcome lets a Compliant outvote an Unknown - "Unknown only wins when
    # there is nothing else" - so it never sees a prerequisite that was not assessed: one of those
    # makes the verdict Unknown on its own, and only the outcomes that were measured are combined.
    if ($notAssessed.Count -gt 0) {
        $outcome = 'Unknown'
    }
    else {
        $measured = @(@($passed) + @($notPassed))
        $outcome = Get-ExchWorstOutcome -Outcomes @($measured | ForEach-Object { [string]$_.Outcome })
    }

    $gap = Get-ExchDeploymentConfigGap -Deployment (Get-ExchThreshold -Run $Run -Name 'Deployment')
    $severity = if (-not $gap.Supplied) { 'Info' }
                elseif (@($notPassed | Where-Object { $_.Outcome -eq 'NonCompliant' }).Count -gt 0) { 'High' }
                elseif ($outcome -eq 'Compliant') { 'Low' }
                else { 'Medium' }

    $sufficiency = if (($passed.Count + $notPassed.Count) -eq 0) { 'HardFail' }
                   elseif ($notAssessed.Count -gt 0) { 'SoftFail' }
                   else { 'Pass' }

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'deployment/deployment-readiness.json' -ContentObject $rowArr

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'deployment.readiness' -Title 'Greenfield Deployment Readiness' -Area 'Deployment' `
            -Columns @('Prerequisite', 'ControlId', 'Status', 'Outcome', 'Sufficiency', 'Severity', 'Group', 'Cause') `
            -Rows $rowArr
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add(('Greenfield deployment readiness, rolled up from the {0} controls DEP-01 requires ({1}); DEP-01 measures nothing itself. Verdict {2}: {3} measured and passed, {4} measured and did not pass, {5} could not be assessed' -f `
        $prerequisites.Count, (($prerequisites | ForEach-Object { $_.Key }) -join ', '), $outcome, $passed.Count, $notPassed.Count, $notAssessed.Count)) | Out-Null
    $parts.Add((Format-ExchReadinessGroup -Label 'Measured and passed' -Rows $passed)) | Out-Null
    $parts.Add((Format-ExchReadinessGroup -Label 'Measured and did not pass' -Rows $notPassed -WithCause)) | Out-Null
    $parts.Add((Format-ExchReadinessGroup -Label 'Could not be assessed' -Rows $notAssessed -WithCause)) | Out-Null
    if (-not $gap.Supplied) {
        $parts.Add(('No deployment config was supplied, so the greenfield controls had nothing to assess; for an assessment of an existing organisation this is expected. {0}' -f `
            (Get-ExchDeploymentSupplyInstruction -Keys @(Get-ExchDeploymentKey)).TrimEnd('.'))) | Out-Null
    }
    $parts.Add('A Compliant verdict means every prerequisite this tool checks was measured and met; it does not mean Exchange Setup will succeed') | Out-Null
    $rationale = ($parts.ToArray() -join '. ') + '.'

    $unrun = @($rowArr | Where-Object { $_.Status -ne 'Reported' })

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome -Sufficiency $sufficiency `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Work through each control listed as not passed or not assessed, in its own finding: supply what the deployment config is missing, make the target servers and the witness reachable from the assessment host, and clear each failed prerequisite, then re-run. A Compliant verdict means every prerequisite this tool checks was measured and met; it does not mean Exchange Setup will succeed, because Setup runs its own readiness checks. https://learn.microsoft.com/exchange/plan-and-deploy/prerequisites' `
        -Metrics @{
            requires        = @($prerequisites | ForEach-Object { $_.Key })
            passed          = @($passed | ForEach-Object { $_.ControlId })
            notPassed       = @($notPassed | ForEach-Object { $_.ControlId })
            notAssessed     = @($notAssessed | ForEach-Object { $_.ControlId })
            notRun          = @($rowArr | Where-Object { $_.Status -eq 'DidNotRun' } | ForEach-Object { $_.ControlId })
            reportedUnknown = @($rowArr | Where-Object { $_.Status -eq 'Reported' -and $_.Outcome -eq 'Unknown' } | ForEach-Object { $_.ControlId })
            rows            = $rowArr
        } `
        -Meta @{ dataSources = @{ Collectors = @{ state = $(if ($unrun.Count -gt 0) { 'Partial' } else { 'Success' }); reason = (@($unrun | ForEach-Object { "$($_.ControlId): $($_.Status)" }) -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchDeploymentReadinessPrerequisite {
    <#
    The controls DEP-01 rolls up, in the order it reports them. The registry row's Requires names the
    same set, and a test holds the two to it.
    #>
    [CmdletBinding()]
    param()

    return @(
        @{ Key = 'ENV.VERS-01'; Name = 'Directory prerequisites: functional levels, Exchange schema and Active Directory preparation, Schema Master' }
        @{ Key = 'DEP.TGT-01';  Name = 'Target server prerequisites' }
        @{ Key = 'DEP.NET-01';  Name = 'Network reachability from each target server' }
        @{ Key = 'DEP.WIT-01';  Name = 'File share witness prerequisites' }
        @{ Key = 'DEP.NAME-01'; Name = 'Planned names are free' }
        @{ Key = 'DEP.VOL-01';  Name = 'Database and log volumes' }
    )
}

function Resolve-ExchReadinessPrerequisite {
    <#
    One prerequisite's row: whether its control reported, what it reported, and which of the three
    groups that puts it in. Only a Compliant with sufficiency Pass is Passed.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][hashtable]$Upstream = @{},
        [Parameter(Mandatory)][ValidateNotNull()]$Prerequisite
    )

    $id = [string]$Prerequisite.Key
    $row = [ordered]@{
        Prerequisite = [string]$Prerequisite.Name
        ControlId    = $id
        Status       = ''
        Outcome      = ''
        Sufficiency  = ''
        Severity     = ''
        Group        = 'NotAssessed'
        Cause        = ''
    }

    if (-not $Upstream -or -not $Upstream.ContainsKey($id) -or $null -eq $Upstream[$id]) {
        $row.Status = 'DidNotRun'
        $row.Cause = 'did not run: no result from it reached DEP-01, so nothing it covers was measured. It was skipped - -SkipDomainQueries skips ENV.VERS-01 - or it failed before returning a result; csv/run.collectors.csv records which, and csv/run.errors.csv the error'
        return [pscustomobject]$row
    }

    $finding = Get-ExchUpstreamFinding -Upstream $Upstream -ControlId $id
    if ($null -eq $finding) {
        $row.Status = 'NoFinding'
        $row.Cause = ('ran, but returned no finding under its own control id {0}, so there is no verdict to read' -f $id)
        return [pscustomobject]$row
    }

    $result = Get-ExchObjectValue -InputObject $finding -Name 'result'
    $outcome = [string](Get-ExchObjectValue -InputObject $result -Name 'outcome' -Default '')
    $sufficiency = [string](Get-ExchObjectValue -InputObject $result -Name 'sufficiency' -Default '')
    $rationale = ([string](Get-ExchObjectValue -InputObject $result -Name 'rationale' -Default '')).Trim().TrimEnd('.')
    if (-not $rationale) { $rationale = 'it gave no rationale' }

    $row.Status = 'Reported'
    $row.Outcome = $outcome
    $row.Sufficiency = $sufficiency
    $row.Severity = [string](Get-ExchObjectValue -InputObject $finding -Name 'severity' -Default '')

    switch ($outcome) {
        'Compliant' {
            if ($sufficiency -eq 'Pass') {
                $row.Group = 'Passed'
                $row.Cause = ('ran and reported Compliant: {0}' -f $rationale)
            }
            else {
                $label = if ($sufficiency) { "'$sufficiency'" } else { 'not recorded' }
                $row.Cause = ('ran and reported Compliant, but with sufficiency {0} - it marked part of what it covers as not assessed, so it is not counted as passed: {1}' -f $label, $rationale)
            }
        }
        'NonCompliant'       { $row.Group = 'NotPassed'; $row.Cause = ('ran and reported NonCompliant: {0}' -f $rationale) }
        'PartiallyCompliant' { $row.Group = 'NotPassed'; $row.Cause = ('ran and reported PartiallyCompliant: {0}' -f $rationale) }
        'Unknown'            { $row.Cause = ('ran and reported Unknown: {0}' -f $rationale) }
        default              { $row.Cause = ("ran and reported an outcome DEP-01 does not recognise ('{0}'), so it is not counted as passed: {1}" -f $outcome, $rationale) }
    }

    return [pscustomobject]$row
}

function Format-ExchReadinessGroup {
    <#
    One of the three groups of the rationale. An empty group is written as '(0): none' - a measured
    zero - never left out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label,
        [Parameter()][object[]]$Rows = @(),
        [Parameter()][switch]$WithCause
    )

    $items = @(@($Rows) | Where-Object { $null -ne $_ } | ForEach-Object {
        $text = ('{0} ({1})' -f $_.ControlId, $_.Prerequisite)
        if ($WithCause) { $text = ('{0} - {1}' -f $text, ([string]$_.Cause).TrimEnd('.')) }
        $text
    })
    $body = if ($items.Count -gt 0) { $items -join ' | ' } else { 'none' }
    return ('{0} ({1}): {2}' -f $Label, $items.Count, $body)
}

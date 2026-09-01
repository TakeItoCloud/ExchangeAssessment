<#
UPG-01 - Exchange Server Subscription Edition readiness roll-up.

Reads the conclusions the environment collectors already reached rather than re-testing the
same thresholds a second time. Where an upstream control could not be evaluated, readiness for
that prerequisite is reported as unknown - a missing signal is never counted as a pass.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_UPG_01_SEReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][hashtable]$Upstream = @{}
    )

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'UPG-01'

    $prerequisites = @(
        @{ Key = 'ENV.VERS-01'; Name = 'Active Directory functional levels and Exchange preparation' }
        @{ Key = 'ENV.OS-01';   Name = 'Supported server operating system' }
        @{ Key = 'EX.CH-01';    Name = 'Supported Exchange product version and build' }
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $outcomes = New-Object System.Collections.Generic.List[string]
    $blockers = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($prereq in $prerequisites) {
        $finding = Get-ExchUpstreamFinding -Upstream $Upstream -ControlId $prereq.Key

        if ($null -eq $finding) {
            $missing.Add($prereq.Name) | Out-Null
            $outcomes.Add('Unknown') | Out-Null
            $rows.Add([pscustomobject]@{
                Prerequisite = $prereq.Name
                ControlId    = $prereq.Key
                Outcome      = 'Unknown'
                Severity     = ''
                Detail       = 'The upstream control did not report, so this prerequisite was not assessed.'
            }) | Out-Null
            continue
        }

        $outcome = [string]$finding.result.outcome
        $outcomes.Add($outcome) | Out-Null
        if ($outcome -eq 'NonCompliant') { $blockers.Add($prereq.Name) | Out-Null }

        $rows.Add([pscustomobject]@{
            Prerequisite = $prereq.Name
            ControlId    = $prereq.Key
            Outcome      = $outcome
            Severity     = [string]$finding.severity
            Detail       = [string]$finding.result.rationale
        }) | Out-Null
    }

    $rowArr = @($rows.ToArray())
    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'upgrade/se-readiness.json' -ContentObject $rowArr

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'upgrade.se-readiness' -Title 'Exchange SE Readiness' -Area 'Upgrade' `
            -Columns @('Prerequisite', 'ControlId', 'Outcome', 'Severity', 'Detail') `
            -Rows $rowArr
    )

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Medium' }
        'Unknown'            { 'Medium' }
        default              { 'Low' }
    }

    $parts = New-Object System.Collections.Generic.List[string]
    if ($blockers.Count -gt 0) { $parts.Add(("Blocked on: {0}" -f ($blockers -join ', '))) | Out-Null }
    if ($missing.Count -gt 0)  { $parts.Add(("Not assessed: {0}" -f ($missing -join ', '))) | Out-Null }

    $partial = @($rowArr | Where-Object { $_.Outcome -eq 'PartiallyCompliant' })
    if ($partial.Count -gt 0) {
        $parts.Add(("Needs work before upgrade: {0}" -f (($partial | ForEach-Object { $_.Prerequisite }) -join ', '))) | Out-Null
    }

    $rationale = if ($parts.Count -gt 0) { ($parts -join '. ') + '.' }
                 else { 'All assessed prerequisites for Exchange Server Subscription Edition are met.' }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($missing.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Clear each failing prerequisite in its own control before planning the Exchange SE upgrade. An in-place upgrade is supported only from Exchange 2019 CU14 or CU15; from Exchange 2016 a legacy side-by-side upgrade is required.' `
        -Metrics @{
            prerequisites = $rowArr.Count
            blockers      = @($blockers.ToArray())
            notAssessed   = @($missing.ToArray())
        } `
        -Meta @{ dataSources = @{ Collectors = @{ state = $(if ($missing.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($missing -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchUpstreamFinding {
    <#
    Pulls the single finding a prerequisite collector produced out of the upstream results.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][hashtable]$Upstream = @{},
        [Parameter(Mandatory)][string]$ControlId
    )

    if (-not $Upstream -or -not $Upstream.ContainsKey($ControlId)) { return $null }
    $result = $Upstream[$ControlId]
    if ($null -eq $result) { return $null }

    return @($result.findings | Where-Object { $_.controlId -eq $ControlId }) | Select-Object -First 1
}

<#
DAG-01 - Database Availability Group health.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_DAG_01_DagHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'DAG-01'

    $dags = @()
    try { $dags = Get-DatabaseAvailabilityGroup -Status -ErrorAction Stop }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'Get-DatabaseAvailabilityGroup failed' -Data @{ error=$_.Exception.Message }
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'Medium' -Title $control.title -Description $control.target -Evidence @() -Remediation 'Run from EMS with rights to query DAG status.' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'SoftFail' -Rationale 'Unable to query DAG state (may be non-DAG environment).' -Metrics @{ error=$_.Exception.Message } -Meta @{ dataSources = @{ Exchange = @{ state='Partial'; reason=$_.Exception.Message } }; evaluationStatus = 'Partial' }
    }

    if ($dags.Count -eq 0) {
        $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'dag/state.json' -ContentObject @()
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'Low' -Title $control.title -Description $control.target -Evidence @($evidencePath) -Remediation 'If DAG is expected, deploy and join Exchange servers; otherwise acknowledge standalone design.' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'SoftFail' -Rationale 'No DAGs detected in the organization.' -Metrics @{ dagCount=0 } -Meta @{ dataSources = @{ Exchange = @{ state='Success'; reason='No DAGs' } }; evaluationStatus = 'Complete' }
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($dag in @($dags)) {
        $members = $dag.Servers
        if ($null -eq $members) { $members = @() }
        $operational = $dag.OperationalServers
        if ($null -eq $operational) { $operational = @() }
        $networks = $dag.NetworkNames
        if ($null -eq $networks) { $networks = @() }
        $dbs = $dag.Databases
        if ($null -eq $dbs) { $dbs = @() }

        $records.Add([pscustomobject]@{
            name        = $dag.Name
            members     = @($members)
            operational = @($operational)
            witness     = $dag.WitnessServer
            networks    = @($networks)
            databases   = @($dbs)
            autoActivationPolicy = $dag.DatabaseCopyAutoActivationPolicy
        }) | Out-Null
    }

    $recArr = @($records.ToArray())
    $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'dag/state.json' -ContentObject $recArr

    $issues = @(
        $recArr | Where-Object {
            $members = @($_.members)
            if (-not ($members -is [System.Array])) { $members = @($members) }
            $oper    = @($_.operational)
            if (-not ($oper -is [System.Array])) { $oper = @($oper) }
            ($members.Count -eq 0) -or ($oper.Count -lt $members.Count)
        }
    )

    $outcome = 'Compliant'
    $sev = 'Medium'
    $suff = 'Pass'
    $rat = 'DAGs detected and operational members present.'

    if ($issues.Count -gt 0) {
        $outcome = 'NonCompliant'
        $sev = 'High'
        $rat = 'One or more DAGs have missing or non-operational members.'
    }

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence @($evidencePath) `
        -Remediation 'Ensure all DAG members are healthy, witness is reachable, and databases replicate across members.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{ dagCount=$recArr.Count; dagIssues=$issues.Count } `
        -Meta @{ dataSources = @{ Exchange = @{ state='Success'; reason='' } }; evaluationStatus = 'Complete' }
}

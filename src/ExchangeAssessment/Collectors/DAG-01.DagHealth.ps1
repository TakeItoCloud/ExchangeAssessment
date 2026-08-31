<#
DAG-01 - Database Availability Group configuration and health.

A standalone organisation is a valid design, so "no DAG" is reported as a fact about the
deployment rather than scored as a failure. Where a DAG does exist, membership, witness and
replication networks are evaluated - an even-membered DAG without a witness cannot hold quorum.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_DAG_01_DagHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'DAG-01'

    try { $dags = @(Get-DatabaseAvailabilityGroup -Status -ErrorAction Stop) }
    catch {
        $reason = "Get-DatabaseAvailabilityGroup failed, so DAG state could not be assessed: $($_.Exception.Message)"
        Write-ExchEvent -Run $Run -Level ERROR -Message 'Get-DatabaseAvailabilityGroup failed' -Data @{ error = $_.Exception.Message }
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason -Severity 'Medium' `
                -Remediation 'Run from an Exchange Management Shell with rights to query database availability groups.'
        )
    }

    $requireWitness = [bool](Get-ExchThreshold -Run $Run -Name 'Dag.RequireWitness' -Default $true)
    $requireAlternate = [bool](Get-ExchThreshold -Run $Run -Name 'Dag.RequireAlternateWitness' -Default $false)

    $dagRows     = New-Object System.Collections.Generic.List[object]
    $networkRows = New-Object System.Collections.Generic.List[object]
    $networkErrors = New-Object System.Collections.Generic.List[string]

    foreach ($dag in $dags) {
        $members     = @($dag.Servers)
        $operational = @($dag.OperationalServers)

        $dagRows.Add([pscustomobject]@{
            Name                 = [string]$dag.Name
            MemberCount          = $members.Count
            Members              = (ConvertTo-ExchFlatValue -Value $members)
            OperationalCount     = $operational.Count
            OperationalServers   = (ConvertTo-ExchFlatValue -Value $operational)
            WitnessServer        = [string]$dag.WitnessServer
            WitnessDirectory     = [string]$dag.WitnessDirectory
            AlternateWitnessServer    = [string]$dag.AlternateWitnessServer
            AlternateWitnessDirectory = [string]$dag.AlternateWitnessDirectory
            DatabaseCount        = @($dag.Databases).Count
            NetworkNames         = (ConvertTo-ExchFlatValue -Value $dag.NetworkNames)
            DatabaseCopyAutoActivationPolicy = [string]$dag.DatabaseCopyAutoActivationPolicy
            ReplicationPort      = [string]$dag.ReplicationPort
            WitnessRequiredForQuorum = ($members.Count % 2 -eq 0)
        }) | Out-Null

        try {
            foreach ($net in @(Get-DatabaseAvailabilityGroupNetwork -Identity $dag.Name -ErrorAction Stop)) {
                $networkRows.Add([pscustomobject]@{
                    Dag             = [string]$dag.Name
                    Network         = [string]$net.Name
                    ReplicationEnabled = [bool]$net.ReplicationEnabled
                    IgnoreNetwork   = [bool]$net.IgnoreNetwork
                    Subnets         = (ConvertTo-ExchFlatValue -Value $net.Subnets)
                    Interfaces      = (ConvertTo-ExchFlatValue -Value $net.Interfaces)
                }) | Out-Null
            }
        }
        catch {
            $networkErrors.Add(("{0}: {1}" -f $dag.Name, $_.Exception.Message)) | Out-Null
        }
    }

    $dagArr = @($dagRows.ToArray())
    $netArr = @($networkRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'dag/state.json' -ContentObject ([ordered]@{
        dags     = $dagArr
        networks = $netArr
        networkReadErrors = @($networkErrors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'mailbox.dags' -Title 'Database Availability Groups' -Area 'Mailbox' `
            -Columns @('Name', 'MemberCount', 'Members', 'OperationalCount', 'OperationalServers', 'WitnessServer', 'WitnessDirectory', 'AlternateWitnessServer', 'AlternateWitnessDirectory', 'DatabaseCount', 'NetworkNames', 'DatabaseCopyAutoActivationPolicy', 'ReplicationPort', 'WitnessRequiredForQuorum') `
            -Rows $dagArr

        New-ExchInventorySection -Run $Run -Key 'mailbox.dag-networks' -Title 'DAG Networks' -Area 'Mailbox' `
            -Columns @('Dag', 'Network', 'ReplicationEnabled', 'IgnoreNetwork', 'Subnets', 'Interfaces') `
            -Rows $netArr
    )

    if ($dagArr.Count -eq 0) {
        # Whether a standalone deployment is acceptable is a property of the client, not of this
        # tool, so the verdict comes from the threshold configuration rather than being assumed.
        $requireHa = [bool](Get-ExchThreshold -Run $Run -Name 'Dag.RequireHighAvailability' -Default $false)

        $finding = New-ExchControlFinding -Control $control `
            -Severity $(if ($requireHa) { 'High' } else { 'Info' }) `
            -Outcome $(if ($requireHa) { 'NonCompliant' } else { 'Compliant' }) `
            -Rationale $(if ($requireHa) {
                    'No database availability groups exist, but this organisation is configured as requiring mailbox high availability. Databases have no copies and no automatic failover.'
                } else {
                    'No database availability groups exist. This is a standalone deployment, so mailbox databases have no copies and no automatic failover. High availability is not required by the assessment configuration for this organisation.'
                }) `
            -Evidence @($evidence) `
            -Remediation 'If mailbox high availability is required, deploy a DAG with an odd member count, or an even count plus a witness. If standalone is deliberate, confirm the recovery time objective is met by backups alone and set Dag.RequireHighAvailability to false for this client.' `
            -Metrics @{ dagCount = 0; highAvailabilityRequired = $requireHa } `
            -Meta @{ dataSources = @{ Exchange = @{ state = 'Success'; reason = 'No DAGs configured' } }; evaluationStatus = 'Complete' }

        return New-ExchCollectorResult -Sections $sections -Findings @($finding)
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    $degraded = @($dagArr | Where-Object { $_.OperationalCount -lt $_.MemberCount })
    if ($degraded.Count -gt 0) {
        $problems.Add(("{0} DAGs have members that are not operational: {1}" -f $degraded.Count, `
            (($degraded | ForEach-Object { "$($_.Name) $($_.OperationalCount)/$($_.MemberCount)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    $noWitness = @($dagArr | Where-Object { $requireWitness -and -not $_.WitnessServer })
    if ($noWitness.Count -gt 0) {
        $quorumRisk = @($noWitness | Where-Object { $_.WitnessRequiredForQuorum })
        $problems.Add(("{0} DAGs have no witness server configured{1}" -f $noWitness.Count, `
            $(if ($quorumRisk.Count -gt 0) { ", and $($quorumRisk.Count) of those have an even member count so cannot hold quorum after a single failure" } else { '' }))) | Out-Null
        $outcomes.Add($(if ($quorumRisk.Count -gt 0) { 'NonCompliant' } else { 'PartiallyCompliant' })) | Out-Null
    }

    if ($requireAlternate) {
        $noAlternate = @($dagArr | Where-Object { -not $_.AlternateWitnessServer })
        if ($noAlternate.Count -gt 0) {
            $problems.Add(("{0} DAGs have no alternate witness configured for datacentre switchover" -f $noAlternate.Count)) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }
    }

    $singleMember = @($dagArr | Where-Object { $_.MemberCount -lt [int](Get-ExchThreshold -Run $Run -Name 'Dag.MinMembersForQuorum' -Default 2) })
    if ($singleMember.Count -gt 0) {
        $problems.Add(("{0} DAGs have fewer members than the configured minimum for redundancy: {1}" -f $singleMember.Count, `
            (($singleMember | ForEach-Object { "$($_.Name) ($($_.MemberCount))" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($networkErrors.Count -gt 0) {
        $problems.Add(("DAG networks could not be read for some groups: {0}" -f ($networkErrors -join '; '))) | Out-Null
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
                 else { ("All {0} DAGs have every member operational, a witness configured and {1} replication networks reported." -f $dagArr.Count, $netArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($networkErrors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Bring non-operational DAG members back into service, configure a witness for every DAG with an even member count, and confirm replication networks are correct.' `
        -Metrics @{
            dagCount     = $dagArr.Count
            networkCount = $netArr.Count
            degraded     = $degraded.Count
            withoutWitness = $noWitness.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($networkErrors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($networkErrors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

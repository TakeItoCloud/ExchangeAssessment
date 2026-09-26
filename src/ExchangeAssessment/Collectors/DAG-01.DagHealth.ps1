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

    $statusWarnings = New-Object System.Collections.Generic.List[string]
    try {
        $dags = @(Invoke-ExchWithWarningCapture -Label 'Get-DatabaseAvailabilityGroup -Status' -Run $Run -ControlId $control.controlId `
            -Warnings $statusWarnings -Script { Get-DatabaseAvailabilityGroup -Status -ErrorAction Stop })
    }
    catch {
        $reason = "Get-DatabaseAvailabilityGroup failed, so DAG state could not be assessed: $($_.Exception.Message)"
        $null = Write-ExchError -Run $Run -Context 'Get-DatabaseAvailabilityGroup' -ErrorRecord $_ -ControlId $control.controlId
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

    # A DAG object carries no list of its databases - measured on the first live run, where
    # reading $dag.Databases under strict mode took the whole collector down. The count comes
    # from the databases instead, each naming its DAG in MasterServerOrAvailabilityGroup. When
    # that read fails the count is $null - not measured - rather than 0.
    $databaseErrors = New-Object System.Collections.Generic.List[string]
    $databases = @(Invoke-ExchQuery -Label 'Get-MailboxDatabase' -Errors $databaseErrors -Run $Run -ControlId $control.controlId `
        -Script { Get-MailboxDatabase -ErrorAction Stop })
    $databaseCountByDag = @{}
    foreach ($db in $databases) {
        $master = [string](Get-ExchObjectValue -InputObject $db -Name 'MasterServerOrAvailabilityGroup' -Default '')
        if (-not $master) { continue }
        if (-not $databaseCountByDag.ContainsKey($master)) { $databaseCountByDag[$master] = 0 }
        $databaseCountByDag[$master]++
    }

    # Properties the verdict is reached from. Missing any of them makes that DAG Unknown, naming
    # the field, rather than letting an empty value read as "no members" or "no witness".
    $judgedDagProperties = @('Name', 'Servers', 'OperationalServers', 'WitnessServer')
    if ($requireAlternate) { $judgedDagProperties += 'AlternateWitnessServer' }

    foreach ($dag in $dags) {
        $dagName     = [string](Get-ExchObjectValue -InputObject $dag -Name 'Name' -Default '')
        $members     = @(Get-ExchObjectValue -InputObject $dag -Name 'Servers')
        $operational = @(Get-ExchObjectValue -InputObject $dag -Name 'OperationalServers')

        $databaseCount = $null
        if ($databaseErrors.Count -eq 0) {
            $databaseCount = $(if ($databaseCountByDag.ContainsKey($dagName)) { $databaseCountByDag[$dagName] } else { 0 })
        }

        $dagRows.Add([pscustomobject]@{
            Name                 = $dagName
            MemberCount          = $members.Count
            Members              = (ConvertTo-ExchFlatValue -Value $members)
            OperationalCount     = $operational.Count
            OperationalServers   = (ConvertTo-ExchFlatValue -Value $operational)
            WitnessServer        = [string](Get-ExchObjectValue -InputObject $dag -Name 'WitnessServer' -Default '')
            WitnessDirectory     = [string](Get-ExchObjectValue -InputObject $dag -Name 'WitnessDirectory' -Default '')
            AlternateWitnessServer    = [string](Get-ExchObjectValue -InputObject $dag -Name 'AlternateWitnessServer' -Default '')
            AlternateWitnessDirectory = [string](Get-ExchObjectValue -InputObject $dag -Name 'AlternateWitnessDirectory' -Default '')
            DatabaseCount        = $databaseCount
            NetworkNames         = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $dag -Name 'NetworkNames'))
            DatabaseCopyAutoActivationPolicy = [string](Get-ExchObjectValue -InputObject $dag -Name 'DatabaseCopyAutoActivationPolicy' -Default '')
            ReplicationPort      = [string](Get-ExchObjectValue -InputObject $dag -Name 'ReplicationPort' -Default '')
            WitnessRequiredForQuorum = ($members.Count % 2 -eq 0)
            UnreadableFields     = (Get-ExchMissingProperty -InputObject $dag -Name $judgedDagProperties)
        }) | Out-Null

        if (-not $dagName) { continue }
        try {
            foreach ($net in @(Get-DatabaseAvailabilityGroupNetwork -Identity $dagName -ErrorAction Stop)) {
                $networkRows.Add([pscustomobject]@{
                    Dag             = $dagName
                    Network         = [string](Get-ExchObjectValue -InputObject $net -Name 'Name' -Default '')
                    ReplicationEnabled = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $net -Name 'ReplicationEnabled'))
                    IgnoreNetwork   = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $net -Name 'IgnoreNetwork'))
                    Subnets         = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $net -Name 'Subnets'))
                    Interfaces      = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $net -Name 'Interfaces'))
                }) | Out-Null
            }
        }
        catch {
            $networkErrors.Add(("{0}: {1}" -f $dagName, $_.Exception.Message)) | Out-Null
            $null = Write-ExchError -Run $Run -Context ('Get-DatabaseAvailabilityGroupNetwork on {0}' -f $dagName) -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
        }
    }

    $dagArr = @($dagRows.ToArray())
    $netArr = @($networkRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'dag/state.json' -ContentObject ([ordered]@{
        dags     = $dagArr
        networks = $netArr
        networkReadErrors = @($networkErrors.ToArray())
        statusWarnings    = @($statusWarnings.ToArray())
        databaseReadErrors = @($databaseErrors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'mailbox.dags' -Title 'Database Availability Groups' -Area 'Mailbox' `
            -Columns @('Name', 'MemberCount', 'Members', 'OperationalCount', 'OperationalServers', 'WitnessServer', 'WitnessDirectory', 'AlternateWitnessServer', 'AlternateWitnessDirectory', 'DatabaseCount', 'NetworkNames', 'DatabaseCopyAutoActivationPolicy', 'ReplicationPort', 'WitnessRequiredForQuorum', 'UnreadableFields') `
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

    # A DAG missing a judged field is Unknown and takes no part in the judgements below, which
    # would otherwise read its empty member list or witness as a measured absence.
    $unreadable = @($dagArr | Where-Object { $_.UnreadableFields })
    if ($unreadable.Count -gt 0) {
        $problems.Add(("{0} DAGs could not be judged because properties the verdict depends on were not returned: {1}" -f $unreadable.Count, `
            (($unreadable | ForEach-Object { "$($_.Name) ($($_.UnreadableFields))" }) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    $judged = @($dagArr | Where-Object { -not $_.UnreadableFields })

    # Exchange writes a warning, not an error, when it cannot reach a member's Replication or
    # cluster service while reading -Status, and still returns the DAG with OperationalServers
    # filled from whatever it could reach. Those warnings are stated, so an operational count
    # read under them is never presented as a complete measurement.
    if ($statusWarnings.Count -gt 0) {
        $problems.Add(("DAG status was read with {0} warnings, so operational membership may be incomplete: {1}" -f $statusWarnings.Count, ($statusWarnings -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    $degraded = @($judged | Where-Object { $_.OperationalCount -lt $_.MemberCount })
    if ($degraded.Count -gt 0) {
        $problems.Add(("{0} DAGs have members that are not operational: {1}" -f $degraded.Count, `
            (($degraded | ForEach-Object { "$($_.Name) $($_.OperationalCount)/$($_.MemberCount)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    $noWitness = @($judged | Where-Object { $requireWitness -and -not $_.WitnessServer })
    if ($noWitness.Count -gt 0) {
        $quorumRisk = @($noWitness | Where-Object { $_.WitnessRequiredForQuorum })
        $problems.Add(("{0} DAGs have no witness server configured{1}" -f $noWitness.Count, `
            $(if ($quorumRisk.Count -gt 0) { ", and $($quorumRisk.Count) of those have an even member count so cannot hold quorum after a single failure" } else { '' }))) | Out-Null
        $outcomes.Add($(if ($quorumRisk.Count -gt 0) { 'NonCompliant' } else { 'PartiallyCompliant' })) | Out-Null
    }

    if ($requireAlternate) {
        $noAlternate = @($judged | Where-Object { -not $_.AlternateWitnessServer })
        if ($noAlternate.Count -gt 0) {
            $problems.Add(("{0} DAGs have no alternate witness configured for datacentre switchover" -f $noAlternate.Count)) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }
    }

    $singleMember = @($judged | Where-Object { $_.MemberCount -lt [int](Get-ExchThreshold -Run $Run -Name 'Dag.MinMembersForQuorum' -Default 2) })
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
        -Sufficiency $(if ($networkErrors.Count -gt 0 -or $statusWarnings.Count -gt 0 -or $unreadable.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Bring non-operational DAG members back into service, configure a witness for every DAG with an even member count, and confirm replication networks are correct.' `
        -Metrics @{
            dagCount     = $dagArr.Count
            networkCount = $netArr.Count
            degraded     = $degraded.Count
            withoutWitness = $noWitness.Count
            unreadable   = $unreadable.Count
            statusWarnings = $statusWarnings.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($networkErrors.Count -gt 0 -or $statusWarnings.Count -gt 0 -or $unreadable.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ((@($networkErrors) + @($statusWarnings)) -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

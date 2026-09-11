<#
DEP.NET-01 - Network reachability, probed from each greenfield target server outward.

A reachability result is a statement about one source reaching one destination. A probe run from the
host running the assessment says whether that host reaches a domain controller - not whether the
member server that will become an Exchange server does. So every probe here runs ON the target, over
WinRM, and every result names the target it was sent to and the host name the target reported for
itself while the probe ran.

  Targets       Deployment.TargetServers, the P13 contract passed with -ConfigPath, and nothing else.
  Flows         Config/PortMatrix.psd1, or the copy passed with -PortMatrixPath: one entry per flow,
                each with its port, protocol and probe and the Microsoft Learn page it was read from.
  Destinations  discovered where they can be, and never guessed:
                  domain controllers   from the directory (Get-ADForest, then Get-ADDomainController)
                  witness and peers    Deployment.WitnessServer and the other TargetServers
                  DNS servers          the target's own DNS client configuration, read on the target

There is no local fallback. A target whose name does not resolve, or that does not answer WinRM, gets
Unknown for every one of its flows, naming the mechanism and the error: a probe from the wrong source
is a wrong answer that looks like a right one.

Each flow is Open (the handshake completed, or the server answered), Closed (the target was told the
port refused or is unreachable) or Unknown with its cause. A timeout is Unknown with cause 'timeout',
never Closed - nothing answered, so nothing refused. A flow whose port the table does not document is
Unknown whatever was measured. A Closed flow is reported, not judged: it may be right for the
environment, and before Exchange and failover clustering are installed nothing listens on a peer's
replication or cluster port.

Remote access goes through the wrappers DEP.TGT-01 established - Resolve-ExchTargetName and
Invoke-ExchTargetCommand - and the directory through Get-ExchDirectoryDomainController, so the tests
can replace the network with mocks. The probe is the one scriptblock Get-ExchPortProbeScript returns;
it is handed to Invoke-ExchTargetCommand and to nothing else, and a test holds it to that.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_DEP_NET_01_TargetPortMatrix {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'DEP.NET-01'

    # The same test DEP.TGT-01 and the preflight warning use, so none of the three can disagree
    # about whether TargetServers was supplied.
    $gap = Get-ExchDeploymentConfigGap -Deployment (Get-ExchThreshold -Run $Run -Name 'Deployment')
    $targets = @(Get-ExchDeploymentTargetServer -Run $Run)
    if (@($gap.Missing) -contains 'TargetServers' -or $targets.Count -eq 0) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Severity 'Info' -DataSource 'DeploymentConfig' `
                -Reason (Get-ExchNoTargetServerReason) `
                -Remediation 'For a greenfield deployment, name the member servers that will become Exchange servers in Deployment.TargetServers and pass the file with -ConfigPath; network reachability is then probed from each of them. For an assessment of an existing organisation this finding is expected.'
        )
    }

    # Loaded once. A missing or unparseable table throws rather than degrading to "no flows",
    # which would look like a clean run.
    try { $matrix = Get-ExchPortMatrix -Run $Run }
    catch {
        $reason = "The port matrix could not be loaded, so no flow was probed from any target server: $($_.Exception.Message)"
        $null = Write-ExchError -Run $Run -Context 'Get-ExchPortMatrix' -ErrorRecord $_ -ControlId $control.controlId
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason -DataSource 'PortMatrix' `
                -Remediation 'Restore src/ExchangeAssessment/Config/PortMatrix.psd1, or pass a valid copy with -PortMatrixPath.'
        )
    }

    $flows = @($matrix.Flows)
    $timeout = [int](Get-ExchThreshold -Run $Run -Name 'PortProbe.TimeoutMilliseconds' -Default 5000)
    $concurrent = [int](Get-ExchThreshold -Run $Run -Name 'PortProbe.MaxConcurrent' -Default 32)
    $witness = [string](@(@(Get-ExchThreshold -Run $Run -Name 'Deployment.WitnessServer' -Default '') |
        ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) | Select-Object -First 1)

    # Domain controllers come from the directory and from nowhere else. A failure there costs only
    # the flows that go to them; the witness, peer and DNS flows still run.
    $controllers = @()
    $directoryCause = ''
    $directoryGaps = @()
    try {
        $discovery = Get-ExchDirectoryDomainController -Run $Run
        $controllers = @(Get-ExchPortItem -InputObject $discovery -Name 'Controllers' | Where-Object { $null -ne $_ })
        $directoryGaps = @(Get-ExchPortItem -InputObject $discovery -Name 'Errors' | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if ($controllers.Count -eq 0) {
            $directoryCause = 'the directory returned no domain controllers'
            if ($directoryGaps.Count -gt 0) { $directoryCause = ('{0} ({1})' -f $directoryCause, ($directoryGaps -join '; ')) }
        }
    }
    catch {
        $directoryCause = "domain controllers could not be discovered from the directory: $($_.Exception.Message)"
        $null = Write-ExchError -Run $Run -Context 'Domain controller discovery (Get-ADForest, Get-ADDomainController)' -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
    }

    $rowList    = New-Object System.Collections.Generic.List[object]
    $sourceList = New-Object System.Collections.Generic.List[object]
    $probedList = New-Object System.Collections.Generic.List[string]

    foreach ($name in $targets) {
        $plan = @(New-ExchPortProbePlan -Flows $flows -Target $name -Targets $targets -Witness $witness -Controllers $controllers -DirectoryCause $directoryCause)
        $probed = Invoke-ExchPortProbeTarget -Run $Run -Target $name -Plan $plan -TimeoutMilliseconds $timeout -MaxConcurrent $concurrent -ControlId $control.controlId
        foreach ($row in @($probed.Rows)) { $rowList.Add($row) | Out-Null }
        $sourceList.Add($probed.Summary) | Out-Null
        foreach ($flowId in @($probed.ProbedFlowIds)) { $probedList.Add([string]$flowId) | Out-Null }
    }

    $rows = @($rowList.ToArray())
    $sources = @($sourceList.ToArray())
    $destinations = @(New-ExchPortDestinationSummary -Rows $rows)
    $probedFlowIds = @($probedList.ToArray() | Sort-Object -Unique)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'deployment/target-port-matrix.json' -ContentObject ([ordered]@{
        portMatrix          = [ordered]@{ path = $matrix.Path; tableAsOf = $matrix.TableAsOf.ToString('yyyy-MM-dd'); flows = $flows.Count }
        timeoutMilliseconds = $timeout
        witnessServer       = $witness
        domainControllers   = $controllers
        directoryCause      = $directoryCause
        directoryGaps       = $directoryGaps
        sources             = $sources
        destinations        = $destinations
        flows               = $rows
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'deployment.target-port-flows' -Title 'Deployment Target Network Flows' -Area 'Deployment' `
            -Columns @('Source', 'ProbeOrigin', 'ProbeOriginAddress', 'FlowId', 'DestinationRole', 'Destination', 'DestinationAddress', 'DestinationDetail',
                'Port', 'Protocol', 'Probe', 'Outcome', 'Cause', 'Measured', 'ElapsedMs', 'Purpose', 'LearnSource') `
            -Rows $rows -HighCardinality

        New-ExchInventorySection -Run $Run -Key 'deployment.target-port-sources' -Title 'Deployment Target Network Flows by Source' -Area 'Deployment' `
            -Columns @('Server', 'Status', 'Error', 'ProbeOrigin', 'OriginCheck', 'DnsServers', 'Results', 'Open', 'Closed', 'Unknown') `
            -Rows $sources

        New-ExchInventorySection -Run $Run -Key 'deployment.target-port-destinations' -Title 'Deployment Target Network Flows by Destination' -Area 'Deployment' `
            -Columns @('Destination', 'DestinationRole', 'Sources', 'Results', 'Open', 'Closed', 'Unknown') `
            -Rows $destinations
    )

    $open    = @($rows | Where-Object { $_.Outcome -eq 'Open' })
    $closed  = @($rows | Where-Object { $_.Outcome -eq 'Closed' })
    $unknown = @($rows | Where-Object { $_.Outcome -eq 'Unknown' })

    $unresolved    = @($sources | Where-Object { $_.Status -eq 'NameDoesNotResolve' })
    $unreachable   = @($sources | Where-Object { $_.Status -eq 'WinRmFailed' })
    $misattributed = @($sources | Where-Object { $_.Status -eq 'Probed' -and @('Missing', 'Mismatch') -contains $_.OriginCheck })
    $misattributedNames = @($misattributed | ForEach-Object { $_.Server })
    $unmeasured    = @($unknown | Where-Object { $_.ProbeOrigin -and $misattributedNames -notcontains $_.Source })

    $witnessFlowIds = @($flows | Where-Object { [string](Get-ExchPortItem -InputObject $_ -Name 'DestinationRole') -eq 'WitnessServer' } | ForEach-Object { [string](Get-ExchPortItem -InputObject $_ -Name 'Id') })
    $peerFlowIds    = @($flows | Where-Object { [string](Get-ExchPortItem -InputObject $_ -Name 'DestinationRole') -eq 'PeerTarget' } | ForEach-Object { [string](Get-ExchPortItem -InputObject $_ -Name 'Id') })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($unresolved.Count -gt 0) {
        $problems.Add(("{0} supplied names do not resolve on the assessment host, so nothing was sent to them and no flow was probed from them: {1}" -f `
            $unresolved.Count, (($unresolved | ForEach-Object { "$($_.Server) ($($_.Error))" }) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($unreachable.Count -gt 0) {
        $problems.Add(("{0} targets did not answer WinRM, so none of their flows was probed - and no probe was run from any other host in their place: {1}" -f `
            $unreachable.Count, (($unreachable | ForEach-Object { "$($_.Server) ($($_.Error))" }) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($misattributed.Count -gt 0) {
        $problems.Add(("{0} targets did not confirm they were the host the probe ran on, so their results are not attributed to them: {1}" -f `
            $misattributed.Count, (($misattributed | ForEach-Object { "$($_.Server) reported '$($_.ProbeOrigin)'" }) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($directoryCause) {
        $problems.Add(("The domain controller flows were not probed from any target: {0}. Domain controllers are discovered from the directory and are never supplied or guessed" -f $directoryCause.TrimEnd('.'))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif ($directoryGaps.Count -gt 0) {
        $problems.Add(("The domain controllers of part of the forest could not be listed, so no flow to them was probed: {0}" -f ($directoryGaps -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if (-not $witness -and $witnessFlowIds.Count -gt 0) {
        $problems.Add(("Deployment.WitnessServer is empty, so the {0} witness flows ({1}) were not probed; every other flow was. Fill in WitnessServer in the file passed with -ConfigPath" -f `
            $witnessFlowIds.Count, ($witnessFlowIds -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($targets.Count -lt 2 -and $peerFlowIds.Count -gt 0) {
        $problems.Add(("Only one target server was supplied, so the {0} flows to another target ({1}) have no destination" -f $peerFlowIds.Count, ($peerFlowIds -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($closed.Count -gt 0) {
        $problems.Add(("{0} flows were refused. A refused flow is reported, not judged: it may be right for this environment - before Exchange and failover clustering are installed nothing listens on a peer's replication or cluster port - and whether it matters is for the reader to decide: {1}" -f `
            $closed.Count, (Format-ExchPortFlowList -Rows $closed))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($unmeasured.Count -gt 0) {
        $problems.Add(("{0} flows on targets that ran the probe could not be measured: {1}" -f $unmeasured.Count, (Format-ExchPortFlowList -Rows $unmeasured -WithCause))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    # Compliant is added only when nothing above fired. Get-ExchWorstOutcome would otherwise let an
    # Open flow outvote an Unknown one, and an unmeasured flow would pass.
    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Medium' }
        'Unknown'            { 'Medium' }
        default              { 'Low' }
    }

    $measuredCount = $open.Count + $closed.Count
    $sufficiency = if ($measuredCount -eq 0) { 'HardFail' }
                   elseif ($unknown.Count -gt 0) { 'SoftFail' }
                   else { 'Pass' }

    $scope = ("The {0} flows of the port matrix dated {1} were probed on each of the {2} target servers named in Deployment.TargetServers that could be reached, from the target itself, with a {3} ms timeout per probe: {4} results, {5} Open, {6} Closed, {7} Unknown" -f `
        $flows.Count, $matrix.TableAsOf.ToString('yyyy-MM-dd'), $targets.Count, $timeout, $rows.Count, $open.Count, $closed.Count, $unknown.Count)
    $rationale = if ($problems.Count -gt 0) { (@($scope) + @($problems.ToArray()) -join '. ') + '.' }
                 else { ('{0}, and every flow from every target was Open: {1}.' -f $scope, (($targets) -join ', ')) }

    $directoryState = if ($directoryCause) { 'Error' } elseif ($directoryGaps.Count -gt 0) { 'Partial' } else { 'Success' }
    $directoryReason = if ($directoryCause) { $directoryCause } else { $directoryGaps -join '; ' }
    $winRmState = if (@($sources | Where-Object { $_.Status -ne 'Probed' }).Count -eq 0) { 'Success' } else { 'Partial' }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome -Sufficiency $sufficiency `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Correct the target names that do not resolve and make every target reachable over WinRM from the assessment host, fill in Deployment.WitnessServer, then review each Closed and Unknown flow with the network team - each row names the source it ran from, the destination and the port. A refused flow may be correct: before Exchange and failover clustering are installed nothing listens on a peer''s replication or cluster port. Exchange also requires traffic to domain controllers and between Exchange servers to be unrestricted on the dynamic RPC range, which a probe to fixed ports cannot prove - https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports' `
        -Metrics @{
            targetCount           = $targets.Count
            flowsInMatrix         = $flows.Count
            flowsProbed           = $probedFlowIds.Count
            probedFlowIds         = $probedFlowIds
            resultCount           = $rows.Count
            openCount             = $open.Count
            closedCount           = $closed.Count
            unknownCount          = $unknown.Count
            domainControllerCount = $controllers.Count
            witnessServer         = $witness
            timeoutMilliseconds   = $timeout
            portMatrixAsOf        = $matrix.TableAsOf.ToString('yyyy-MM-dd')
            portMatrixPath        = $matrix.Path
            unresolvedNames       = @($unresolved | ForEach-Object { $_.Server })
            unreachableNames      = @($unreachable | ForEach-Object { $_.Server })
            flows                 = $rows
            perTarget             = $sources
            perDestination        = $destinations
        } `
        -Meta @{ dataSources = @{
            DeploymentConfig = @{ state = 'Success'; reason = '' }
            PortMatrix       = @{ state = 'Success'; reason = $matrix.Path }
            Directory        = @{ state = $directoryState; reason = $directoryReason }
            WinRM            = @{ state = $winRmState; reason = (@($sources | Where-Object { $_.Status -ne 'Probed' } | ForEach-Object { "$($_.Server): $($_.Status)" }) -join ', ') }
        }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchDirectoryDomainController {
    <#
    Every domain controller in the forest of the host running the assessment, read from the
    directory: Get-ADForest for the domains, then Get-ADDomainController for each. A domain whose
    controllers cannot be listed is named in Errors and does not cost the others. The one place
    DEP.NET-01 reads the directory, so the tests can replace it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    Assert-ExchADModule -Run $Run
    $forest = Get-ADForest -ErrorAction Stop

    $controllers = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($domain in @($forest.Domains)) {
        try {
            foreach ($dc in @(Get-ADDomainController -Filter * -Server $domain -ErrorAction Stop)) {
                $controllers.Add([pscustomobject]@{
                    HostName        = [string]$dc.HostName
                    Domain          = [string]$dc.Domain
                    Site            = [string]$dc.Site
                    IsGlobalCatalog = [bool]$dc.IsGlobalCatalog
                }) | Out-Null
            }
        }
        catch { $errors.Add(('{0}: {1}' -f $domain, $_.Exception.Message)) | Out-Null }
    }

    return [pscustomobject]@{ Controllers = $controllers.ToArray(); Errors = $errors.ToArray() }
}

function Get-ExchPortItem {
    <#
    One property of an object that may not carry it: a table entry, a deserialized reading, a mock,
    a directory record. Collections come back as they are, for the caller to wrap in @().
    #>
    [CmdletBinding()]
    param(
        [Parameter()]$InputObject,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties.Match($Name) | Select-Object -First 1
    if (-not $property) { return $null }
    return $property.Value
}

function Get-ExchPortNote {
    [CmdletBinding()]
    param([Parameter()][string]$Note = '')

    if (-not $Note) { return 'the port matrix holds no port for this flow' }
    return $Note.TrimEnd('.')
}

function Test-ExchPortNumber {
    [CmdletBinding()]
    param([Parameter()]$Port)

    $number = 0
    if (-not [int]::TryParse([string]$Port, [ref]$number)) { return $false }
    return ($number -ge 1 -and $number -le 65535)
}

function New-ExchPortProbePlan {
    <#
    What one target is asked to probe: one item per flow and destination. An item that cannot be
    sent - no witness named, only one target, the directory unread, a flow the table does not define
    well enough to probe - carries its reason in Blocked, and becomes an Unknown row without
    anything being sent.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object[]]$Flows = @(),
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Target,
        [Parameter()][string[]]$Targets = @(),
        [Parameter()][string]$Witness = '',
        [Parameter()][object[]]$Controllers = @(),
        [Parameter()][string]$DirectoryCause = ''
    )

    $probes = @('TcpConnect', 'UdpDns', 'UdpDatagram', 'WmiConnect')
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($flow in @($Flows)) {
        $id    = [string](Get-ExchPortItem -InputObject $flow -Name 'Id')
        $role  = [string](Get-ExchPortItem -InputObject $flow -Name 'DestinationRole')
        $port  = Get-ExchPortItem -InputObject $flow -Name 'Port'
        $probe = [string](Get-ExchPortItem -InputObject $flow -Name 'Probe')
        $note  = [string](Get-ExchPortItem -InputObject $flow -Name 'Note')
        $base  = @{
            FlowId          = $id
            DestinationRole = $role
            Port            = $port
            Protocol        = [string](Get-ExchPortItem -InputObject $flow -Name 'Protocol')
            Probe           = $probe
            Purpose         = [string](Get-ExchPortItem -InputObject $flow -Name 'Purpose')
            Note            = $note
            LearnSource     = ((@(Get-ExchPortItem -InputObject $flow -Name 'Source') | Where-Object { $_ }) -join ' ')
        }

        $invalid = ''
        if (-not $id) { $invalid = 'Not probed: the port matrix holds a flow with no Id.' }
        elseif ($probes -notcontains $probe) { $invalid = ("Not probed: the flow's probe '{0}' is not one this collector runs." -f $probe) }
        elseif ($null -eq $port -and $probe -ne 'WmiConnect') {
            $invalid = ('No Learn-documented port: {0}. A {1} probe needs a port, so nothing was measured.' -f (Get-ExchPortNote -Note $note), $probe)
        }
        elseif ($null -ne $port -and -not (Test-ExchPortNumber -Port $port)) {
            $invalid = ("Not probed: the port matrix holds port '{0}', which is not a port number." -f [string]$port)
        }

        if ($invalid) {
            $items.Add((New-ExchPortPlanItem -Base $base -Blocked $invalid)) | Out-Null
            continue
        }

        if ($role -eq 'DomainController') {
            if ($DirectoryCause) {
                $items.Add((New-ExchPortPlanItem -Base $base -Blocked ('Not probed: {0}.' -f $DirectoryCause.TrimEnd('.')))) | Out-Null
                continue
            }
            $globalCatalogOnly = [bool](Get-ExchPortItem -InputObject $flow -Name 'GlobalCatalogOnly')
            $selected = @($Controllers | Where-Object { -not $globalCatalogOnly -or [bool](Get-ExchPortItem -InputObject $_ -Name 'IsGlobalCatalog') })
            if ($selected.Count -eq 0) {
                $items.Add((New-ExchPortPlanItem -Base $base -Blocked 'Not probed: no domain controller discovered in the directory is a global catalog.')) | Out-Null
            }
            foreach ($dc in $selected) {
                $detail = ('domain {0}, site {1}, global catalog {2}' -f [string](Get-ExchPortItem -InputObject $dc -Name 'Domain'),
                    [string](Get-ExchPortItem -InputObject $dc -Name 'Site'), [string][bool](Get-ExchPortItem -InputObject $dc -Name 'IsGlobalCatalog'))
                $items.Add((New-ExchPortPlanItem -Base $base -Destination ([string](Get-ExchPortItem -InputObject $dc -Name 'HostName')) -Detail $detail)) | Out-Null
            }
        }
        elseif ($role -eq 'WitnessServer') {
            if ($Witness) { $items.Add((New-ExchPortPlanItem -Base $base -Destination $Witness -Detail 'Deployment.WitnessServer')) | Out-Null }
            else {
                $items.Add((New-ExchPortPlanItem -Base $base -Blocked 'Not probed: Deployment.WitnessServer is empty, so there is no witness to probe. Fill in WitnessServer in the file passed with -ConfigPath.')) | Out-Null
            }
        }
        elseif ($role -eq 'PeerTarget') {
            $peers = @($Targets | Where-Object { $_ -ne $Target })
            if ($peers.Count -eq 0) {
                $items.Add((New-ExchPortPlanItem -Base $base -Blocked 'Not probed: only one target server was supplied in Deployment.TargetServers, so there is no other target to probe.')) | Out-Null
            }
            foreach ($peer in $peers) { $items.Add((New-ExchPortPlanItem -Base $base -Destination $peer -Detail 'Deployment.TargetServers')) | Out-Null }
        }
        elseif ($role -eq 'DnsServer') {
            $items.Add((New-ExchPortPlanItem -Base $base -Detail 'read from the target''s own DNS client configuration')) | Out-Null
        }
        else {
            $items.Add((New-ExchPortPlanItem -Base $base -Blocked ("Not probed: the port matrix names destination role '{0}', which this collector does not know." -f $role))) | Out-Null
        }
    }

    return $items.ToArray()
}

function New-ExchPortPlanItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][hashtable]$Base,
        [Parameter()][string]$Destination = '',
        [Parameter()][string]$Detail = '',
        [Parameter()][string]$Blocked = ''
    )

    return [pscustomobject]@{
        FlowId            = [string]$Base['FlowId']
        DestinationRole   = [string]$Base['DestinationRole']
        Destination       = $Destination
        DestinationDetail = $Detail
        Port              = $Base['Port']
        Protocol          = [string]$Base['Protocol']
        Probe             = [string]$Base['Probe']
        Purpose           = [string]$Base['Purpose']
        Note              = [string]$Base['Note']
        LearnSource       = [string]$Base['LearnSource']
        Blocked           = $Blocked
    }
}

function Invoke-ExchPortProbeTarget {
    <#
    Runs one target's plan ON that target and turns what came back into one row per flow and
    destination. The name is resolved first, as DEP.TGT-01 does, so a typo reads as a name that does
    not resolve. There is no second path: a target that cannot be reached over WinRM gets an Unknown
    row for every item, and nothing is probed from anywhere else in its place.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Target,
        [Parameter()][object[]]$Plan = @(),
        [Parameter()][int]$TimeoutMilliseconds = 5000,
        [Parameter()][int]$MaxConcurrent = 32,
        [Parameter()][string]$ControlId = ''
    )

    $requests = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $Plan.Count; $index++) {
        $item = $Plan[$index]
        if ($item.Blocked) { continue }
        $requests.Add(@{
            Key             = $index
            FlowId          = $item.FlowId
            DestinationRole = $item.DestinationRole
            Destination     = $item.Destination
            Port            = $item.Port
            Protocol        = $item.Protocol
            Probe           = $item.Probe
        }) | Out-Null
    }

    $status = 'Probed'
    $failure = ''
    $notProbed = ''
    $reading = $null

    $resolution = $null
    try { $resolution = Resolve-ExchTargetName -Name $Target }
    catch {
        $null = Write-ExchError -Run $Run -Context ('Name resolution of {0}' -f $Target) -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning'
        $resolution = [pscustomobject]@{ Resolved = $false; Addresses = @(); Error = [string]$_.Exception.Message }
    }

    if (-not [bool](Get-ExchPortItem -InputObject $resolution -Name 'Resolved')) {
        $status = 'NameDoesNotResolve'
        $failure = [string](Get-ExchPortItem -InputObject $resolution -Name 'Error')
        if (-not $failure) { $failure = 'the name did not resolve' }
        $notProbed = ('Not probed: the name {0} does not resolve on the assessment host ({1}), so nothing was sent to it and no probe ran from it.' -f $Target, $failure.TrimEnd('.'))
    }
    elseif ($requests.Count -eq 0) {
        $status = 'NothingToProbe'
    }
    else {
        try {
            $answer = @(Invoke-ExchTargetCommand -ComputerName $Target -ScriptBlock (Get-ExchPortProbeScript) -ArgumentList @($requests.ToArray(), $TimeoutMilliseconds, $MaxConcurrent))
            $reading = @($answer | Where-Object { $null -ne (Get-ExchPortItem -InputObject $_ -Name 'Results') }) | Select-Object -Last 1
            if ($null -eq $reading) { throw 'the target ran the probe and returned no reading' }
        }
        catch {
            $status = 'WinRmFailed'
            $failure = [string]$_.Exception.Message
            $reading = $null
            $notProbed = ('Not probed: WinRM (Invoke-Command) to {0} failed: {1}. No probe ran from {0}, and none was run from any other host in its place.' -f $Target, $failure.TrimEnd('.'))
            $null = Write-ExchError -Run $Run -Context ('Invoke-Command port probe on {0}' -f $Target) -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning'
        }
    }

    $origin = ''
    $originCheck = ''
    $dnsServers = ''
    $results = @()
    if ($null -ne $reading) {
        $origin = [string](Get-ExchPortItem -InputObject $reading -Name 'OriginHost')
        $originCheck = Test-ExchProbeOrigin -Target $Target -OriginHost $origin
        $dnsServers = ((@(Get-ExchPortItem -InputObject $reading -Name 'DnsServers') | Where-Object { $_ } | ForEach-Object { [string]$_ }) -join ';')
        $results = @(Get-ExchPortItem -InputObject $reading -Name 'Results' | Where-Object { $null -ne $_ })
    }

    $rows = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $Plan.Count; $index++) {
        $item = $Plan[$index]
        if ($item.Blocked) {
            $rows.Add((New-ExchPortFlowRow -Item $item -Source $Target -Verdict @{ Outcome = 'Unknown'; Cause = $item.Blocked; Measured = '' })) | Out-Null
            continue
        }
        if ($null -eq $reading) {
            $cause = if ($notProbed) { $notProbed } else { 'Not probed: nothing was sent to the target.' }
            $rows.Add((New-ExchPortFlowRow -Item $item -Source $Target -Verdict @{ Outcome = 'Unknown'; Cause = $cause; Measured = '' })) | Out-Null
            continue
        }

        $matched = @($results | Where-Object { [string](Get-ExchPortItem -InputObject $_ -Name 'Key') -eq [string]$index })
        if ($matched.Count -eq 0) {
            $verdict = Resolve-ExchPortFlowOutcome -Item $item -Result $null -Target $Target -OriginHost $origin -OriginCheck $originCheck
            $rows.Add((New-ExchPortFlowRow -Item $item -Source $Target -Verdict $verdict -ProbeOrigin $origin)) | Out-Null
            continue
        }
        foreach ($result in $matched) {
            $verdict = Resolve-ExchPortFlowOutcome -Item $item -Result $result -Target $Target -OriginHost $origin -OriginCheck $originCheck
            $rows.Add((New-ExchPortFlowRow -Item $item -Source $Target -Verdict $verdict -Result $result -ProbeOrigin $origin)) | Out-Null
        }
    }

    $rowArray = @($rows.ToArray())
    $probedFlowIds = @()
    if ($null -ne $reading) { $probedFlowIds = @($requests.ToArray() | ForEach-Object { [string]$_['FlowId'] } | Sort-Object -Unique) }

    return [pscustomobject]@{
        Rows          = $rowArray
        ProbedFlowIds = $probedFlowIds
        Summary       = [pscustomobject]@{
            Server      = $Target
            Status      = $status
            Error       = $failure
            ProbeOrigin = $origin
            OriginCheck = $originCheck
            DnsServers  = $dnsServers
            Results     = $rowArray.Count
            Open        = @($rowArray | Where-Object { $_.Outcome -eq 'Open' }).Count
            Closed      = @($rowArray | Where-Object { $_.Outcome -eq 'Closed' }).Count
            Unknown     = @($rowArray | Where-Object { $_.Outcome -eq 'Unknown' }).Count
        }
    }
}

function Test-ExchProbeOrigin {
    <#
    Whether the host name the target reported while the probe ran is the target that was asked:
    Match, Mismatch, NotComparable when the target was named by address, or Missing when nothing was
    reported. A result that cannot be attributed to its source is not a result about that source.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Target,
        [Parameter()][string]$OriginHost = ''
    )

    if (-not $OriginHost) { return 'Missing' }
    $address = $null
    if ([System.Net.IPAddress]::TryParse($Target, [ref]$address)) { return 'NotComparable' }
    $wanted = ($Target.Split('.')[0]).ToUpperInvariant()
    $reported = ($OriginHost.Split('.')[0]).ToUpperInvariant()
    if ($wanted -eq $reported) { return 'Match' }
    return 'Mismatch'
}

function Resolve-ExchPortFlowOutcome {
    <#
    The verdict on one flow result, and the only place one is reached. Open needs a completed
    handshake or an answer; Closed needs a refusal the target was told about. Everything else is
    Unknown with its cause: a timeout is 'timeout', never Closed, because nothing answered and so
    nothing refused; a result the target did not attribute to itself is not about that target; and a
    flow whose port the table does not document is Unknown whatever was measured, because a pass
    needs a documented port to be a pass against.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Item,
        [Parameter()]$Result,
        [Parameter()][string]$Target = '',
        [Parameter()][string]$OriginHost = '',
        [Parameter()][string]$OriginCheck = ''
    )

    if ($null -eq $Result) {
        return @{ Outcome = 'Unknown'; Cause = 'The target returned no result for this flow, so it was not measured.'; Measured = '' }
    }

    $status   = [string](Get-ExchPortItem -InputObject $Result -Name 'Status')
    $detail   = ([string](Get-ExchPortItem -InputObject $Result -Name 'Detail')).TrimEnd('.')
    $local    = [string](Get-ExchPortItem -InputObject $Result -Name 'LocalAddress')
    $address  = [string](Get-ExchPortItem -InputObject $Result -Name 'DestinationAddress')
    $elapsed  = [string](Get-ExchPortItem -InputObject $Result -Name 'ElapsedMs')
    $observed = [string](Get-ExchPortItem -InputObject $Result -Name 'ObservedRemotePorts')

    $measured = switch ($status) {
        'Connected' { 'connected from {0} to {1} in {2} ms' -f $local, $address, $elapsed }
        'Answered'  { 'answered by {0} in {1} ms ({2})' -f $address, $elapsed, $detail }
        'Refused'   { 'refused by {0} in {1} ms ({2})' -f $address, $elapsed, $detail }
        'Measured'  { '{0}; TCP connections from the target to {1} afterwards: {2}' -f $detail, $address, $observed }
        default     { $detail }
    }

    if (-not $OriginHost) {
        return @{ Outcome = 'Unknown'; Measured = $measured; Cause = 'The target did not report the host the probe ran on, so the result cannot be attributed to it.' }
    }
    if ($OriginCheck -eq 'Mismatch') {
        return @{ Outcome = 'Unknown'; Measured = $measured; Cause = ('The probe reported running on {0}, not on {1}, so the result is not a statement about {1}.' -f $OriginHost, $Target) }
    }
    if ($null -eq $Item.Port) {
        return @{ Outcome = 'Unknown'; Measured = $measured; Cause = ('No Learn-documented port: {0}. What the probe measured is recorded and is not judged.' -f (Get-ExchPortNote -Note $Item.Note)) }
    }

    switch ($status) {
        'Connected' { return @{ Outcome = 'Open'; Cause = ''; Measured = $measured } }
        'Answered'  { return @{ Outcome = 'Open'; Cause = ''; Measured = $measured } }
        'Refused'   { return @{ Outcome = 'Closed'; Cause = ''; Measured = $measured } }
        'Timeout' {
            $cause = 'timeout: nothing answered within the probe timeout, which does not tell a filtered port from a host that is down'
            if ($Item.Probe -eq 'UdpDatagram') { $cause = 'timeout: no reply to an empty datagram, and a UDP service need not reply to one, so the silence says nothing either way' }
            return @{ Outcome = 'Unknown'; Cause = $cause; Measured = $measured }
        }
        'NameNotResolved' { return @{ Outcome = 'Unknown'; Cause = ('The destination name did not resolve on the target: {0}.' -f $detail); Measured = '' } }
        'NoDestination'   { return @{ Outcome = 'Unknown'; Cause = ('No destination: {0}.' -f $detail); Measured = '' } }
        'Error'           { return @{ Outcome = 'Unknown'; Cause = ('The probe failed on the target: {0}.' -f $detail); Measured = $measured } }
        'Measured'        { return @{ Outcome = 'Unknown'; Cause = 'A WMI connection measures which ports opened; it does not test the port the table names.'; Measured = $measured } }
    }

    return @{ Outcome = 'Unknown'; Cause = ("The target returned status '{0}', which is not a probe result." -f $status); Measured = $measured }
}

function New-ExchPortFlowRow {
    <#
    One flow result. Source is the target the probe was sent to; ProbeOrigin is the host name the
    target reported for itself while the probe ran, and ProbeOriginAddress the local address the
    connection left from - both measured on the target, never assumed. Both are empty when no probe
    ran.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Item,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Source,
        [Parameter(Mandatory)][ValidateNotNull()][hashtable]$Verdict,
        [Parameter()]$Result,
        [Parameter()][string]$ProbeOrigin = ''
    )

    $destination = $Item.Destination
    $address = ''
    $local = ''
    $elapsed = $null
    if ($null -ne $Result) {
        $reported = [string](Get-ExchPortItem -InputObject $Result -Name 'Destination')
        if ($reported) { $destination = $reported }
        $address = [string](Get-ExchPortItem -InputObject $Result -Name 'DestinationAddress')
        $local = [string](Get-ExchPortItem -InputObject $Result -Name 'LocalAddress')
        $elapsed = Get-ExchPortItem -InputObject $Result -Name 'ElapsedMs'
    }

    return [pscustomobject]@{
        Source             = $Source
        ProbeOrigin        = $ProbeOrigin
        ProbeOriginAddress = $local
        FlowId             = $Item.FlowId
        DestinationRole    = $Item.DestinationRole
        Destination        = $destination
        DestinationAddress = $address
        DestinationDetail  = $Item.DestinationDetail
        Port               = $(if ($null -eq $Item.Port) { '' } else { [string]$Item.Port })
        Protocol           = $Item.Protocol
        Probe              = $Item.Probe
        Outcome            = [string]$Verdict['Outcome']
        Cause              = [string]$Verdict['Cause']
        Measured           = [string]$Verdict['Measured']
        ElapsedMs          = $elapsed
        Purpose            = $Item.Purpose
        LearnSource        = $Item.LearnSource
    }
}

function New-ExchPortDestinationSummary {
    <#
    The flow results rolled up per destination, naming every source that probed it.
    #>
    [CmdletBinding()]
    param([Parameter()][object[]]$Rows = @())

    foreach ($group in @($Rows | Where-Object { $_.Destination } | Group-Object -Property DestinationRole, Destination)) {
        $members = @($group.Group)
        [pscustomobject]@{
            Destination     = $members[0].Destination
            DestinationRole = $members[0].DestinationRole
            Sources         = ((@($members | ForEach-Object { $_.Source }) | Sort-Object -Unique) -join ';')
            Results         = $members.Count
            Open            = @($members | Where-Object { $_.Outcome -eq 'Open' }).Count
            Closed          = @($members | Where-Object { $_.Outcome -eq 'Closed' }).Count
            Unknown         = @($members | Where-Object { $_.Outcome -eq 'Unknown' }).Count
        }
    }
}

function Format-ExchPortFlowList {
    <#
    Flow results as rationale text, capped so a large forest does not bury the finding; every result
    is still in metrics.flows and the flows CSV.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object[]]$Rows = @(),
        [Parameter()][switch]$WithCause,
        [Parameter()][int]$Limit = 25
    )

    $shown = @($Rows | Select-Object -First $Limit | ForEach-Object {
        $destination = if ($_.Destination) { $_.Destination } else { $_.DestinationRole }
        $port = if ($_.Port) { $_.Port } else { 'no port' }
        $text = ('{0} -> {1} {2}/{3} ({4})' -f $_.Source, $destination, $_.Protocol, $port, $_.FlowId)
        if ($WithCause) { $text = ('{0} - {1}' -f $text, ([string]$_.Cause).TrimEnd('.')) }
        $text
    })

    $list = $shown -join '; '
    if ($Rows.Count -gt $Limit) { $list = ('{0}; and {1} more, every one listed in metrics.flows' -f $list, ($Rows.Count - $Limit)) }
    return $list
}

function Get-ExchPortProbeScript {
    <#
    The probe, as it runs ON a target server. It is handed to Invoke-ExchTargetCommand and to
    nothing else: a test walks this file's syntax tree and fails if a network primitive appears
    outside this scriptblock, or if the scriptblock is reached any other way.

    Takes the flows to probe, the per-probe timeout in milliseconds and how many TCP probes to start
    together. Returns the host name the target reports for itself, the DNS servers in its own client
    configuration, and one result per flow and destination. It judges nothing - Status says what
    happened on the wire and the collector decides the outcome:

      Connected        the TCP handshake completed
      Answered         a UDP reply came back (for DNS, a reply to the query that was sent)
      Refused          the target was told the connection was refused or the port is unreachable
      Timeout          nothing came back within the timeout
      Measured         a WMI connection was attempted and the TCP connections it left were read
      NameNotResolved  the destination name did not resolve on the target
      NoDestination    a DNS flow, and the target has no DNS server configured or it could not be read
      Error            anything else, with the error

    Written for Windows PowerShell 5.1, the default remoting endpoint on Windows Server.
    #>
    [CmdletBinding()]
    param()

    return {
        param($Requests, $TimeoutMilliseconds, $MaxConcurrent)

        $timeout = [int]$TimeoutMilliseconds
        $concurrent = [Math]::Max(1, [int]$MaxConcurrent)
        $originHost = [System.Net.Dns]::GetHostName()
        $results = New-Object System.Collections.Generic.List[object]

        # The target's own DNS servers: the DNS flows go to these, and to nothing supplied.
        $dnsServers = @()
        $dnsError = ''
        try {
            $dnsServers = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
                ForEach-Object { @($_.ServerAddresses) } | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        }
        catch { $dnsError = 'the DNS client configuration could not be read: ' + $_.Exception.Message }

        $resolved = @{}
        $resolve = {
            param($Name)
            if ($resolved.ContainsKey($Name)) { return $resolved[$Name] }
            $address = $null
            $failure = ''
            $parsed = $null
            if ([System.Net.IPAddress]::TryParse($Name, [ref]$parsed)) { $address = $parsed }
            else {
                try {
                    $all = @([System.Net.Dns]::GetHostAddresses($Name))
                    $v4 = @($all | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
                    if ($v4.Count -gt 0) { $address = $v4[0] }
                    elseif ($all.Count -gt 0) { $address = $all[0] }
                    else { $failure = 'the resolver returned no address' }
                }
                catch { $failure = $_.Exception.Message }
            }
            $entry = @{ Address = $address; Error = $failure }
            $resolved[$Name] = $entry
            return $entry
        }

        $socketError = {
            param($Exception)
            $current = $Exception
            while ($null -ne $current -and -not ($current -is [System.Net.Sockets.SocketException])) { $current = $current.InnerException }
            return $current
        }

        $newResult = {
            param($Request, $Destination, $Address, $Status, $Detail, $Local, $Elapsed, $Observed)
            [pscustomobject]@{
                Key                 = [int]$Request['Key']
                Destination         = [string]$Destination
                DestinationAddress  = [string]$Address
                Status              = [string]$Status
                Detail              = [string]$Detail
                LocalAddress        = [string]$Local
                ElapsedMs           = [int]$Elapsed
                ObservedRemotePorts = [string]$Observed
            }
        }

        # One unit of work per flow and destination. A DNS flow goes to every DNS server the target
        # itself is configured with.
        $work = New-Object System.Collections.Generic.List[object]
        foreach ($request in @($Requests)) {
            if ([string]$request['DestinationRole'] -eq 'DnsServer') {
                if ($dnsError) { $results.Add((& $newResult $request '' '' 'NoDestination' $dnsError '' 0 '')); continue }
                if ($dnsServers.Count -eq 0) { $results.Add((& $newResult $request '' '' 'NoDestination' 'the target has no IPv4 DNS server in its client configuration' '' 0 '')); continue }
                foreach ($server in $dnsServers) { $work.Add(@{ Request = $request; Destination = [string]$server }) }
            }
            else { $work.Add(@{ Request = $request; Destination = [string]$request['Destination'] }) }
        }

        # TCP: a batch of connections is started together and each waits out its own timeout, so a
        # batch of filtered ports costs one timeout rather than one per port.
        $tcp = @($work | Where-Object { [string]$_.Request['Probe'] -eq 'TcpConnect' })
        for ($start = 0; $start -lt $tcp.Count; $start += $concurrent) {
            $end = [Math]::Min($start + $concurrent, $tcp.Count) - 1
            $pending = New-Object System.Collections.Generic.List[object]
            foreach ($item in @($tcp[$start..$end])) {
                $target = & $resolve $item.Destination
                if ($null -eq $target.Address) { $results.Add((& $newResult $item.Request $item.Destination '' 'NameNotResolved' $target.Error '' 0 '')); continue }
                $client = New-Object System.Net.Sockets.TcpClient -ArgumentList $target.Address.AddressFamily
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $async = $client.BeginConnect($target.Address, [int]$item.Request['Port'], $null, $null)
                    $pending.Add([pscustomobject]@{ Item = $item; Address = $target.Address; Client = $client; Async = $async; Watch = $watch })
                }
                catch {
                    $results.Add((& $newResult $item.Request $item.Destination $target.Address 'Error' $_.Exception.Message '' $watch.ElapsedMilliseconds ''))
                    $client.Close()
                }
            }
            foreach ($attempt in $pending) {
                $remaining = [int][Math]::Max(0, $timeout - $attempt.Watch.ElapsedMilliseconds)
                $status = 'Timeout'
                $detail = ('no answer within {0} ms' -f $timeout)
                $local = ''
                if ($attempt.Async.AsyncWaitHandle.WaitOne($remaining)) {
                    try {
                        $attempt.Client.EndConnect($attempt.Async)
                        $status = 'Connected'
                        $detail = ''
                        $local = [string]$attempt.Client.Client.LocalEndPoint
                    }
                    catch {
                        $socket = & $socketError $_.Exception
                        if ($null -ne $socket -and $socket.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) { $status = 'Refused'; $detail = $socket.Message }
                        elseif ($null -ne $socket -and $socket.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) { $status = 'Timeout'; $detail = $socket.Message }
                        elseif ($null -ne $socket) { $status = 'Error'; $detail = ('{0}: {1}' -f $socket.SocketErrorCode, $socket.Message) }
                        else { $status = 'Error'; $detail = $_.Exception.Message }
                    }
                }
                $results.Add((& $newResult $attempt.Item.Request $attempt.Item.Destination $attempt.Address $status $detail $local $attempt.Watch.ElapsedMilliseconds ''))
                $attempt.Client.Close()
            }
        }

        # UDP: a DNS query where the flow is DNS, otherwise one empty datagram. Being told the port is
        # unreachable is a refusal; silence is only a timeout.
        foreach ($item in @($work | Where-Object { @('UdpDns', 'UdpDatagram') -contains [string]$_.Request['Probe'] })) {
            $target = & $resolve $item.Destination
            if ($null -eq $target.Address) { $results.Add((& $newResult $item.Request $item.Destination '' 'NameNotResolved' $target.Error '' 0 '')); continue }
            $isDns = ([string]$item.Request['Probe'] -eq 'UdpDns')
            $client = New-Object System.Net.Sockets.UdpClient -ArgumentList $target.Address.AddressFamily
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $status = 'Error'
            $detail = ''
            $local = ''
            try {
                $client.Client.ReceiveTimeout = $timeout
                $client.Connect($target.Address, [int]$item.Request['Port'])
                $local = [string]$client.Client.LocalEndPoint
                [byte[]]$datagram = @()
                if ($isDns) {
                    # A query for the root zone's name servers: the 12-byte header (a random id,
                    # recursion desired, one question) and the question (the root name, type NS,
                    # class IN). Any reply carrying the same id is the server answering.
                    $id = Get-Random -Minimum 1 -Maximum 65535
                    $datagram = [byte[]]@((($id -shr 8) -band 0xFF), ($id -band 0xFF), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1)
                }
                $null = $client.Send($datagram, $datagram.Length)
                $remote = New-Object System.Net.IPEndPoint -ArgumentList $target.Address, 0
                $reply = $client.Receive([ref]$remote)
                if ($isDns -and ($reply.Length -lt 2 -or $reply[0] -ne $datagram[0] -or $reply[1] -ne $datagram[1])) {
                    $status = 'Error'
                    $detail = 'a reply came back that does not answer the query'
                }
                else {
                    $status = 'Answered'
                    $detail = ('{0} bytes back' -f $reply.Length)
                }
            }
            catch {
                $socket = & $socketError $_.Exception
                if ($null -ne $socket -and $socket.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionReset) { $status = 'Refused'; $detail = 'the target was told the port is unreachable' }
                elseif ($null -ne $socket -and $socket.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) { $status = 'Timeout'; $detail = ('no reply within {0} ms' -f $timeout) }
                elseif ($null -ne $socket) { $status = 'Error'; $detail = ('{0}: {1}' -f $socket.SocketErrorCode, $socket.Message) }
                else { $status = 'Error'; $detail = $_.Exception.Message }
            }
            finally { $client.Close() }
            $results.Add((& $newResult $item.Request $item.Destination $target.Address $status $detail $local $watch.ElapsedMilliseconds ''))
        }

        # WMI: where Learn names the mechanism and not the port. The connection is made in its own
        # runspace so it can be abandoned at the timeout, then the TCP connections the target holds to
        # that host are read - what actually opened, rather than a number asserted in advance. Inside a
        # WinRM session the operator's credentials do not pass on to a third host without delegation,
        # so an access-denied here is about authentication, not the network path; the connections read
        # afterwards still show which ports the attempt reached.
        $connect = {
            param($Path)
            $ErrorActionPreference = 'Stop'
            $scope = New-Object System.Management.ManagementScope -ArgumentList $Path
            $scope.Connect()
            $scope.IsConnected
        }
        foreach ($item in @($work | Where-Object { [string]$_.Request['Probe'] -eq 'WmiConnect' })) {
            $target = & $resolve $item.Destination
            if ($null -eq $target.Address) { $results.Add((& $newResult $item.Request $item.Destination '' 'NameNotResolved' $target.Error '' 0 '')); continue }
            # The connections already held to this address - an earlier probe's, or anything else's -
            # so that only the ones the WMI attempt opens are reported.
            $remoteAddress = $target.Address.ToString()
            $before = @{}
            $beforeFailure = ''
            try {
                foreach ($connection in @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { [string]$_.RemoteAddress -eq $remoteAddress })) {
                    $before[('{0}:{1}' -f $connection.LocalPort, $connection.RemotePort)] = $true
                }
            }
            catch { $beforeFailure = $_.Exception.Message }
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $detail = ''
            $runner = [powershell]::Create()
            $null = $runner.AddScript($connect.ToString()).AddArgument(('\\{0}\root\cimv2' -f $item.Destination))
            try {
                $handle = $runner.BeginInvoke()
                if ($handle.AsyncWaitHandle.WaitOne($timeout)) {
                    $null = $runner.EndInvoke($handle)
                    $detail = 'the WMI connection was accepted'
                    $runner.Dispose()
                }
                else {
                    $detail = ('the WMI connection did not complete within {0} ms' -f $timeout)
                    $null = $runner.BeginStop($null, $null)
                }
            }
            catch {
                $inner = $_.Exception
                while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
                $detail = 'the WMI connection failed: ' + $inner.Message
                $runner.Dispose()
            }
            $observed = ''
            if ($beforeFailure) { $observed = 'not read: the connections held before the attempt could not be listed: ' + $beforeFailure }
            else {
                try {
                    $ports = @(Get-NetTCPConnection -ErrorAction Stop |
                        Where-Object { [string]$_.RemoteAddress -eq $remoteAddress -and -not $before.ContainsKey(('{0}:{1}' -f $_.LocalPort, $_.RemotePort)) } |
                        ForEach-Object { [int]$_.RemotePort } | Sort-Object -Unique)
                    $observed = if ($ports.Count -gt 0) { 'remote ports ' + ($ports -join ',') + ', on connections that were not there before the attempt' } else { 'no new TCP connection' }
                }
                catch { $observed = 'not read: ' + $_.Exception.Message }
            }
            $results.Add((& $newResult $item.Request $item.Destination $target.Address 'Measured' $detail '' $watch.ElapsedMilliseconds $observed))
        }

        [pscustomobject]@{
            OriginHost          = $originHost
            DnsServers          = $dnsServers
            DnsError            = $dnsError
            TimeoutMilliseconds = $timeout
            Results             = $results.ToArray()
        }
    }
}

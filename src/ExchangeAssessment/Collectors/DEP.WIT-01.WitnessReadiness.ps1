<#
DEP.WIT-01 - Prerequisites of the server that will host the DAG's file share witness.

The witness cannot be discovered: the DAG it will serve does not exist yet, and the directory cannot
say which server is meant to hold it. The operator names it in Deployment.WitnessServer, the P13
deployment config passed with -ConfigPath, and this collector assesses that name and no other. An
empty WitnessServer is the expected state until the plan names a witness, and is reported as one
Unknown finding saying so - never as an error.

Each check enforces a statement Microsoft Learn makes about the witness. The values live in
Config/Thresholds.psd1 under WitnessPrerequisites, each with its URL and read date:

  NameResolves                   the name resolves on the assessment host
  Reachable                      CIM and WinRM both answered - which says the reads ran, not that
                                 any prerequisite is met
  DomainMember                   Win32_ComputerSystem.PartOfDomain
  SameForest                     the witness's forest is the assessment host's - "must be in the same
                                 Active Directory forest as the DAG"
  OperatingSystem                a server edition at version 6.0 or later - "must be running Windows
                                 Server 2008 or later"
  NotDomainController            a directory server needs the Exchange Trusted Subsystem group in its
                                 Builtin\Administrators group, which Learn calls an unnecessary
                                 elevation of privileges and not a recommended configuration
  NotExchangeServer              Exchange services on the witness are reported, not failed: Learn
                                 recommends an Exchange server with Client Access services as witness
  NotDagMember                   not one of Deployment.TargetServers, by name or address - "can't be a
                                 member of the DAG"
  FileServerRole                 FS-FileServer installed
  FirewallFileAndPrinterSharing  on every network profile in use, Windows Firewall is off or every
  FirewallWmi                    inbound rule of the group that applies to that profile is enabled
  TrustedSubsystemGrant          three states, never two: the group is not in the directory yet
                                 (Unknown - expected before /PrepareAD), the group exists and is not in
                                 the witness's local Administrators group (NonCompliant), or it is
  WitnessDirectory               when Deployment.WitnessDirectory is supplied, a local non-root full
                                 path; not applicable when it is not

The server is read the DEP.TGT-01 way - Get-ExchTargetState over CIM and WinRM, which fail
independently - and each check is gated by Get-ExchTargetMechanismGate on the mechanisms it names,
so a mechanism that failed costs only its own checks. Remote access goes through
Resolve-ExchTargetName, Get-ExchTargetCimInstance and Invoke-ExchTargetCommand, and the directory
through Find-ExchDirectoryGroup, so the tests can replace the network with mocks.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_DEP_WIT_01_WitnessReadiness {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'DEP.WIT-01'

    # The P13 contract decides whether WitnessServer was supplied, so this collector and the
    # preflight warning cannot disagree about it.
    $gap = Get-ExchDeploymentConfigGap -Deployment (Get-ExchThreshold -Run $Run -Name 'Deployment')
    $witness = Get-ExchDeploymentWitnessServer -Run $Run
    if (@($gap.Missing) -contains 'WitnessServer' -or -not $witness) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Severity 'Info' -DataSource 'DeploymentConfig' `
                -Reason (Get-ExchNoWitnessServerReason) `
                -Remediation 'Name the server that will host the file share witness in Deployment.WitnessServer and pass the file with -ConfigPath. Until a witness is chosen this finding is expected, and it is not an error.'
        )
    }

    $requirements = Get-ExchWitnessRequirement -Run $Run
    $targets = @(Get-ExchDeploymentTargetServer -Run $Run)
    $directory = [string](@(Get-ExchDeploymentValue -Run $Run -Key 'WitnessDirectory') | Select-Object -First 1)

    $runForest = ''
    $runForestCause = ''
    try { $runForest = [string](Get-ExchRunForestName) }
    catch {
        $runForestCause = "the forest of the host running the assessment could not be read: $($_.Exception.Message)"
        $null = Write-ExchError -Run $Run -Context 'Win32_NTDomain on the assessment host' -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
    }

    $readerArguments = @(
        [string](Get-ExchPrereqValue -Entry $requirements['FileServerFeature'])
        [string](Get-ExchPrereqValue -Entry $requirements['FileAndPrinterSharingFirewallGroup'])
        [string](Get-ExchPrereqValue -Entry $requirements['WmiFirewallGroup'])
    )
    $target = Get-ExchTargetState -Run $Run -ComputerName $witness -ControlId $control.controlId `
        -CimQuery @(Get-ExchWitnessCimQuery) -RemoteReader (Get-ExchWitnessRemoteReader) -RemoteArgumentList $readerArguments

    $server = New-ExchTargetServerRow -Target $target -RunForest $runForest -RunForestCause $runForestCause
    $membership = Get-ExchWitnessDagMembership -Run $Run -Witness $witness -Target $target -Targets $targets -ControlId $control.controlId
    $group = Get-ExchWitnessTrustedSubsystem -Run $Run -Name ([string](Get-ExchPrereqValue -Entry $requirements['TrustedSubsystemGroup'])) -ControlId $control.controlId

    $context = @{
        Witness      = $witness
        Target       = $target
        Server       = $server
        Requirements = $requirements
        Membership   = $membership
        Group        = $group
        Directory    = $directory
    }
    $checks = @(foreach ($definition in @(Get-ExchWitnessCheckDefinition)) { Invoke-ExchWitnessCheck -Definition $definition -Context $context })

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'deployment/witness-readiness.json' -ContentObject ([ordered]@{
        witnessServer    = $witness
        witnessDirectory = $directory
        runForest        = $runForest
        trustedSubsystem = $group
        membership       = $membership
        server           = $server
        checks           = $checks
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'deployment.witness-server' -Title 'Deployment Witness Server' -Area 'Deployment' `
            -Columns @('Server', 'Status', 'Resolves', 'Addresses', 'ResolveError', 'CimState', 'CimError', 'WinRmState', 'WinRmError',
                'PartOfDomain', 'Domain', 'Forest', 'RunForest', 'SameForest', 'DomainRole', 'IsDomainController', 'IsExchangeServer',
                'OperatingSystem', 'LastBoot') `
            -Rows @($server)

        New-ExchInventorySection -Run $Run -Key 'deployment.witness-checks' -Title 'Deployment Witness Prerequisite Checks' -Area 'Deployment' `
            -Columns @('Server', 'Check', 'Mechanisms', 'MechanismState', 'Outcome', 'Required', 'Measured', 'Cause', 'Source') `
            -Rows $checks
    )

    $contacted = @('Read', 'PartiallyRead') -contains $server.Status
    $failed    = @($checks | Where-Object { $_.Outcome -eq 'NonCompliant' })
    $partial   = @($checks | Where-Object { $_.Outcome -eq 'PartiallyCompliant' })
    # On a witness that was never reached, 'Not read' rows are covered by the sentence that says so;
    # every other Unknown still names its own cause, the Trusted Subsystem group's among them.
    $unjudged  = @($checks | Where-Object { $_.Outcome -eq 'Unknown' -and ($contacted -or -not ([string]$_.Cause).StartsWith('Not read:')) })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($server.Status -eq 'NameDoesNotResolve') {
        $problems.Add(("The witness name {0} does not resolve on the assessment host ({1}), so nothing was sent to it and none of its prerequisites was read - check Deployment.WitnessServer for a typo, or whether the host has a DNS record yet" -f `
            $witness, ([string]$server.ResolveError).TrimEnd('.'))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif ($server.Status -eq 'Unreachable') {
        $problems.Add(("The witness {0} resolves ({1}) but answered neither CIM nor WinRM, so none of the checks that read the server ran: CIM: {2}; WinRM: {3}" -f `
            $witness, $server.Addresses, ([string]$server.CimError).TrimEnd('.'), ([string]$server.WinRmError).TrimEnd('.'))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif ($server.Status -eq 'PartiallyRead') {
        $problems.Add(("The witness answered only part of what was asked (CIM {0}, WinRM {1}), so the checks that needed the rest are Unknown and the others stand" -f $server.CimState, $server.WinRmState)) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($failed.Count -gt 0) {
        $problems.Add(("{0} witness checks failed: {1}" -f $failed.Count, (($failed | ForEach-Object { "$($_.Check) (found $($_.Measured); required $($_.Required)) - $(([string]$_.Cause).TrimEnd('.'))" }) -join '; '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($partial.Count -gt 0) {
        $problems.Add(("{0} witness checks are reported for the reader to judge: {1}" -f $partial.Count, (($partial | ForEach-Object { "$($_.Check) ($($_.Measured)) - $(([string]$_.Cause).TrimEnd('.'))" }) -join '; '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($unjudged.Count -gt 0) {
        $problems.Add(("{0} witness checks could not be judged: {1}" -f $unjudged.Count, (($unjudged | ForEach-Object { "$($_.Check) - $(([string]$_.Cause).TrimEnd('.'))" }) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    # Compliant is added only when nothing above fired. Get-ExchWorstOutcome would otherwise let a
    # Compliant check outvote an Unknown one, and an unread prerequisite would pass.
    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Medium' }
        'Unknown'            { 'Medium' }
        default              { 'Low' }
    }

    $applicable = @($checks | Where-Object { $_.Outcome -ne 'NotApplicable' })
    $judged = @($applicable | Where-Object { $_.Outcome -ne 'Unknown' })
    $sufficiency = if ($judged.Count -eq 0) { 'HardFail' }
                   elseif ($judged.Count -lt $applicable.Count) { 'SoftFail' }
                   else { 'Pass' }

    $scope = ("The witness named in Deployment.WitnessServer, {0}, was checked against {1} witness prerequisites ({2} applicable)" -f $witness, $checks.Count, $applicable.Count)
    $rationale = if ($problems.Count -gt 0) { (@($scope) + @($problems.ToArray()) -join '. ') + '.' }
                 else { ('{0}, and every applicable check was read and met.' -f $scope) }

    $cimState = if ($target.CimState -eq 'Succeeded') { 'Success' } elseif ($target.CimState -eq 'Partial') { 'Partial' } else { 'Error' }
    $winRmState = if ($target.WinRmState -eq 'Succeeded') { 'Success' } else { 'Error' }
    $directoryState = switch ($group.State) { 'Found' { 'Success' } 'NotFound' { 'Success' } default { 'Error' } }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome -Sufficiency $sufficiency `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Correct the witness name if it does not resolve and make the witness reachable over CIM and WinRM from the assessment host, then address each failed check: a member server in the assessment''s forest that is not a domain controller and not one of the target servers, with the File Server role and the File and Printer Sharing and WMI firewall exceptions, and - once Active Directory has been prepared for Exchange - the Exchange Trusted Subsystem group in its local Administrators group. https://learn.microsoft.com/exchange/high-availability/manage-ha/manage-dags#creating-dags' `
        -Metrics @{
            witnessServer            = $witness
            witnessDirectory         = $directory
            status                   = $server.Status
            targetCount              = $targets.Count
            checkCount               = $checks.Count
            compliantChecks          = @($checks | Where-Object { $_.Outcome -eq 'Compliant' }).Count
            nonCompliantChecks       = $failed.Count
            partiallyCompliantChecks = $partial.Count
            unknownChecks            = @($checks | Where-Object { $_.Outcome -eq 'Unknown' }).Count
            notApplicableChecks      = @($checks | Where-Object { $_.Outcome -eq 'NotApplicable' }).Count
            trustedSubsystemGroup    = $group.Name
            trustedSubsystemState    = $group.State
            directoryScope           = $group.Scope
            runForest                = $runForest
            server                   = $server
            checks                   = $checks
        } `
        -Meta @{ dataSources = @{
            DeploymentConfig = @{ state = 'Success'; reason = '' }
            CIM              = @{ state = $cimState; reason = [string]$target.CimError }
            WinRM            = @{ state = $winRmState; reason = [string]$target.WinRmError }
            Directory        = @{ state = $directoryState; reason = [string]$group.Error }
        }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchNoWitnessServerReason {
    <#
    The rationale when no witness was supplied. The template path and both commands come from the
    P13 helper the preflight warning uses, so the two cannot drift apart.
    #>
    [CmdletBinding()]
    param()

    return ("No witness server was supplied: Deployment.WitnessServer is empty or absent, so no file share witness was assessed. " +
        "This is the expected state until the deployment plan names one, and it is not an error - the directory cannot name the witness, because the DAG it will serve does not exist yet. " +
        (Get-ExchDeploymentSupplyInstruction -Keys @('WitnessServer')))
}

function Get-ExchWitnessRequirement {
    <#
    The WitnessPrerequisites entries from the run's configuration, by key. A key the configuration
    does not carry is $null, and the check that reads it reports that rather than guessing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $table = Get-ExchThreshold -Run $Run -Name 'WitnessPrerequisites' -Default @{}
    $result = @{}
    foreach ($key in @('MinimumOsVersion', 'ServerProductTypes', 'DomainControllerRoles', 'TrustedSubsystemGroup',
            'FileServerFeature', 'FileAndPrinterSharingFirewallGroup', 'WmiFirewallGroup')) {
        $result[$key] = $null
        if ($table -is [System.Collections.IDictionary] -and $table.Contains($key)) { $result[$key] = $table[$key] }
    }
    return $result
}

function Get-ExchWitnessCimQuery {
    <#
    The CIM classes read from the witness, Win32_OperatingSystem first: Get-ExchTargetState does not
    attempt the rest when it fails. The class names are the ones DEP.TGT-01 reads, so
    New-ExchTargetServerRow describes the witness exactly as it describes a target.
    #>
    [CmdletBinding()]
    param()

    return @(
        @{ Name = 'OperatingSystem'; ClassName = 'Win32_OperatingSystem'; Filter = '' }
        @{ Name = 'ComputerSystem';  ClassName = 'Win32_ComputerSystem';  Filter = '' }
        @{ Name = 'NTDomain';        ClassName = 'Win32_NTDomain';        Filter = '' }
        @{ Name = 'Service';         ClassName = 'Win32_Service';         Filter = "Name = 'MSExchangeServiceHost' OR Name = 'MSExchangeADTopology'" }
    )
}

function Get-ExchWitnessRemoteReader {
    <#
    The WinRM reading of the witness, as it runs ON the witness: the File Server role service, the
    firewall state of each profile and the network profiles in use, the rules of the two firewall
    groups, and the SIDs of the local Administrators group's members. Each item is read in its own
    try, and a failure is returned in Errors under the item's name rather than losing the others.
    It judges nothing. Written for Windows PowerShell 5.1, the default remoting endpoint.
    #>
    [CmdletBinding()]
    param()

    return {
        param($FileServerFeature, $FileSharingGroup, $WmiGroup)

        $errors = @{}

        $fileServer = $null
        try {
            if (-not $FileServerFeature) { throw 'no feature name was supplied' }
            $feature = @(Get-WindowsFeature -Name $FileServerFeature -ErrorAction Stop) | Select-Object -First 1
            if ($null -ne $feature) { $fileServer = [pscustomobject]@{ Name = [string]$feature.Name; InstallState = [string]$feature.InstallState } }
        }
        catch { $errors['FileServer'] = $_.Exception.Message }

        $firewallProfiles = @()
        try {
            $firewallProfiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.Name; Enabled = [string]$_.Enabled }
            })
        }
        catch { $errors['FirewallProfiles'] = $_.Exception.Message }

        $categories = @()
        try { $categories = @(Get-NetConnectionProfile -ErrorAction Stop | ForEach-Object { [string]$_.NetworkCategory } | Sort-Object -Unique) }
        catch { $errors['NetworkCategories'] = $_.Exception.Message }

        $readGroup = {
            param($Group)
            if (-not $Group) { throw 'no firewall rule group was supplied' }
            try {
                @(Get-NetFirewallRule -PolicyStore ActiveStore -Group $Group -ErrorAction Stop | ForEach-Object {
                    [pscustomobject]@{ DisplayName = [string]$_.DisplayName; Enabled = [string]$_.Enabled; Direction = [string]$_.Direction; Profile = [string]$_.Profile }
                })
            }
            catch {
                # A group with no rule is an answer, not a failure; the collector reports it.
                if ([string]$_.CategoryInfo.Category -eq 'ObjectNotFound') { @() } else { throw }
            }
        }
        $fileSharing = @()
        try { $fileSharing = @(& $readGroup $FileSharingGroup) } catch { $errors['FirewallFileSharing'] = $_.Exception.Message }
        $wmi = @()
        try { $wmi = @(& $readGroup $WmiGroup) } catch { $errors['FirewallWmi'] = $_.Exception.Message }

        # The Administrators group by its well-known SID, so a localised name does not matter, and its
        # members by SID, so a member whose name no longer resolves is still listed.
        $administrators = @()
        try {
            $wellKnown = New-Object System.Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-32-544'
            $groupName = ([string]$wellKnown.Translate([System.Security.Principal.NTAccount]).Value -split '\\')[-1]
            $localGroup = [ADSI]('WinNT://./{0},group' -f $groupName)
            $administrators = @(foreach ($member in @($localGroup.psbase.Invoke('Members'))) {
                $type = $member.GetType()
                $bytes = $type.InvokeMember('objectSid', 'GetProperty', $null, $member, $null)
                $path = [string]$type.InvokeMember('ADsPath', 'GetProperty', $null, $member, $null)
                $memberSid = ''
                if ($null -ne $bytes) { $memberSid = (New-Object System.Security.Principal.SecurityIdentifier -ArgumentList ([byte[]]$bytes), 0).Value }
                [pscustomobject]@{ Sid = $memberSid; Path = $path }
            })
        }
        catch { $errors['Administrators'] = $_.Exception.Message }

        [pscustomobject]@{
            FileServer          = $fileServer
            FirewallProfiles    = $firewallProfiles
            NetworkCategories   = $categories
            FirewallFileSharing = $fileSharing
            FirewallWmi         = $wmi
            Administrators      = $administrators
            Errors              = $errors
        }
    }
}

function Get-ExchWitnessCheckDefinition {
    <#
    One definition per witness check: the mechanisms it names, the CIM classes and WinRM items it
    reads, whether Get-ExchTargetMechanismGate decides if it runs, and the Learn page behind it.
    Checks with Gate $false read their own inputs and say themselves what was not read.
    #>
    [CmdletBinding()]
    param()

    $manageDags = 'https://learn.microsoft.com/exchange/high-availability/manage-ha/manage-dags#creating-dags'
    $createDags = 'https://learn.microsoft.com/exchange/high-availability/manage-ha/create-dags'
    $newDag     = 'https://learn.microsoft.com/powershell/module/exchangepowershell/new-databaseavailabilitygroup'
    $azure      = 'https://learn.microsoft.com/exchange/high-availability/manage-ha/azure-vms-as-dag-witness-servers'

    return @(
        @{ Key = 'NameResolves';                  Gate = $false; Mechanisms = @('DNS');                CimClasses = @();                  RemoteItems = @();                                                                Source = @() }
        @{ Key = 'Reachable';                     Gate = $false; Mechanisms = @('CIM', 'WinRM');       CimClasses = @();                  RemoteItems = @();                                                                Source = @() }
        @{ Key = 'DomainMember';                  Gate = $true;  Mechanisms = @('CIM');                CimClasses = @('ComputerSystem');  RemoteItems = @();                                                                Source = @($manageDags) }
        @{ Key = 'SameForest';                    Gate = $true;  Mechanisms = @('CIM');                CimClasses = @('NTDomain');        RemoteItems = @();                                                                Source = @($manageDags) }
        @{ Key = 'OperatingSystem';               Gate = $true;  Mechanisms = @('CIM');                CimClasses = @('OperatingSystem'); RemoteItems = @();                                                                Source = @($manageDags) }
        @{ Key = 'NotDomainController';           Gate = $true;  Mechanisms = @('CIM');                CimClasses = @('ComputerSystem');  RemoteItems = @();                                                                Source = @($newDag, $azure) }
        @{ Key = 'NotExchangeServer';             Gate = $true;  Mechanisms = @('CIM');                CimClasses = @('Service');         RemoteItems = @();                                                                Source = @($createDags) }
        @{ Key = 'NotDagMember';                  Gate = $false; Mechanisms = @('Config', 'DNS');      CimClasses = @();                  RemoteItems = @();                                                                Source = @($manageDags) }
        @{ Key = 'FileServerRole';                Gate = $true;  Mechanisms = @('WinRM');              CimClasses = @();                  RemoteItems = @('FileServer');                                                    Source = @($azure) }
        @{ Key = 'FirewallFileAndPrinterSharing'; Gate = $true;  Mechanisms = @('WinRM');              CimClasses = @();                  RemoteItems = @('FirewallProfiles', 'NetworkCategories', 'FirewallFileSharing');  Source = @($manageDags) }
        @{ Key = 'FirewallWmi';                   Gate = $true;  Mechanisms = @('WinRM');              CimClasses = @();                  RemoteItems = @('FirewallProfiles', 'NetworkCategories', 'FirewallWmi');          Source = @($manageDags) }
        @{ Key = 'TrustedSubsystemGrant';         Gate = $false; Mechanisms = @('Directory', 'WinRM'); CimClasses = @();                  RemoteItems = @('Administrators');                                                Source = @($createDags, $manageDags) }
        @{ Key = 'WitnessDirectory';              Gate = $false; Mechanisms = @('Config');             CimClasses = @();                  RemoteItems = @();                                                                Source = @($newDag, $createDags) }
    )
}

function Invoke-ExchWitnessCheck {
    <#
    Runs one witness check. A gated check whose CIM class or WinRM item was not read is Unknown,
    naming the mechanism and the error, and is never passed to the evaluator.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Definition,
        [Parameter(Mandatory)][ValidateNotNull()][hashtable]$Context
    )

    $row = [ordered]@{
        Server         = $Context.Witness
        Check          = [string]$Definition.Key
        Mechanisms     = (@($Definition.Mechanisms) -join '+')
        MechanismState = ''
        Outcome        = 'Unknown'
        Required       = ''
        Measured       = ''
        Cause          = ''
        Source         = (@($Definition.Source) -join ' ')
    }

    if ($Definition.Gate) {
        $gate = Get-ExchTargetMechanismGate -Target $Context.Target -Definition $Definition
        $row.MechanismState = $gate.MechanismState
        if (@($gate.Blocked).Count -gt 0) {
            $row.Cause = ('Not read: {0}.' -f ((@($gate.Blocked) | ForEach-Object { ([string]$_).TrimEnd('.') }) -join '; '))
            return [pscustomobject]$row
        }
    }

    $result = Test-ExchWitnessCheck -Key ([string]$Definition.Key) -Context $Context
    $row.Outcome  = [string]$result['Outcome']
    $row.Required = [string]$result['Required']
    $row.Measured = [string]$result['Measured']
    $row.Cause    = [string]$result['Cause']
    if ($result.Contains('MechanismState')) { $row.MechanismState = [string]$result['MechanismState'] }
    if ($row.Outcome -eq 'Unknown' -and -not $row.Cause) { $row.Cause = 'The check returned no verdict and no reason.' }
    return [pscustomobject]$row
}

function New-ExchWitnessNoValue {
    <#
    The result for a WitnessPrerequisites key that holds no Value - absent from the configuration,
    or nulled by an override. Nothing is judged against a value that is not there.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key,
        [Parameter()][string]$Measured = ''
    )

    return New-ExchPrereqResult -Outcome 'Unknown' -Measured $Measured -Cause ('No value: WitnessPrerequisites.{0} holds no Value in the run''s configuration, so this check was not judged.' -f $Key)
}

function Test-ExchWitnessCheck {
    <#
    The evaluators. Each is reached only when what it reads was read, and each returns Unknown with a
    cause when the data cannot support a verdict. Every Compliant comes from New-ExchPrereqVerdict,
    so a pass is always the result of a comparison.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key,
        [Parameter(Mandatory)][ValidateNotNull()][hashtable]$Context
    )

    $target = $Context.Target
    $requirements = $Context.Requirements
    $os = @(Get-ExchTargetCimItem -Target $target -Name 'OperatingSystem') | Select-Object -First 1
    $computer = @(Get-ExchTargetCimItem -Target $target -Name 'ComputerSystem') | Select-Object -First 1

    switch ($Key) {

        'NameResolves' {
            $required = 'the name resolves on the assessment host'
            if ($target.Resolved) { return (New-ExchPrereqVerdict -Met $true -Required $required -Measured ('resolves to {0}' -f $target.Addresses)) }
            return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured 'does not resolve' -Cause ('The name {0} does not resolve on the assessment host ({1}), so nothing was sent to it - check Deployment.WitnessServer for a typo, or whether the host has a DNS record yet.' -f $target.Name, ([string]$target.ResolveError).TrimEnd('.')))
        }

        'Reachable' {
            $required = 'CIM and WinRM both answer from the assessment host - which says the reads ran, not that any prerequisite is met'
            $measured = ('CIM {0}, WinRM {1}' -f $target.CimState, $target.WinRmState)
            if (-not $target.Resolved) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause 'Not attempted: the name did not resolve.') }
            $cimAnswered = @('Succeeded', 'Partial') -contains $target.CimState
            $winRmAnswered = $target.WinRmState -eq 'Succeeded'
            if ($cimAnswered -and $winRmAnswered) { return (New-ExchPrereqVerdict -Met $true -Required $required -Measured $measured) }
            $failures = @()
            if (-not $cimAnswered) { $failures += ('CIM: {0}' -f ([string]$target.CimError).TrimEnd('.')) }
            if (-not $winRmAnswered) { $failures += ('WinRM: {0}' -f ([string]$target.WinRmError).TrimEnd('.')) }
            return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause ('The witness resolves but did not answer every mechanism from the assessment host - {0}. The checks that need the missing mechanism are Unknown and the others stand.' -f ($failures -join '; ')))
        }

        'DomainMember' {
            $required = 'a domain member (Win32_ComputerSystem.PartOfDomain True)'
            $member = Get-ExchObjectValue -InputObject $computer -Name 'PartOfDomain'
            if ($null -eq $member) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause 'Win32_ComputerSystem returned no PartOfDomain.') }
            $measured = ('PartOfDomain {0}, domain {1}' -f [bool]$member, [string](Get-ExchObjectValue -InputObject $computer -Name 'Domain' -Default ''))
            return (New-ExchPrereqVerdict -Met ([bool]$member) -Required $required -Measured $measured -FailCause 'The witness is not a domain member, and Learn requires it to be in the same Active Directory forest as the DAG.')
        }

        'SameForest' {
            $required = ('the assessment host''s forest ({0})' -f $Context.Server.RunForest)
            $measured = ('forest {0}' -f $Context.Server.Forest)
            if ($Context.Server.SameForest -eq 'True') { return (New-ExchPrereqVerdict -Met $true -Required $required -Measured $measured) }
            if ($Context.Server.SameForest -eq 'False') { return (New-ExchPrereqVerdict -Met $false -Required $required -Measured $measured -FailCause 'Learn: "The witness server must be in the same Active Directory forest as the DAG."') }
            return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause ('The witness could not be placed in or out of the assessment''s forest: witness forest ''{0}'', assessment host forest ''{1}''.' -f $Context.Server.Forest, $Context.Server.RunForest))
        }

        'OperatingSystem' {
            $minimum = Get-ExchPrereqValue -Entry $requirements['MinimumOsVersion']
            $types = Get-ExchPrereqValue -Entry $requirements['ServerProductTypes']
            $version = [string](Get-ExchObjectValue -InputObject $os -Name 'Version' -Default '')
            $productType = Get-ExchObjectValue -InputObject $os -Name 'ProductType'
            $measured = ('{0} {1}, ProductType {2}' -f [string](Get-ExchObjectValue -InputObject $os -Name 'Caption' -Default ''), $version, [string]$productType).Trim()
            if ($null -eq $minimum) { return (New-ExchWitnessNoValue -Key 'MinimumOsVersion' -Measured $measured) }
            if ($null -eq $types) { return (New-ExchWitnessNoValue -Key 'ServerProductTypes' -Measured $measured) }
            $required = ('a Windows Server edition (ProductType {0}) at version {1} or later' -f (@($types) -join ' or '), [string]$minimum)
            if ($null -eq $productType) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause 'Win32_OperatingSystem returned no ProductType.') }
            $parsed = $null
            try { $parsed = [version]$version } catch { $parsed = $null }
            if ($null -eq $parsed) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause 'Win32_OperatingSystem returned no parseable Version.') }
            $floor = $null
            try { $floor = [version][string]$minimum } catch { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause 'WitnessPrerequisites.MinimumOsVersion is not a version number.') }
            if (@($types | ForEach-Object { [int]$_ }) -notcontains [int]$productType) {
                return (New-ExchPrereqResult -Outcome 'NonCompliant' -Required $required -Measured $measured -Cause ('ProductType {0} is not a server edition, and Learn requires Windows Server 2008 or later.' -f $productType))
            }
            return (New-ExchPrereqVerdict -Met ($parsed -ge $floor) -Required $required -Measured $measured -FailCause 'The operating system is older than the minimum Learn states for a witness.')
        }

        'NotDomainController' {
            $roles = Get-ExchPrereqValue -Entry $requirements['DomainControllerRoles']
            $role = Get-ExchObjectValue -InputObject $computer -Name 'DomainRole'
            $measured = ('DomainRole {0}' -f [string]$role)
            if ($null -eq $roles) { return (New-ExchWitnessNoValue -Key 'DomainControllerRoles' -Measured $measured) }
            $required = ('not a domain controller (DomainRole not {0})' -f (@($roles) -join ' or '))
            if ($null -eq $role) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause 'Win32_ComputerSystem returned no DomainRole.') }
            $isController = @($roles | ForEach-Object { [int]$_ }) -contains [int]$role
            return (New-ExchPrereqVerdict -Met (-not $isController) -Required $required -Measured $measured -FailCause ('The witness is a domain controller (DomainRole {0}). Learn: when the witness is a directory server the Exchange Trusted Subsystem group has to be added to its Builtin\Administrators group (New-DatabaseAvailabilityGroup), and placing the witness share on a domain controller "will result in an unnecessary elevation of privileges. Therefore, it is not a recommended configuration" (Using a Microsoft Azure VM as a DAG witness server).' -f $role))
        }

        'NotExchangeServer' {
            $required = 'not already an Exchange server (no MSExchangeServiceHost or MSExchangeADTopology service)'
            $services = @(Get-ExchTargetCimItem -Target $target -Name 'Service' | ForEach-Object { [string](Get-ExchObjectValue -InputObject $_ -Name 'Name' -Default '') } | Where-Object { $_ })
            if ($services.Count -eq 0) { return (New-ExchPrereqVerdict -Met $true -Required $required -Measured 'no Exchange service found') }
            return (New-ExchPrereqResult -Outcome 'PartiallyCompliant' -Required $required -Measured ('Exchange services present: {0}' -f ($services -join ', ')) -Cause 'The witness already runs Exchange services. Learn does not forbid this - it recommends an Exchange server with Client Access services as the witness - so it is not a failure; it is reported because the deployment config names the witness apart from the target servers, and an Exchange witness must still not be a member of the DAG.')
        }

        'NotDagMember' {
            $membership = $Context.Membership
            $required = 'not one of the servers in Deployment.TargetServers, which will be the DAG members'
            if ([int]$membership.TargetCount -eq 0) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause 'Deployment.TargetServers is empty, so the planned DAG members are not known and the witness could not be compared with them.') }
            if (@($membership.Found).Count -gt 0) {
                return (New-ExchPrereqVerdict -Met $false -Required $required -Measured ('matches {0}' -f (@($membership.Found) -join '; ')) -FailCause 'Learn: "The witness server can''t be a member of the DAG."')
            }
            $measured = ('no match among {0} target servers' -f $membership.TargetCount)
            if (@($membership.Uncompared).Count -gt 0) { $measured = ('{0}; compared by name only for {1}, whose address could not be compared' -f $measured, (@($membership.Uncompared) -join ', ')) }
            return (New-ExchPrereqVerdict -Met $true -Required $required -Measured $measured)
        }

        'FileServerRole' {
            $featureName = Get-ExchPrereqValue -Entry $requirements['FileServerFeature']
            if (-not $featureName) { return (New-ExchWitnessNoValue -Key 'FileServerFeature') }
            $required = ('{0} installed' -f $featureName)
            $feature = Get-ExchTargetRemoteItem -Target $target -Name 'FileServer'
            if ($null -eq $feature) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause ('Get-WindowsFeature returned no feature named {0}.' -f $featureName)) }
            $state = [string](Get-ExchObjectValue -InputObject $feature -Name 'InstallState' -Default '')
            return (New-ExchPrereqVerdict -Met ($state -eq 'Installed') -Required $required -Measured ('{0} {1}' -f $featureName, $state) -FailCause 'The File Server role service is not installed, and Learn''s witness preparation adds the File Server role.')
        }

        'FirewallFileAndPrinterSharing' {
            return (Test-ExchWitnessFirewall -Target $target -Key 'FileAndPrinterSharingFirewallGroup' -GroupEntry $requirements['FileAndPrinterSharingFirewallGroup'] -RulesItem 'FirewallFileSharing' -Label 'File and Printer Sharing')
        }

        'FirewallWmi' {
            return (Test-ExchWitnessFirewall -Target $target -Key 'WmiFirewallGroup' -GroupEntry $requirements['WmiFirewallGroup'] -RulesItem 'FirewallWmi' -Label 'WMI')
        }

        'TrustedSubsystemGrant' { return (Test-ExchWitnessTrustedSubsystem -Context $Context) }

        'WitnessDirectory' {
            $required = 'a local, non-root full path - the NonRootLocalLongFullPath type of New-DatabaseAvailabilityGroup -WitnessDirectory'
            if (-not $Context.Directory) {
                return @{ Outcome = 'NotApplicable'; Required = $required; Measured = 'not supplied'; Cause = 'No witness directory was supplied in Deployment.WitnessDirectory, so there is nothing to check; Exchange creates the default %SystemDrive%\DAGFileShareWitnesses\<DAG FQDN> on the witness (create-dags).' }
            }
            $test = Test-ExchWitnessDirectoryPath -Path $Context.Directory
            return (New-ExchPrereqVerdict -Met ([bool]$test.Valid) -Required $required -Measured $Context.Directory -FailCause ('The path is {0}.' -f $test.Reason))
        }

        default {
            return (New-ExchPrereqResult -Outcome 'Unknown' -Cause ("No check is defined for the witness check '{0}', so it was not evaluated." -f $Key))
        }
    }
}

function Test-ExchWitnessFirewall {
    <#
    One firewall exception, judged on every network profile the witness has in use: met on a
    profile where Windows Firewall is off, or where every inbound rule of the group that applies to
    that profile is enabled. Only Windows Firewall is read; another firewall product is invisible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Target,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key,
        [Parameter()]$GroupEntry,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RulesItem,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label
    )

    $group = Get-ExchPrereqValue -Entry $GroupEntry
    if (-not $group) { return (New-ExchWitnessNoValue -Key $Key) }
    $required = ('on every network profile in use, Windows Firewall off, or every inbound {0} rule (group {1}) that applies to it enabled' -f $Label, $group)

    $firewallProfiles = @(Get-ExchTargetRemoteItem -Target $Target -Name 'FirewallProfiles' | Where-Object { $null -ne $_ })
    $categories = @(Get-ExchTargetRemoteItem -Target $Target -Name 'NetworkCategories' | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $rules = @(Get-ExchTargetRemoteItem -Target $Target -Name $RulesItem | Where-Object { $null -ne $_ })
    if ($categories.Count -eq 0) {
        return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause 'The witness returned no network connection profile, so the firewall profile in use is not known.')
    }

    $inUse = @($categories | ForEach-Object { if ($_ -eq 'DomainAuthenticated') { 'Domain' } else { $_ } } | Sort-Object -Unique)
    $parts = New-Object System.Collections.Generic.List[string]
    $states = New-Object System.Collections.Generic.List[string]
    foreach ($name in $inUse) {
        $firewallProfile = @($firewallProfiles | Where-Object { [string](Get-ExchObjectValue -InputObject $_ -Name 'Name' -Default '') -eq $name }) | Select-Object -First 1
        $enabled = [string](Get-ExchObjectValue -InputObject $firewallProfile -Name 'Enabled' -Default '')
        if (-not $enabled) { $parts.Add(('{0}: firewall state not returned' -f $name)) | Out-Null; $states.Add('Unknown') | Out-Null; continue }
        if ($enabled -eq 'False') { $parts.Add(('{0}: Windows Firewall off' -f $name)) | Out-Null; $states.Add('Met') | Out-Null; continue }
        if ($enabled -ne 'True') { $parts.Add(("{0}: firewall state '{1}'" -f $name, $enabled)) | Out-Null; $states.Add('Unknown') | Out-Null; continue }

        $applies = @($rules | Where-Object {
            $ruleProfile = [string](Get-ExchObjectValue -InputObject $_ -Name 'Profile' -Default '')
            [string](Get-ExchObjectValue -InputObject $_ -Name 'Direction' -Default '') -eq 'Inbound' -and
                ($ruleProfile -eq 'Any' -or @($ruleProfile -split ',\s*') -contains $name)
        })
        if ($applies.Count -eq 0) { $parts.Add(('{0}: firewall on, and no inbound rule of the group applies to it' -f $name)) | Out-Null; $states.Add('Unknown') | Out-Null; continue }
        $on = @($applies | Where-Object { [string](Get-ExchObjectValue -InputObject $_ -Name 'Enabled' -Default '') -eq 'True' })
        $parts.Add(('{0}: firewall on, {1} of {2} inbound rules enabled' -f $name, $on.Count, $applies.Count)) | Out-Null
        if ($on.Count -eq $applies.Count) { $states.Add('Met') | Out-Null }
        elseif ($on.Count -eq 0) { $states.Add('NotMet') | Out-Null }
        else { $states.Add('Partial') | Out-Null }
    }

    $measured = $parts.ToArray() -join '; '
    if ($states -contains 'NotMet') {
        return (New-ExchPrereqResult -Outcome 'NonCompliant' -Required $required -Measured $measured -Cause ('Windows Firewall is on and the {0} exception is not enabled for a profile in use, and Learn requires it on the witness.' -f $Label))
    }
    if ($states -contains 'Partial') {
        return (New-ExchPrereqResult -Outcome 'PartiallyCompliant' -Required $required -Measured $measured -Cause ('Some inbound {0} rules are disabled on a profile in use; which of them the witness needs is not judged here.' -f $Label))
    }
    if ($states -contains 'Unknown') {
        return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause ('The {0} exception could not be judged on every profile in use - no rule of group {1} was found, or a profile''s state was not returned; the group id was read on Windows 11 and may differ on the witness.' -f $Label, $group))
    }
    return (New-ExchPrereqVerdict -Met $true -Required $required -Measured $measured)
}

function Test-ExchWitnessTrustedSubsystem {
    <#
    The Exchange Trusted Subsystem grant, in three states that are never collapsed:
      (a) the group is not in the directory - Unknown, because it does not exist until /PrepareAD
          creates it, and until then there is nothing to check;
      (b) the group exists and is not a member of the witness's local Administrators group -
          NonCompliant;
      (c) the group exists and is a member - Compliant.
    A directory that could not be searched, or a membership that could not be read, is Unknown with
    that cause, never (a) or (b).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()][hashtable]$Context)

    $group = $Context.Group
    $name = [string]$group.Name
    if ($group.State -eq 'NoValue') { return (New-ExchWitnessNoValue -Key 'TrustedSubsystemGroup') }
    $required = ('the {0} group is a member of the witness''s local Administrators group' -f $name)

    if ($group.State -eq 'NotFound') {
        return @{
            Outcome        = 'Unknown'
            Required       = $required
            Measured       = 'state (a): the group is not in the directory'
            MechanismState = 'Directory:Read'
            Cause          = ('The {0} group does not exist in the directory yet (searched {1}). Setup /PrepareAD creates it in the Microsoft Exchange Security Groups OU of the forest root domain, so this is expected before Active Directory has been prepared for Exchange, and is not a failed prerequisite. The grant becomes checkable once /PrepareAD has run and replicated; assess again then.' -f $name, $group.Scope)
        }
    }
    if ($group.State -ne 'Found') {
        return @{
            Outcome        = 'Unknown'
            Required       = $required
            Measured       = 'directory not read'
            MechanismState = 'Directory:Failed'
            Cause          = ('The directory could not be searched for the {0} group, so the grant was not checked: {1}.' -f $name, ([string]$group.Error).TrimEnd('.'))
        }
    }

    $gate = Get-ExchTargetMechanismGate -Target $Context.Target -Definition @{ Mechanisms = @('WinRM'); CimClasses = @(); RemoteItems = @('Administrators') }
    $mechanismState = ('Directory:Read {0}' -f $gate.MechanismState)
    if (@($gate.Blocked).Count -gt 0) {
        return @{
            Outcome        = 'Unknown'
            Required       = $required
            Measured       = 'the group exists in the directory; the witness''s Administrators group was not read'
            MechanismState = $mechanismState
            Cause          = ('The {0} group exists in the directory ({1}), but the witness''s local Administrators group was not read: {2}.' -f $name, $group.DistinguishedName, ((@($gate.Blocked) | ForEach-Object { ([string]$_).TrimEnd('.') }) -join '; '))
        }
    }

    $members = @(Get-ExchTargetRemoteItem -Target $Context.Target -Name 'Administrators' | Where-Object { $null -ne $_ })
    $isMember = @($members | Where-Object { [string](Get-ExchObjectValue -InputObject $_ -Name 'Sid' -Default '') -eq [string]$group.Sid }).Count -gt 0
    if ($isMember) {
        $result = New-ExchPrereqVerdict -Met $true -Required $required -Measured ('state (c): {0} ({1}) is a member of the witness''s local Administrators group' -f $name, $group.Sid)
    }
    else {
        $result = New-ExchPrereqVerdict -Met $false -Required $required `
            -Measured ('state (b): {0} ({1}) exists in the directory and is not among the {2} members of the witness''s local Administrators group' -f $name, $group.Sid, $members.Count) `
            -FailCause ('Learn requires the {0} group in the witness''s local Administrators group before the DAG is created, so that Exchange can create the witness directory and share. Direct membership was compared by SID; membership through a nested group was not evaluated.' -f $name)
    }
    $result['MechanismState'] = $mechanismState
    return $result
}

function Get-ExchWitnessTrustedSubsystem {
    <#
    Looks the Exchange Trusted Subsystem group up in the directory. State is Found, NotFound, Error
    (the search failed, or more than one group holds the name) or NoValue (no group name configured).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][string]$Name = '',
        [Parameter()][string]$ControlId = ''
    )

    $state = [pscustomobject]@{ State = 'NoValue'; Name = $Name; Sid = ''; DistinguishedName = ''; Scope = ''; Error = '' }
    if (-not $Name) { return $state }

    try {
        $lookup = Find-ExchDirectoryGroup -Run $Run -Name $Name
        $state.Scope = [string](Get-ExchPortItem -InputObject $lookup -Name 'Scope')
        $groups = @(Get-ExchPortItem -InputObject $lookup -Name 'Groups' | Where-Object { $null -ne $_ })
        if ($groups.Count -eq 0) { $state.State = 'NotFound'; return $state }
        if ($groups.Count -gt 1) {
            $state.State = 'Error'
            $state.Error = ('more than one group named {0} was found: {1}' -f $Name, (($groups | ForEach-Object { [string](Get-ExchPortItem -InputObject $_ -Name 'DistinguishedName') }) -join '; '))
            return $state
        }
        $state.State = 'Found'
        $state.Sid = [string](Get-ExchPortItem -InputObject $groups[0] -Name 'Sid')
        $state.DistinguishedName = [string](Get-ExchPortItem -InputObject $groups[0] -Name 'DistinguishedName')
    }
    catch {
        $state.State = 'Error'
        $state.Error = [string]$_.Exception.Message
        $null = Write-ExchError -Run $Run -Context ('Directory search for the {0} group' -f $Name) -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning'
    }
    return $state
}

function Get-ExchWitnessDagMembership {
    <#
    Whether the witness is one of the planned DAG members - the servers in Deployment.TargetServers.
    Compared by name (the full name, or the first label when either side was given without a domain)
    and, when both resolve, by address, so an alias of a target is caught too.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Witness,
        [Parameter(Mandatory)][ValidateNotNull()]$Target,
        [Parameter()][string[]]$Targets = @(),
        [Parameter()][string]$ControlId = ''
    )

    $witnessFull = $Witness.TrimEnd('.').ToLowerInvariant()
    $witnessAddresses = @(([string]$Target.Addresses) -split ';' | Where-Object { $_ })
    $found = New-Object System.Collections.Generic.List[string]
    $uncompared = New-Object System.Collections.Generic.List[string]

    foreach ($name in @($Targets)) {
        $full = $name.TrimEnd('.').ToLowerInvariant()
        $shortOnly = -not $full.Contains('.') -or -not $witnessFull.Contains('.')
        if ($full -eq $witnessFull -or ($shortOnly -and $full.Split('.')[0] -eq $witnessFull.Split('.')[0])) {
            $found.Add(('{0} (same name)' -f $name)) | Out-Null
            continue
        }
        if ($witnessAddresses.Count -eq 0) { $uncompared.Add($name) | Out-Null; continue }
        $resolution = $null
        try { $resolution = Resolve-ExchTargetName -Name $name }
        catch {
            $null = Write-ExchError -Run $Run -Context ('Name resolution of {0}' -f $name) -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning'
        }
        if (-not [bool](Get-ExchPortItem -InputObject $resolution -Name 'Resolved')) { $uncompared.Add($name) | Out-Null; continue }
        $shared = @(@(Get-ExchPortItem -InputObject $resolution -Name 'Addresses') | ForEach-Object { [string]$_ } | Where-Object { $witnessAddresses -contains $_ })
        if ($shared.Count -gt 0) { $found.Add(('{0} (same address {1})' -f $name, ($shared -join ', '))) | Out-Null }
    }

    return [pscustomobject]@{ TargetCount = @($Targets).Count; Found = $found.ToArray(); Uncompared = $uncompared.ToArray() }
}

function Test-ExchWitnessDirectoryPath {
    <#
    Whether a witness directory is a local, non-root full path: a drive letter, a backslash and at
    least one folder, with no character a Windows path cannot hold. The type New-DatabaseAvailabilityGroup
    gives -WitnessDirectory is NonRootLocalLongFullPath. The path is on the witness and is only read
    as text: Exchange creates it, so it need not exist yet.
    #>
    [CmdletBinding()]
    param([Parameter()][string]$Path = '')

    if (-not $Path) { return [pscustomobject]@{ Valid = $false; Reason = 'empty' } }
    if ($Path.StartsWith('\\')) { return [pscustomobject]@{ Valid = $false; Reason = 'a network (UNC) path, not a local path' } }
    if ($Path -notmatch '^[A-Za-z]:\\') { return [pscustomobject]@{ Valid = $false; Reason = 'not a full local path beginning with a drive letter and a backslash' } }
    $rest = $Path.Substring(3).Trim('\')
    if (-not $rest) { return [pscustomobject]@{ Valid = $false; Reason = 'the root of a drive' } }
    if ($rest -match '[<>:"|?*\x00-\x1F]') { return [pscustomobject]@{ Valid = $false; Reason = 'holding a character a Windows path cannot contain' } }
    return [pscustomobject]@{ Valid = $true; Reason = '' }
}

function Find-ExchDirectoryGroup {
    <#
    The groups holding a name, searched in a global catalog of the assessment host's forest. The one
    place DEP.WIT-01 reads the directory, so the tests can replace it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )

    Assert-ExchADModule -Run $Run
    $catalog = Get-ExchDirectoryGlobalCatalog
    $filter = '(&(objectCategory=group)(cn={0}))' -f (ConvertTo-ExchLdapFilterValue -Value $Name)
    $groups = @(Get-ADGroup -LDAPFilter $filter -Server $catalog.Server -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Name; DistinguishedName = [string]$_.DistinguishedName; Sid = [string]$_.SID }
    })
    return [pscustomobject]@{ Scope = $catalog.Scope; Groups = $groups }
}

function Get-ExchDirectoryGlobalCatalog {
    <#
    A global catalog of the assessment host's forest, found by DC Locator, and the -Server value that
    searches it on port 3268 - the port that covers every domain in the forest.
    #>
    [CmdletBinding()]
    param()

    $controller = Get-ADDomainController -Discover -Service GlobalCatalog -ErrorAction Stop
    $hostName = [string](@($controller.HostName) | Select-Object -First 1)
    if (-not $hostName) { throw 'DC Locator returned no global catalog for the assessment host''s forest' }
    return [pscustomobject]@{
        Server = ('{0}:3268' -f $hostName)
        Scope  = ('the global catalog {0}:3268, which covers every domain of the assessment host''s forest' -f $hostName)
    }
}

function ConvertTo-ExchLdapFilterValue {
    <#
    Escapes a value for an LDAP filter (RFC 4515), so a name is matched as text and never as syntax.
    #>
    [CmdletBinding()]
    param([Parameter()][string]$Value = '')

    return $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
}

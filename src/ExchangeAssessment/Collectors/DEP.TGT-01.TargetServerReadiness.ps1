<#
DEP.TGT-01 - Prerequisite readiness of the member servers that will become Exchange servers.

Every other collector that inspects servers takes its list from Get-ExchangeServer, so it can only
see machines that are already Exchange servers. A greenfield deployment needs the Exchange Server SE
prerequisites checked on member servers that are not Exchange servers yet. Those cannot be
discovered: the operator names them in Deployment.TargetServers, the P13 deployment config passed
with -ConfigPath, and this collector assesses exactly those names. It never calls
Get-ExchangeServer and never guesses a server from the directory. An empty TargetServers means none
was supplied - not that there are none - and is reported that way.

Every prerequisite figure comes from Config/PrereqTable.psd1, or the copy passed with
-PrereqTablePath, where each value carries the Microsoft Learn page it was read from and the date.
A value Learn does not document is $null there, and its check reports Unknown.

Each name is resolved first. A name that does not resolve is reported as such and nothing is sent
to it, so a typo in the config cannot read as a server that is down. A name that resolves is read
over two mechanisms that fail independently:

  CIM    Get-CimInstance against the server, the ENV.OS-01 pattern: operating system and edition,
         volumes with free space and allocation unit, page file, installed memory, services,
         domain membership and forest, last boot. Each class is its own query, so a class that
         fails costs only the checks that read it.
  WinRM  One Invoke-Command for what CIM cannot reach: the .NET Framework Release value, the
         uninstall registry keys (64-bit and WOW6432Node), Windows features, %ProgramFiles% and the
         pending-restart indicators.

Installed software is read from the uninstall keys, never from the Win32_Product class: querying it
makes Windows Installer run a consistency check that can reconfigure every installed product.

Each check names the mechanisms it needs. A check whose mechanism failed is Unknown with the
mechanism and the error in its cause, and the per-server record says which mechanisms answered, so
a check that failed can be told from one that was never attempted. Nothing unread is a pass: the
control is Compliant only when every check on every server is.

All remote access goes through Resolve-ExchTargetName, Get-ExchTargetCimInstance and
Invoke-ExchTargetCommand, so the tests can replace the network with mocks.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_DEP_TGT_01_TargetServerReadiness {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'DEP.TGT-01'

    # The P13 contract decides whether TargetServers was supplied, so this collector and the
    # preflight warning can never disagree about it.
    $gap = Get-ExchDeploymentConfigGap -Deployment (Get-ExchThreshold -Run $Run -Name 'Deployment')
    $targets = @(Get-ExchDeploymentTargetServer -Run $Run)
    if (@($gap.Missing) -contains 'TargetServers' -or $targets.Count -eq 0) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Severity 'Info' -DataSource 'DeploymentConfig' `
                -Reason (Get-ExchNoTargetServerReason) `
                -Remediation 'For a greenfield deployment, name the member servers that will become Exchange servers in Deployment.TargetServers and pass the file with -ConfigPath. For an assessment of an existing organisation this finding is expected.'
        )
    }

    # Loaded once. A missing or unparseable table throws rather than degrading to "nothing to
    # check", which would look like a clean run.
    try { $table = Get-ExchPrereqTable -Run $Run }
    catch {
        $reason = "The prerequisite table could not be loaded, so no target server was assessed: $($_.Exception.Message)"
        $null = Write-ExchError -Run $Run -Context 'Get-ExchPrereqTable' -ErrorRecord $_ -ControlId $control.controlId
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason -DataSource 'PrereqTable' `
                -Remediation 'Restore src/ExchangeAssessment/Config/PrereqTable.psd1, or pass a valid copy with -PrereqTablePath.'
        )
    }

    $prerequisites = $table.Prerequisites
    $keys = @($prerequisites.Keys | Sort-Object)
    $definitions = @{}
    foreach ($definition in @(Get-ExchPrereqCheckDefinition)) { $definitions[[string]$definition.Key] = $definition }

    $runForest = ''
    $runForestCause = ''
    try { $runForest = [string](Get-ExchRunForestName) }
    catch {
        $runForestCause = "the forest of the host running the assessment could not be read: $($_.Exception.Message)"
        $null = Write-ExchError -Run $Run -Context 'Win32_NTDomain on the assessment host' -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
    }

    $indicatorValue = Get-ExchPrereqValue -Entry (Get-ExchPrereqEntry -Prerequisites $prerequisites -Key 'PendingReboot')
    $rebootIndicators = if ($null -eq $indicatorValue) { @() } else { @($indicatorValue) }

    $serverRows = New-Object System.Collections.Generic.List[object]
    $checkRows  = New-Object System.Collections.Generic.List[object]
    $volumeRows = New-Object System.Collections.Generic.List[object]

    foreach ($name in $targets) {
        $target = Get-ExchTargetState -Run $Run -ComputerName $name -ControlId $control.controlId -RebootIndicators $rebootIndicators
        $serverRows.Add((New-ExchTargetServerRow -Target $target -RunForest $runForest -RunForestCause $runForestCause)) | Out-Null

        foreach ($volume in @(Get-ExchTargetCimItem -Target $target -Name 'Volume')) {
            $volumeRows.Add((New-ExchTargetVolumeRow -Server $name -Volume $volume)) | Out-Null
        }

        foreach ($key in $keys) {
            $definition = $null
            if ($definitions.ContainsKey($key)) { $definition = $definitions[$key] }
            $checkRows.Add((Invoke-ExchPrereqCheck -Key $key -Prerequisites $prerequisites -Definition $definition -Target $target)) | Out-Null
        }
    }

    $servers = @($serverRows.ToArray())
    $checks  = @($checkRows.ToArray())
    $volumes = @($volumeRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'deployment/target-readiness.json' -ContentObject ([ordered]@{
        prereqTable = [ordered]@{ path = $table.Path; tableAsOf = $table.TableAsOf.ToString('yyyy-MM-dd') }
        runForest   = $runForest
        servers     = $servers
        checks      = $checks
        volumes     = $volumes
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'deployment.target-servers' -Title 'Deployment Target Servers' -Area 'Deployment' `
            -Columns @('Server', 'Status', 'Resolves', 'Addresses', 'ResolveError', 'CimState', 'CimError', 'WinRmState', 'WinRmError',
                'PartOfDomain', 'Domain', 'Forest', 'RunForest', 'SameForest', 'DomainRole', 'IsDomainController', 'IsExchangeServer',
                'OperatingSystem', 'LastBoot') `
            -Rows $servers

        New-ExchInventorySection -Run $Run -Key 'deployment.target-prerequisites' -Title 'Deployment Target Prerequisite Checks' -Area 'Deployment' `
            -Columns @('Server', 'Check', 'Mechanisms', 'MechanismState', 'Outcome', 'Required', 'Measured', 'Cause', 'Source') `
            -Rows $checks

        New-ExchInventorySection -Run $Run -Key 'deployment.target-volumes' -Title 'Deployment Target Volumes' -Area 'Deployment' `
            -Columns @('Server', 'Volume', 'DriveLetter', 'FileSystem', 'CapacityGB', 'FreeGB', 'AllocationUnitBytes') `
            -Rows $volumes
    )

    $unresolved   = @($servers | Where-Object { $_.Status -eq 'NameDoesNotResolve' })
    $unreachable  = @($servers | Where-Object { $_.Status -eq 'Unreachable' })
    $partlyRead   = @($servers | Where-Object { $_.Status -eq 'PartiallyRead' })
    $contacted    = @($servers | Where-Object { $_.Status -eq 'Read' -or $_.Status -eq 'PartiallyRead' })
    $notMember    = @($contacted | Where-Object { $_.PartOfDomain -eq 'False' })
    $otherForest  = @($contacted | Where-Object { $_.SameForest -eq 'False' })
    $forestUnread = @($contacted | Where-Object { $_.SameForest -eq 'Unknown' })
    $controllers  = @($contacted | Where-Object { $_.IsDomainController -eq 'True' })
    $exchange     = @($contacted | Where-Object { $_.IsExchangeServer -eq 'True' })

    $contactedNames = @($contacted | ForEach-Object { $_.Server })
    $failedChecks   = @($checks | Where-Object { $_.Outcome -eq 'NonCompliant' })
    $unjudged       = @($checks | Where-Object { $_.Outcome -eq 'Unknown' -and $contactedNames -contains $_.Server })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($unresolved.Count -gt 0) {
        $problems.Add(("{0} supplied names do not resolve, so nothing was sent to them and none of their prerequisites was read - check Deployment.TargetServers for a typo, or whether the host has a DNS record yet: {1}" -f `
            $unresolved.Count, (($unresolved | ForEach-Object { "$($_.Server) ($($_.ResolveError))" }) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($unreachable.Count -gt 0) {
        $problems.Add(("{0} servers resolve but answered neither CIM nor WinRM, so none of their prerequisites was read: {1}" -f `
            $unreachable.Count, (($unreachable | ForEach-Object { "$($_.Server) (CIM: $($_.CimError); WinRM: $($_.WinRmError))" }) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($partlyRead.Count -gt 0) {
        $problems.Add(("{0} servers answered only part of what was asked, so the checks that needed the rest are Unknown: {1}" -f `
            $partlyRead.Count, (($partlyRead | ForEach-Object { "$($_.Server) (CIM $($_.CimState), WinRM $($_.WinRmState))" }) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($notMember.Count -gt 0) {
        $problems.Add(("{0} servers are not domain members, and Exchange is installed only on member servers: {1}" -f `
            $notMember.Count, (($notMember | ForEach-Object { $_.Server }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($otherForest.Count -gt 0) {
        $problems.Add(("{0} servers are joined to a different forest from the host running the assessment ({1}): {2}" -f `
            $otherForest.Count, $runForest, (($otherForest | ForEach-Object { "$($_.Server) in $($_.Forest)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($forestUnread.Count -gt 0) {
        $problems.Add(("{0} servers could not be placed in or out of the assessment's forest: {1}" -f `
            $forestUnread.Count, (($forestUnread | ForEach-Object { "$($_.Server) (forest '$($_.Forest)', assessment host forest '$($_.RunForest)')" }) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($controllers.Count -gt 0) {
        $problems.Add(("{0} target servers are domain controllers; Microsoft recommends installing Exchange only on member servers, and changing a server between member and directory server after Exchange is installed is not supported: {1}" -f `
            $controllers.Count, (($controllers | ForEach-Object { "$($_.Server) (DomainRole $($_.DomainRole))" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($exchange.Count -gt 0) {
        $problems.Add(("{0} target servers already run Exchange services, so they are not servers that will become Exchange servers; their prerequisites were still checked: {1}" -f `
            $exchange.Count, (($exchange | ForEach-Object { $_.Server }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($failedChecks.Count -gt 0) {
        $problems.Add(("{0} prerequisite checks failed: {1}" -f `
            $failedChecks.Count, (($failedChecks | ForEach-Object { "$($_.Server) $($_.Check) (found $($_.Measured); required $($_.Required))" }) -join '; '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($unjudged.Count -gt 0) {
        $problems.Add(("{0} prerequisite checks on servers that were contacted could not be judged: {1}" -f `
            $unjudged.Count, (($unjudged | ForEach-Object { "$($_.Server) $($_.Check) - $(([string]$_.Cause).TrimEnd('.'))" }) -join '; '))) | Out-Null
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

    $judged = @($checks | Where-Object { $_.Outcome -ne 'Unknown' })
    $sufficiency = if ($judged.Count -eq 0) { 'HardFail' }
                   elseif (@($checks | Where-Object { $_.Outcome -eq 'Unknown' }).Count -gt 0) { 'SoftFail' }
                   else { 'Pass' }

    $scope = ("{0} target servers named in Deployment.TargetServers were checked against {1} prerequisites from the table dated {2}" -f `
        $servers.Count, $keys.Count, $table.TableAsOf.ToString('yyyy-MM-dd'))
    $rationale = if ($problems.Count -gt 0) { (@($scope) + @($problems.ToArray()) -join '. ') + '.' }
                 else { ("{0}, and every check on every server was read and met: {1}." -f $scope, (($servers | ForEach-Object { $_.Server }) -join ', ')) }

    $cimState = if (@($servers | Where-Object { $_.CimState -ne 'Succeeded' }).Count -eq 0) { 'Success' } else { 'Partial' }
    $winRmState = if (@($servers | Where-Object { $_.WinRmState -ne 'Succeeded' }).Count -eq 0) { 'Success' } else { 'Partial' }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome -Sufficiency $sufficiency `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Correct the names that do not resolve, make every target reachable over CIM and WinRM from the assessment host, then install the missing prerequisites listed per server - https://learn.microsoft.com/exchange/plan-and-deploy/prerequisites - and re-run. A check that is Unknown because the table holds no Learn-documented value can be judged by passing a verified copy of the table with -PrereqTablePath.' `
        -Metrics @{
            targetCount          = $servers.Count
            readCount            = @($servers | Where-Object { $_.Status -eq 'Read' }).Count
            partiallyReadCount   = $partlyRead.Count
            unreachableCount     = $unreachable.Count
            unresolvedCount      = $unresolved.Count
            unresolvedNames      = @($unresolved | ForEach-Object { $_.Server })
            unreachableNames     = @($unreachable | ForEach-Object { $_.Server })
            prerequisiteCount    = $keys.Count
            checkCount           = $checks.Count
            compliantChecks      = @($checks | Where-Object { $_.Outcome -eq 'Compliant' }).Count
            nonCompliantChecks   = $failedChecks.Count
            unknownChecks        = @($checks | Where-Object { $_.Outcome -eq 'Unknown' }).Count
            prereqTableAsOf      = $table.TableAsOf.ToString('yyyy-MM-dd')
            prereqTablePath      = $table.Path
            runForest            = $runForest
            servers              = $servers
            checks               = $checks
        } `
        -Meta @{ dataSources = @{
            DeploymentConfig = @{ state = 'Success'; reason = '' }
            PrereqTable      = @{ state = 'Success'; reason = $table.Path }
            CIM              = @{ state = $cimState; reason = (@($servers | Where-Object { $_.CimState -ne 'Succeeded' } | ForEach-Object { "$($_.Server): $($_.CimState)" }) -join ', ') }
            WinRM            = @{ state = $winRmState; reason = (@($servers | Where-Object { $_.WinRmState -ne 'Succeeded' } | ForEach-Object { "$($_.Server): $($_.WinRmState)" }) -join ', ') }
        }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchDeploymentTargetServer {
    <#
    The names in Deployment.TargetServers: trimmed, blanks dropped, and a name listed twice kept
    once, in its first spelling.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $seen = @{}
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Get-ExchThreshold -Run $Run -Name 'Deployment.TargetServers' -Default @())) {
        $text = ([string]$item).Trim()
        if (-not $text) { continue }
        $folded = $text.ToLowerInvariant()
        if ($seen.ContainsKey($folded)) { continue }
        $seen[$folded] = $true
        $names.Add($text) | Out-Null
    }
    return $names.ToArray()
}

function Get-ExchNoTargetServerReason {
    <#
    The rationale when no target server was supplied. The template path and both commands come
    from the P13 helper the preflight warning uses, so the two cannot drift apart.
    #>
    [CmdletBinding()]
    param()

    $instruction = Get-ExchDeploymentConfigInstruction
    return ("No target servers were supplied: Deployment.TargetServers is empty or absent, so no server that will become an Exchange server was assessed. " +
        "This does not mean there are no target servers - it means none was named, and the directory cannot name them because they are not Exchange servers yet. " +
        "Template: {0}. Create a copy: {1}. Fill in TargetServers, then pass it back: {2} (or {3})." -f `
        $instruction.Template, $instruction.CreateCommand, $instruction.PassBackScript, $instruction.PassBackRun)
}

function Get-ExchPrereqCheckDefinition {
    <#
    One definition per prerequisite key: the mechanisms the check needs, the CIM classes it reads
    and the items of the WinRM reading it reads. A check is attempted only when every one of those
    was read; otherwise it is Unknown, naming what was not.

    A test holds these keys and the table's keys to the same set.
    #>
    [CmdletBinding()]
    param()

    return @(
        @{ Key = 'OperatingSystemBuild';                Mechanisms = @('CIM');          CimClasses = @('OperatingSystem');                                     RemoteItems = @() }
        @{ Key = 'OperatingSystemEdition';              Mechanisms = @('CIM');          CimClasses = @('OperatingSystem');                                     RemoteItems = @() }
        @{ Key = 'DotNetFrameworkRelease';              Mechanisms = @('CIM', 'WinRM'); CimClasses = @('OperatingSystem');                                     RemoteItems = @('DotNet') }
        @{ Key = 'VisualCppRedistributable2012';        Mechanisms = @('WinRM');        CimClasses = @();                                                      RemoteItems = @('Uninstall') }
        @{ Key = 'VisualCppRedistributable2012Version'; Mechanisms = @('WinRM');        CimClasses = @();                                                      RemoteItems = @('Uninstall') }
        @{ Key = 'VisualCppRedistributable2013';        Mechanisms = @('WinRM');        CimClasses = @();                                                      RemoteItems = @('Uninstall') }
        @{ Key = 'VisualCppRedistributable2013Version'; Mechanisms = @('WinRM');        CimClasses = @();                                                      RemoteItems = @('Uninstall') }
        @{ Key = 'UcmaRuntime';                         Mechanisms = @('WinRM');        CimClasses = @();                                                      RemoteItems = @('Uninstall') }
        @{ Key = 'UcmaRuntimeVersion';                  Mechanisms = @('WinRM');        CimClasses = @();                                                      RemoteItems = @('Uninstall') }
        @{ Key = 'IisUrlRewrite';                       Mechanisms = @('WinRM');        CimClasses = @();                                                      RemoteItems = @('Uninstall') }
        @{ Key = 'WindowsFeatures';                     Mechanisms = @('CIM', 'WinRM'); CimClasses = @('OperatingSystem');                                     RemoteItems = @('Features') }
        @{ Key = 'RemoteRegistryStartMode';             Mechanisms = @('CIM');          CimClasses = @('Service');                                             RemoteItems = @() }
        @{ Key = 'InstallVolumeFreeSpaceGB';            Mechanisms = @('CIM', 'WinRM'); CimClasses = @('Volume');                                              RemoteItems = @('ProgramFiles') }
        @{ Key = 'SystemVolumeFreeSpaceMB';             Mechanisms = @('CIM');          CimClasses = @('OperatingSystem', 'Volume');                           RemoteItems = @() }
        @{ Key = 'QueueVolumeFreeSpaceMB';              Mechanisms = @('CIM', 'WinRM'); CimClasses = @('Volume');                                              RemoteItems = @('ProgramFiles') }
        @{ Key = 'PageFileSize';                        Mechanisms = @('CIM');          CimClasses = @('ComputerSystem', 'PageFileSetting', 'PhysicalMemory'); RemoteItems = @() }
        @{ Key = 'PendingReboot';                       Mechanisms = @('WinRM');        CimClasses = @();                                                      RemoteItems = @('Reboot') }
    )
}

function Get-ExchTargetCimQuery {
    <#
    The CIM classes read from each target, in the order they are read. Win32_OperatingSystem goes
    first: if it fails, the server is not answering CIM and the rest are not attempted.
    #>
    [CmdletBinding()]
    param()

    return @(
        @{ Name = 'OperatingSystem'; ClassName = 'Win32_OperatingSystem'; Filter = '' }
        @{ Name = 'ComputerSystem';  ClassName = 'Win32_ComputerSystem';  Filter = '' }
        @{ Name = 'NTDomain';        ClassName = 'Win32_NTDomain';        Filter = '' }
        @{ Name = 'Volume';          ClassName = 'Win32_Volume';          Filter = 'DriveType = 3' }
        @{ Name = 'PageFileSetting'; ClassName = 'Win32_PageFileSetting'; Filter = '' }
        @{ Name = 'PhysicalMemory';  ClassName = 'Win32_PhysicalMemory';  Filter = '' }
        @{ Name = 'Service';         ClassName = 'Win32_Service';         Filter = "Name = 'RemoteRegistry' OR Name = 'MSExchangeServiceHost' OR Name = 'MSExchangeADTopology'" }
    )
}

function Resolve-ExchTargetName {
    <#
    Resolves one supplied name. Returns Resolved false with the resolver's message rather than
    throwing, because a name that does not resolve is a finding about the config, not a failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name)

    try {
        $addresses = @([System.Net.Dns]::GetHostAddresses($Name) | ForEach-Object { $_.ToString() })
        if ($addresses.Count -eq 0) {
            return [pscustomobject]@{ Resolved = $false; Addresses = @(); Error = 'the resolver returned no address' }
        }
        return [pscustomobject]@{ Resolved = $true; Addresses = $addresses; Error = '' }
    }
    catch {
        return [pscustomobject]@{ Resolved = $false; Addresses = @(); Error = [string]$_.Exception.Message }
    }
}

function Get-ExchTargetCimInstance {
    <#
    The one place a target is read over CIM, as ENV.OS-01 reads its servers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComputerName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClassName,
        [Parameter()][string]$Filter = ''
    )

    if ($Filter) { return @(Get-CimInstance -ClassName $ClassName -Filter $Filter -ComputerName $ComputerName -ErrorAction Stop) }
    return @(Get-CimInstance -ClassName $ClassName -ComputerName $ComputerName -ErrorAction Stop)
}

function Invoke-ExchTargetCommand {
    <#
    The one place a target is read over WinRM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComputerName,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter()][object[]]$ArgumentList = @()
    )

    return Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
}

function Get-ExchRunForestName {
    <#
    The forest of the host running the assessment, read from the same class as each target's:
    Win32_NTDomain.DNSForestName. More than one forest name, or none, is not an answer.
    #>
    [CmdletBinding()]
    param()

    $forest = Resolve-ExchNtDomainForest -Instances @(Get-CimInstance -ClassName Win32_NTDomain -ErrorAction Stop)
    if (-not $forest.Forest) { throw $forest.Cause }
    return $forest.Forest
}

function Resolve-ExchNtDomainForest {
    <#
    Reduces Win32_NTDomain instances to one forest name. Returns an empty Forest and the reason when
    there is none, or more than one.
    #>
    [CmdletBinding()]
    param([Parameter()][object[]]$Instances = @())

    $names = @(@($Instances) | ForEach-Object { [string](Get-ExchObjectValue -InputObject $_ -Name 'DNSForestName' -Default '') } |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('.') } | Sort-Object -Unique)

    if ($names.Count -eq 1) { return [pscustomobject]@{ Forest = $names[0]; Cause = '' } }
    if ($names.Count -eq 0) { return [pscustomobject]@{ Forest = ''; Cause = 'Win32_NTDomain returned no DNSForestName' } }
    return [pscustomobject]@{ Forest = ''; Cause = ('Win32_NTDomain returned more than one DNSForestName: {0}' -f ($names -join ', ')) }
}

function Get-ExchTargetState {
    <#
    Everything read from one target: whether the name resolved, what each CIM class returned or
    why it did not, and the WinRM reading or why there was none. CimState and WinRmState are
    Succeeded, Partial (CIM only), Failed or NotAttempted, and the matching Error says why.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComputerName,
        [Parameter()][string]$ControlId = '',
        [Parameter()][object[]]$RebootIndicators = @()
    )

    $state = [pscustomobject]@{
        Name         = $ComputerName
        Resolved     = $false
        Addresses    = ''
        ResolveError = ''
        CimState     = 'NotAttempted'
        CimError     = ''
        Cim          = @{}
        CimErrors    = @{}
        WinRmState   = 'NotAttempted'
        WinRmError   = ''
        Remote       = $null
    }

    $resolution = $null
    try { $resolution = Resolve-ExchTargetName -Name $ComputerName }
    catch {
        $null = Write-ExchError -Run $Run -Context ('Name resolution of {0}' -f $ComputerName) -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning'
        $resolution = [pscustomobject]@{ Resolved = $false; Addresses = @(); Error = [string]$_.Exception.Message }
    }

    if (-not [bool](Get-ExchObjectValue -InputObject $resolution -Name 'Resolved' -Default $false)) {
        $state.ResolveError = [string](Get-ExchObjectValue -InputObject $resolution -Name 'Error' -Default 'the name did not resolve')
        if (-not $state.ResolveError) { $state.ResolveError = 'the name did not resolve' }
        $state.CimError   = 'not attempted: the name did not resolve'
        $state.WinRmError = 'not attempted: the name did not resolve'
        return $state
    }

    $state.Resolved = $true
    $addressProperty = $resolution.PSObject.Properties.Match('Addresses') | Select-Object -First 1
    if ($addressProperty) { $state.Addresses = (@($addressProperty.Value) -join ';') }

    $queries = @(Get-ExchTargetCimQuery)
    foreach ($query in $queries) {
        if ($query.Name -ne 'OperatingSystem' -and $state.CimErrors.ContainsKey('OperatingSystem')) {
            $state.CimErrors[$query.Name] = ('{0} not attempted: Win32_OperatingSystem, the first CIM query, failed' -f $query.ClassName)
            continue
        }
        try {
            $state.Cim[$query.Name] = @(Get-ExchTargetCimInstance -ComputerName $ComputerName -ClassName $query.ClassName -Filter $query.Filter)
        }
        catch {
            $state.CimErrors[$query.Name] = ('{0} query failed: {1}' -f $query.ClassName, $_.Exception.Message)
            $null = Write-ExchError -Run $Run -Context ('Get-CimInstance {0} on {1}' -f $query.ClassName, $ComputerName) -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning'
        }
    }

    if ($state.CimErrors.Count -eq 0) { $state.CimState = 'Succeeded' }
    elseif ($state.Cim.Count -eq 0) { $state.CimState = 'Failed' }
    else { $state.CimState = 'Partial' }
    $state.CimError = (@($queries | Where-Object { $state.CimErrors.ContainsKey($_.Name) } | ForEach-Object { $state.CimErrors[$_.Name] }) -join '; ')

    try {
        $state.Remote = Read-ExchTargetRemote -ComputerName $ComputerName -RebootIndicators $RebootIndicators
        $state.WinRmState = 'Succeeded'
    }
    catch {
        $state.WinRmState = 'Failed'
        $state.WinRmError = [string]$_.Exception.Message
        $null = Write-ExchError -Run $Run -Context ('Invoke-Command on {0}' -f $ComputerName) -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning'
    }

    return $state
}

function Read-ExchTargetRemote {
    <#
    The WinRM reading: one Invoke-Command returning the .NET Framework Release value, every
    uninstall entry under both uninstall roots, every Windows feature with its install state,
    %ProgramFiles%, and each pending-restart indicator. Each item is read in its own try, and a
    failure is returned in Errors under the item's name rather than losing the others.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComputerName,
        [Parameter()][object[]]$RebootIndicators = @()
    )

    $reader = {
        param($Indicators)

        $errors = @{}

        $dotNetRelease = $null
        $dotNetFullKey = $false
        try {
            $ndp = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
            $dotNetFullKey = Test-Path -LiteralPath $ndp
            if ($dotNetFullKey) {
                $ndpValues = Get-ItemProperty -LiteralPath $ndp -ErrorAction Stop
                if ($null -ne $ndpValues.PSObject.Properties['Release']) { $dotNetRelease = [int]$ndpValues.Release }
            }
        }
        catch { $errors['DotNet'] = $_.Exception.Message }

        $uninstall = @()
        $unreadableEntries = 0
        try {
            $roots = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            )
            $uninstall = @(foreach ($root in $roots) {
                if (-not (Test-Path -LiteralPath $root)) { continue }
                foreach ($entry in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
                    try {
                        $values = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction Stop
                        if ($null -eq $values.PSObject.Properties['DisplayName']) { continue }
                        $version = ''
                        if ($null -ne $values.PSObject.Properties['DisplayVersion']) { $version = [string]$values.DisplayVersion }
                        [pscustomobject]@{ Root = $root; DisplayName = [string]$values.DisplayName; DisplayVersion = $version }
                    }
                    catch { $unreadableEntries++ }
                }
            })
        }
        catch { $errors['Uninstall'] = $_.Exception.Message }

        $features = @()
        try {
            $features = @(Get-WindowsFeature -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.Name; InstallState = [string]$_.InstallState }
            })
        }
        catch { $errors['Features'] = $_.Exception.Message }

        $programFiles = [string]$env:ProgramFiles
        if (-not $programFiles) { $errors['ProgramFiles'] = 'the ProgramFiles environment variable is empty' }

        $reboot = @()
        try {
            $reboot = @(foreach ($indicator in @($Indicators)) {
                $path = [string]$indicator['Path']
                $valueName = [string]$indicator['ValueName']
                $present = $false
                if (Test-Path -LiteralPath $path) {
                    if (-not $valueName) { $present = $true }
                    else {
                        $keyValues = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
                        $present = ($null -ne $keyValues.PSObject.Properties[$valueName])
                    }
                }
                [pscustomobject]@{ Path = $path; ValueName = $valueName; Present = $present }
            })
        }
        catch { $errors['Reboot'] = $_.Exception.Message }

        [pscustomobject]@{
            DotNetRelease     = $dotNetRelease
            DotNetFullKey     = $dotNetFullKey
            Uninstall         = $uninstall
            UnreadableEntries = $unreadableEntries
            Features          = $features
            ProgramFiles      = $programFiles
            Reboot            = $reboot
            Errors            = $errors
        }
    }

    return Invoke-ExchTargetCommand -ComputerName $ComputerName -ScriptBlock $reader -ArgumentList @(, @($RebootIndicators))
}

function Get-ExchTargetCimItem {
    <#
    The instances one CIM class returned for a target, or nothing when it was not read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Target,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )

    if ($Target.Cim.ContainsKey($Name)) { return @($Target.Cim[$Name]) }
    return @()
}

function Get-ExchTargetRemoteItem {
    <#
    One item of the WinRM reading. Collections are returned as they are - the caller wraps the
    result in @() - because Get-ExchObjectValue is for scalars.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Target,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )

    if ($null -eq $Target.Remote) { return $null }
    $property = $Target.Remote.PSObject.Properties.Match($Name) | Select-Object -First 1
    if (-not $property) { return $null }
    return $property.Value
}

function Get-ExchTargetRemoteError {
    <#
    The error the WinRM reading returned for one item, or '' when there was none.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Target,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )

    $errors = Get-ExchTargetRemoteItem -Target $Target -Name 'Errors'
    if ($errors -is [System.Collections.IDictionary] -and $errors.Contains($Name)) { return [string]$errors[$Name] }
    if ($null -ne $errors -and -not ($errors -is [System.Collections.IDictionary])) {
        $property = $errors.PSObject.Properties.Match($Name) | Select-Object -First 1
        if ($property) { return [string]$property.Value }
    }
    return ''
}

function Get-ExchPrereqEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Prerequisites,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key
    )

    if ($Prerequisites -is [System.Collections.IDictionary] -and $Prerequisites.Contains($Key)) { return $Prerequisites[$Key] }
    return $null
}

function Get-ExchPrereqValue {
    <#
    The Value of one table entry. An entry with no Value key reads as $null, the same as one that
    Learn does not document, so a malformed override cannot become a pass.
    #>
    [CmdletBinding()]
    param([Parameter()]$Entry)

    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains('Value')) { return $Entry['Value'] }
    return $null
}

function Get-ExchPrereqField {
    [CmdletBinding()]
    param(
        [Parameter()]$Entry,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )

    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Name)) { return $Entry[$Name] }
    return $null
}

function ConvertTo-ExchBuildKey {
    <#
    major.minor.build of a Windows version string, the form the table keys on.
    #>
    [CmdletBinding()]
    param([Parameter()][string]$Version)

    $parsed = $null
    try { $parsed = [version]$Version } catch { return '' }
    return ('{0}.{1}.{2}' -f $parsed.Major, $parsed.Minor, [Math]::Max($parsed.Build, 0))
}

function Find-ExchUninstallEntry {
    <#
    The uninstall entries whose DisplayName matches a -like pattern.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object[]]$Entries = @(),
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Pattern
    )

    return @(@($Entries) | Where-Object { [string](Get-ExchObjectValue -InputObject $_ -Name 'DisplayName' -Default '') -like $Pattern })
}

function Find-ExchVolumeForPath {
    <#
    The Win32_Volume that holds a path: the one whose Name is the longest prefix of it, so a mount
    point wins over the drive it is mounted on.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object[]]$Volumes = @(),
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path
    )

    $probe = if ($Path.EndsWith('\')) { $Path } else { $Path + '\' }
    $best = $null
    $bestLength = -1
    foreach ($volume in @($Volumes)) {
        $name = [string](Get-ExchObjectValue -InputObject $volume -Name 'Name' -Default '')
        if (-not $name) { continue }
        if (-not $name.EndsWith('\')) { $name = $name + '\' }
        if ($probe.StartsWith($name, [System.StringComparison]::OrdinalIgnoreCase) -and $name.Length -gt $bestLength) {
            $best = $volume
            $bestLength = $name.Length
        }
    }
    return $best
}

function New-ExchPrereqResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Compliant', 'PartiallyCompliant', 'NonCompliant', 'Unknown')][string]$Outcome,
        [Parameter()][string]$Required = '',
        [Parameter()][string]$Measured = '',
        [Parameter()][string]$Cause = ''
    )

    return @{ Outcome = $Outcome; Required = $Required; Measured = $Measured; Cause = $Cause }
}

function New-ExchPrereqVerdict {
    <#
    Compliant when the comparison the caller passes in held, NonCompliant with the cause when it
    did not. Every judged check ends here, so a verdict always comes from a comparison.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Met,
        [Parameter()][string]$Required = '',
        [Parameter()][string]$Measured = '',
        [Parameter()][string]$FailCause = ''
    )

    if ($Met) { return @{ Outcome = 'Compliant'; Required = $Required; Measured = $Measured; Cause = '' } }
    return @{ Outcome = 'NonCompliant'; Required = $Required; Measured = $Measured; Cause = $FailCause }
}

function New-ExchPrereqUndocumented {
    <#
    The result for a table value of $null. The cause says the value is not documented, and the
    measurement is still reported so a reader can see what was found.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]$Entry,
        [Parameter()][string]$Measured = ''
    )

    $note = [string](Get-ExchPrereqField -Entry $Entry -Name 'Note')
    if (-not $note) { $note = 'the table holds no value for this prerequisite' }
    return New-ExchPrereqResult -Outcome 'Unknown' -Measured $Measured -Cause ('No Learn-documented value: {0}' -f $note.TrimEnd('.'))
}

function Invoke-ExchPrereqCheck {
    <#
    Runs one prerequisite check on one target. The mechanisms the check needs are confirmed first:
    a check whose CIM class or WinRM item was not read is Unknown, naming the mechanism and the
    error, and is never passed to the evaluator.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key,
        [Parameter(Mandatory)][ValidateNotNull()]$Prerequisites,
        [Parameter()]$Definition,
        [Parameter(Mandatory)][ValidateNotNull()]$Target
    )

    $entry = Get-ExchPrereqEntry -Prerequisites $Prerequisites -Key $Key
    $source = (@(Get-ExchPrereqField -Entry $entry -Name 'Source') | Where-Object { $_ }) -join ' '

    $row = [ordered]@{
        Server         = $Target.Name
        Check          = $Key
        Mechanisms     = ''
        MechanismState = ''
        Outcome        = 'Unknown'
        Required       = ''
        Measured       = ''
        Cause          = ''
        Source         = $source
    }

    if ($null -eq $Definition) {
        $row.Cause = ("No check is defined for the prerequisite key '{0}', so it was not evaluated." -f $Key)
        return [pscustomobject]$row
    }

    $mechanisms = @($Definition.Mechanisms)
    $row.Mechanisms = ($mechanisms -join '+')
    $states = New-Object System.Collections.Generic.List[string]
    $blocked = New-Object System.Collections.Generic.List[string]

    if ($mechanisms -contains 'CIM') {
        $missing = @(@($Definition.CimClasses) | Where-Object { -not $Target.Cim.ContainsKey($_) })
        if ($Target.CimState -eq 'NotAttempted') {
            $states.Add('CIM:NotAttempted') | Out-Null
            $blocked.Add(('CIM was not attempted on {0} ({1})' -f $Target.Name, $Target.CimError)) | Out-Null
        }
        elseif ($missing.Count -gt 0) {
            $states.Add('CIM:Failed') | Out-Null
            $blocked.Add(('CIM on {0}: {1}' -f $Target.Name, (($missing | ForEach-Object { $Target.CimErrors[$_] }) -join '; '))) | Out-Null
        }
        else { $states.Add('CIM:Read') | Out-Null }
    }

    if ($mechanisms -contains 'WinRM') {
        if ($Target.WinRmState -eq 'NotAttempted') {
            $states.Add('WinRM:NotAttempted') | Out-Null
            $blocked.Add(('WinRM was not attempted on {0} ({1})' -f $Target.Name, $Target.WinRmError)) | Out-Null
        }
        elseif ($Target.WinRmState -ne 'Succeeded') {
            $states.Add('WinRM:Failed') | Out-Null
            $blocked.Add(('WinRM (Invoke-Command) to {0} failed: {1}' -f $Target.Name, $Target.WinRmError)) | Out-Null
        }
        else {
            $itemErrors = @(@($Definition.RemoteItems) | ForEach-Object {
                $message = Get-ExchTargetRemoteError -Target $Target -Name $_
                if ($message) { '{0}: {1}' -f $_, $message }
            })
            if ($itemErrors.Count -gt 0) {
                $states.Add('WinRM:Failed') | Out-Null
                $blocked.Add(('WinRM read on {0} failed for {1}' -f $Target.Name, ($itemErrors -join '; '))) | Out-Null
            }
            else { $states.Add('WinRM:Read') | Out-Null }
        }
    }

    $row.MechanismState = ($states.ToArray() -join ' ')
    if ($blocked.Count -gt 0) {
        $row.Cause = ('Not read: {0}.' -f (($blocked.ToArray() | ForEach-Object { ([string]$_).TrimEnd('.') }) -join '; '))
        return [pscustomobject]$row
    }

    $result = Test-ExchPrereqCheck -Key $Key -Entry $entry -Prerequisites $Prerequisites -Target $Target
    $row.Outcome  = [string]$result.Outcome
    $row.Required = [string]$result.Required
    $row.Measured = [string]$result.Measured
    $row.Cause    = [string]$result.Cause
    if ($row.Outcome -eq 'Unknown' -and -not $row.Cause) { $row.Cause = 'The check returned no verdict and no reason.' }
    return [pscustomobject]$row
}

function Test-ExchPrereqCheck {
    <#
    The evaluators. Each is reached only when the data it reads was read, and each returns Unknown
    with a cause when the data it was handed cannot support a verdict.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key,
        [Parameter()]$Entry,
        [Parameter(Mandatory)][ValidateNotNull()]$Prerequisites,
        [Parameter(Mandatory)][ValidateNotNull()]$Target
    )

    $value = Get-ExchPrereqValue -Entry $Entry
    $os = @(Get-ExchTargetCimItem -Target $Target -Name 'OperatingSystem') | Select-Object -First 1
    $osVersion = [string](Get-ExchObjectValue -InputObject $os -Name 'Version' -Default '')
    $osBuild = ConvertTo-ExchBuildKey -Version $osVersion

    switch ($Key) {

        'OperatingSystemBuild' {
            $caption = [string](Get-ExchObjectValue -InputObject $os -Name 'Caption' -Default '')
            $measured = ('{0} ({1})' -f $caption, $osVersion).Trim()
            if ($null -eq $value) { return (New-ExchPrereqUndocumented -Entry $Entry -Measured $measured) }
            $required = 'one of ' + (@($value) -join ', ')
            if (-not $osBuild) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause 'Win32_OperatingSystem returned no parseable Version.') }
            return (New-ExchPrereqVerdict -Met (@($value) -contains $osBuild) -Required $required -Measured $measured -FailCause 'Build is not one the supportability matrix lists for Exchange Server SE.')
        }

        'OperatingSystemEdition' {
            $sku = Get-ExchObjectValue -InputObject $os -Name 'OperatingSystemSKU'
            $measured = if ($null -eq $sku) { '' } else { 'OperatingSystemSKU ' + [string]$sku }
            if ($null -eq $value) { return (New-ExchPrereqUndocumented -Entry $Entry -Measured $measured) }
            $required = 'OperatingSystemSKU one of ' + (@($value) -join ', ')
            if ($null -eq $sku) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause 'Win32_OperatingSystem returned no OperatingSystemSKU.') }
            return (New-ExchPrereqVerdict -Met (@($value | ForEach-Object { [int]$_ }) -contains [int]$sku) -Required $required -Measured $measured -FailCause 'Edition is not Standard or Datacenter.')
        }

        'DotNetFrameworkRelease' {
            $release = Get-ExchTargetRemoteItem -Target $Target -Name 'DotNetRelease'
            $fullKey = [bool](Get-ExchTargetRemoteItem -Target $Target -Name 'DotNetFullKey')
            $measured = if ($null -ne $release) { 'Release ' + [string]$release } elseif ($fullKey) { 'NDP\v4\Full present, no Release value' } else { 'NDP\v4\Full absent' }
            if ($null -eq $value) { return (New-ExchPrereqUndocumented -Entry $Entry -Measured $measured) }
            if (-not ($value -is [System.Collections.IDictionary]) -or -not $osBuild -or -not $value.Contains($osBuild)) {
                return (New-ExchPrereqResult -Outcome 'Unknown' -Measured $measured -Cause ('The table has no .NET Framework row for operating system build {0}.' -f $osBuild))
            }
            $minimum = $value[$osBuild]
            if ($null -eq $minimum) { return (New-ExchPrereqUndocumented -Entry $Entry -Measured $measured) }
            $required = 'Release >= ' + [string]$minimum
            if (-not $fullKey) { return (New-ExchPrereqResult -Outcome 'NonCompliant' -Required $required -Measured $measured -Cause 'HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full is absent, so .NET Framework 4.5 or later is not installed.') }
            if ($null -eq $release) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause 'NDP\v4\Full carries no Release value.') }
            return (New-ExchPrereqVerdict -Met ([int]$release -ge [int]$minimum) -Required $required -Measured $measured -FailCause 'Release value is below the minimum for this operating system.')
        }

        { $_ -in @('VisualCppRedistributable2012', 'VisualCppRedistributable2013', 'UcmaRuntime', 'IisUrlRewrite') } {
            $entries = @(Get-ExchTargetRemoteItem -Target $Target -Name 'Uninstall')
            if ($null -eq $value) { return (New-ExchPrereqUndocumented -Entry $Entry -Measured ('{0} uninstall entries read' -f $entries.Count)) }
            $required = "an uninstall entry named like '$value'"
            if ($entries.Count -eq 0) {
                return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured '0 uninstall entries read' -Cause 'The uninstall keys returned no entries at all, which is not a reading of an installed server.')
            }
            $found = @(Find-ExchUninstallEntry -Entries $entries -Pattern ([string]$value))
            $measured = if ($found.Count -gt 0) { ($found | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)".Trim() }) -join '; ' }
                        else { 'no match in {0} uninstall entries under both roots' -f $entries.Count }
            return (New-ExchPrereqVerdict -Met ($found.Count -gt 0) -Required $required -Measured $measured -FailCause 'Not installed.')
        }

        { $_ -in @('VisualCppRedistributable2012Version', 'VisualCppRedistributable2013Version', 'UcmaRuntimeVersion') } {
            $entries = @(Get-ExchTargetRemoteItem -Target $Target -Name 'Uninstall')
            $packageKey = [string](Get-ExchPrereqField -Entry $Entry -Name 'PackageKey')
            $pattern = $null
            if ($packageKey) { $pattern = Get-ExchPrereqValue -Entry (Get-ExchPrereqEntry -Prerequisites $Prerequisites -Key $packageKey) }
            $found = @()
            if ($pattern) { $found = @(Find-ExchUninstallEntry -Entries $entries -Pattern ([string]$pattern)) }
            $measured = if ($found.Count -gt 0) { ($found | ForEach-Object { [string]$_.DisplayVersion }) -join '; ' } else { '' }
            if ($null -eq $value) { return (New-ExchPrereqUndocumented -Entry $Entry -Measured $measured) }
            $required = '>= ' + [string]$value
            if (-not $pattern) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause ('The package itself cannot be identified: {0} has no value.' -f $packageKey)) }
            if ($found.Count -eq 0) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause ('The package was not found, so there is no version to judge (see {0}).' -f $packageKey)) }
            $minimum = $null
            try { $minimum = [version][string]$value } catch { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause 'The table value is not a version number.') }
            $parsed = @($found | ForEach-Object { $v = $null; try { $v = [version][string]$_.DisplayVersion } catch { $v = $null }; $v } | Where-Object { $null -ne $_ })
            if ($parsed.Count -eq 0) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause 'DisplayVersion is not a version number.') }
            return (New-ExchPrereqVerdict -Met (@($parsed | Where-Object { $_ -ge $minimum }).Count -gt 0) -Required $required -Measured $measured -FailCause 'Installed version is below the minimum.')
        }

        'WindowsFeatures' {
            $features = @(Get-ExchTargetRemoteItem -Target $Target -Name 'Features')
            if ($null -eq $value) { return (New-ExchPrereqUndocumented -Entry $Entry -Measured ('{0} features read' -f $features.Count)) }
            if ($features.Count -eq 0) { return (New-ExchPrereqResult -Outcome 'Unknown' -Measured '0 features read' -Cause 'Get-WindowsFeature returned no features, which is not a reading of a Windows Server.') }

            $installed = @($features | Where-Object { [string](Get-ExchObjectValue -InputObject $_ -Name 'InstallState' -Default '') -eq 'Installed' } |
                ForEach-Object { [string](Get-ExchObjectValue -InputObject $_ -Name 'Name' -Default '') })
            $desktop = @(Get-ExchPrereqField -Entry @{ Value = $value } -Name 'Value' | ForEach-Object { $_['DesktopExperience'] })
            $core    = @(Get-ExchPrereqField -Entry @{ Value = $value } -Name 'Value' | ForEach-Object { $_['ServerCore'] })
            $common  = @($core | Where-Object { $desktop -contains $_ })

            $bySku = Get-ExchPrereqField -Entry $Entry -Name 'InstallationOptionBySku'
            $sku = Get-ExchObjectValue -InputObject $os -Name 'OperatingSystemSKU'
            $option = ''
            if ($bySku -is [System.Collections.IDictionary] -and $null -ne $sku) {
                if (@($bySku['DesktopExperience'] | ForEach-Object { [int]$_ }) -contains [int]$sku) { $option = 'DesktopExperience' }
                elseif (@($bySku['ServerCore'] | ForEach-Object { [int]$_ }) -contains [int]$sku) { $option = 'ServerCore' }
            }

            $requiredList = if ($option -eq 'DesktopExperience') { $desktop } elseif ($option -eq 'ServerCore') { $core } else { $common }
            $missing = @($requiredList | Where-Object { $installed -notcontains $_ })
            $label = if ($option) { $option } else { 'installation option not determined' }
            $required = ('{0} features for {1}' -f $requiredList.Count, $label)
            $measured = ('{0} of {1} installed' -f ($requiredList.Count - $missing.Count), $requiredList.Count)

            if ($missing.Count -gt 0) {
                return (New-ExchPrereqResult -Outcome 'NonCompliant' -Required $required -Measured $measured -Cause ('Missing: {0}.' -f ($missing -join ', ')))
            }
            if (-not $option) {
                $unjudged = @($desktop | Where-Object { $common -notcontains $_ })
                return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause ('OperatingSystemSKU {0} maps to no installation option in the table, so the Desktop Experience-only features were not judged: {1}.' -f [string]$sku, ($unjudged -join ', ')))
            }
            return (New-ExchPrereqVerdict -Met ($missing.Count -eq 0) -Required $required -Measured $measured -FailCause 'Features are missing.')
        }

        'RemoteRegistryStartMode' {
            $serviceName = [string](Get-ExchPrereqField -Entry $Entry -Name 'ServiceName')
            if (-not $serviceName) { $serviceName = 'RemoteRegistry' }
            $service = @(Get-ExchTargetCimItem -Target $Target -Name 'Service' | Where-Object { [string](Get-ExchObjectValue -InputObject $_ -Name 'Name' -Default '') -eq $serviceName }) | Select-Object -First 1
            $startMode = [string](Get-ExchObjectValue -InputObject $service -Name 'StartMode' -Default '')
            $measured = if ($service) { ('StartMode {0}, State {1}' -f $startMode, [string](Get-ExchObjectValue -InputObject $service -Name 'State' -Default '')) } else { 'service not present' }
            if ($null -eq $value) { return (New-ExchPrereqUndocumented -Entry $Entry -Measured $measured) }
            $required = ('{0} StartMode {1}' -f $serviceName, [string]$value)
            if (-not $service) { return (New-ExchPrereqResult -Outcome 'NonCompliant' -Required $required -Measured $measured -Cause ('Win32_Service returned no service named {0}.' -f $serviceName)) }
            if (-not $startMode) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause 'Win32_Service returned no StartMode.') }
            return (New-ExchPrereqVerdict -Met ($startMode -eq [string]$value) -Required $required -Measured $measured -FailCause 'Remote Registry must be Automatic and must not be Disabled.')
        }

        { $_ -in @('InstallVolumeFreeSpaceGB', 'SystemVolumeFreeSpaceMB', 'QueueVolumeFreeSpaceMB') } {
            $volumes = @(Get-ExchTargetCimItem -Target $Target -Name 'Volume')
            if ($Key -eq 'SystemVolumeFreeSpaceMB') {
                $path = [string](Get-ExchObjectValue -InputObject $os -Name 'SystemDrive' -Default '')
                $pathLabel = 'SystemDrive'
            }
            else {
                $path = [string](Get-ExchTargetRemoteItem -Target $Target -Name 'ProgramFiles')
                $pathLabel = '%ProgramFiles%'
            }
            $unit = if ($Key -eq 'InstallVolumeFreeSpaceGB') { 1GB } else { 1MB }
            $unitName = if ($Key -eq 'InstallVolumeFreeSpaceGB') { 'GB' } else { 'MB' }

            $volume = $null
            if ($path) { $volume = Find-ExchVolumeForPath -Volumes $volumes -Path $path }
            $freeBytes = Get-ExchObjectValue -InputObject $volume -Name 'FreeSpace'
            $measured = if ($null -ne $freeBytes) { ('{0} {1} free on {2} ({3} {4})' -f [math]::Round([double]$freeBytes / $unit, 1), $unitName, [string](Get-ExchObjectValue -InputObject $volume -Name 'Name' -Default ''), $pathLabel, $path) } else { '' }
            if ($null -eq $value) { return (New-ExchPrereqUndocumented -Entry $Entry -Measured $measured) }
            $required = ('>= {0} {1} free' -f [string]$value, $unitName)
            if (-not $path) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause ('{0} was not returned, so the volume could not be identified.' -f $pathLabel)) }
            if ($null -eq $volume) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause ('No fixed volume returned by Win32_Volume holds {0}.' -f $path)) }
            if ($null -eq $freeBytes) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause 'Win32_Volume returned no FreeSpace for that volume.') }
            return (New-ExchPrereqVerdict -Met ([double]$freeBytes -ge ([double]$value * $unit)) -Required $required -Measured $measured -FailCause 'Not enough free space.')
        }

        'PageFileSize' {
            $computer = @(Get-ExchTargetCimItem -Target $Target -Name 'ComputerSystem') | Select-Object -First 1
            $automatic = Get-ExchObjectValue -InputObject $computer -Name 'AutomaticManagedPagefile'
            $pageFiles = @(Get-ExchTargetCimItem -Target $Target -Name 'PageFileSetting')
            $capacities = @(Get-ExchTargetCimItem -Target $Target -Name 'PhysicalMemory' | ForEach-Object { Get-ExchObjectValue -InputObject $_ -Name 'Capacity' } | Where-Object { $null -ne $_ })
            $installedMb = $null
            if ($capacities.Count -gt 0) { $installedMb = [double]((($capacities | ForEach-Object { [double]$_ }) | Measure-Object -Sum).Sum) / 1MB }
            $sizes = @($pageFiles | ForEach-Object { '{0} initial {1} MB, maximum {2} MB' -f [string](Get-ExchObjectValue -InputObject $_ -Name 'Name' -Default ''), [string](Get-ExchObjectValue -InputObject $_ -Name 'InitialSize' -Default ''), [string](Get-ExchObjectValue -InputObject $_ -Name 'MaximumSize' -Default '') })
            $measured = ('installed memory {0} MB; automatic management {1}; {2}' -f $(if ($null -ne $installedMb) { [math]::Round($installedMb, 0) } else { 'unread' }), [string]$automatic, $(if ($sizes.Count -gt 0) { $sizes -join '; ' } else { 'no page file setting' }))
            if ($null -eq $value) { return (New-ExchPrereqUndocumented -Entry $Entry -Measured $measured) }
            if ($null -eq $installedMb -or $installedMb -le 0) { return (New-ExchPrereqResult -Outcome 'Unknown' -Measured $measured -Cause 'Win32_PhysicalMemory returned no Capacity, so installed memory is unknown.') }
            $expected = $installedMb * [double]$value / 100
            $low = [math]::Floor($expected)
            $high = [math]::Ceiling($expected)
            $required = ('initial = maximum = {0} MB ({1}% of installed memory)' -f [math]::Round($expected, 0), [string]$value)
            if ($null -eq $automatic) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause 'Win32_ComputerSystem returned no AutomaticManagedPagefile.') }
            if ([bool]$automatic) { return (New-ExchPrereqResult -Outcome 'NonCompliant' -Required $required -Measured $measured -Cause 'The page file is system managed, so its size is not fixed.') }
            if ($pageFiles.Count -eq 0) { return (New-ExchPrereqResult -Outcome 'NonCompliant' -Required $required -Measured $measured -Cause 'No page file is configured.') }
            if ($pageFiles.Count -gt 1) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause ('{0} page files are configured, and the rule Learn states is for one.' -f $pageFiles.Count)) }
            $initial = Get-ExchObjectValue -InputObject $pageFiles[0] -Name 'InitialSize'
            $maximum = Get-ExchObjectValue -InputObject $pageFiles[0] -Name 'MaximumSize'
            if ($null -eq $initial -or $null -eq $maximum) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause 'Win32_PageFileSetting returned no InitialSize or MaximumSize.') }
            if ([double]$initial -ne [double]$maximum) { return (New-ExchPrereqResult -Outcome 'NonCompliant' -Required $required -Measured $measured -Cause 'Minimum and maximum differ.') }
            return (New-ExchPrereqVerdict -Met ([double]$initial -ge $low -and [double]$initial -le $high) -Required $required -Measured $measured -FailCause ('Size is not {0}% of installed memory.' -f [string]$value))
        }

        'PendingReboot' {
            $readings = @(Get-ExchTargetRemoteItem -Target $Target -Name 'Reboot')
            $present = @($readings | Where-Object { [bool](Get-ExchObjectValue -InputObject $_ -Name 'Present' -Default $false) })
            $measured = if ($present.Count -gt 0) { 'present: ' + (($present | ForEach-Object { "$($_.Path) $($_.ValueName)".Trim() }) -join '; ') } else { ('{0} indicators read, none present' -f $readings.Count) }
            if ($null -eq $value) { return (New-ExchPrereqUndocumented -Entry $Entry -Measured $measured) }
            $expected = @($value).Count
            $required = ('none of {0} pending-restart indicators present' -f $expected)
            if ($readings.Count -ne $expected) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Measured $measured -Cause ('{0} of {1} indicators came back.' -f $readings.Count, $expected)) }
            return (New-ExchPrereqVerdict -Met ($present.Count -eq 0) -Required $required -Measured $measured -FailCause 'A restart is pending, and Exchange Setup will not continue until it is done.')
        }

        default {
            return (New-ExchPrereqResult -Outcome 'Unknown' -Cause ("No check is defined for the prerequisite key '{0}', so it was not evaluated." -f $Key))
        }
    }
}

function New-ExchTargetServerRow {
    <#
    One row per target: how far it was reached and what it is. The tri-state columns hold True,
    False or Unknown, so a value that was not read never looks like a False.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Target,
        [Parameter()][string]$RunForest = '',
        [Parameter()][string]$RunForestCause = ''
    )

    $status = if (-not $Target.Resolved) { 'NameDoesNotResolve' }
              elseif ($Target.CimState -eq 'Failed' -and $Target.WinRmState -eq 'Failed') { 'Unreachable' }
              elseif ($Target.CimState -ne 'Succeeded' -or $Target.WinRmState -ne 'Succeeded') { 'PartiallyRead' }
              else { 'Read' }

    $os = @(Get-ExchTargetCimItem -Target $Target -Name 'OperatingSystem') | Select-Object -First 1
    $computer = @(Get-ExchTargetCimItem -Target $Target -Name 'ComputerSystem') | Select-Object -First 1

    $partOfDomain = 'Unknown'
    $domain = ''
    $domainRole = ''
    $isController = 'Unknown'
    if ($Target.Cim.ContainsKey('ComputerSystem') -and $computer) {
        $member = Get-ExchObjectValue -InputObject $computer -Name 'PartOfDomain'
        if ($null -ne $member) { $partOfDomain = [string][bool]$member }
        $domain = [string](Get-ExchObjectValue -InputObject $computer -Name 'Domain' -Default '')
        $role = Get-ExchObjectValue -InputObject $computer -Name 'DomainRole'
        if ($null -ne $role) {
            $domainRole = [string]$role
            $isController = [string](@(4, 5) -contains [int]$role)
        }
    }

    $forest = ''
    $sameForest = 'Unknown'
    if ($Target.Cim.ContainsKey('NTDomain')) {
        $resolved = Resolve-ExchNtDomainForest -Instances @(Get-ExchTargetCimItem -Target $Target -Name 'NTDomain')
        $forest = if ($resolved.Forest) { $resolved.Forest } else { $resolved.Cause }
        if ($resolved.Forest -and $RunForest) { $sameForest = [string]($resolved.Forest -eq $RunForest) }
    }

    $isExchange = 'Unknown'
    if ($Target.Cim.ContainsKey('Service')) {
        $exchangeServices = @(Get-ExchTargetCimItem -Target $Target -Name 'Service' | Where-Object {
            @('MSExchangeServiceHost', 'MSExchangeADTopology') -contains [string](Get-ExchObjectValue -InputObject $_ -Name 'Name' -Default '')
        })
        $isExchange = [string]($exchangeServices.Count -gt 0)
    }

    return [pscustomobject]@{
        Server             = $Target.Name
        Status             = $status
        Resolves           = [string][bool]$Target.Resolved
        Addresses          = $Target.Addresses
        ResolveError       = $Target.ResolveError
        CimState           = $Target.CimState
        CimError           = $Target.CimError
        WinRmState         = $Target.WinRmState
        WinRmError         = $Target.WinRmError
        PartOfDomain       = $partOfDomain
        Domain             = $domain
        Forest             = $forest
        RunForest          = $(if ($RunForest) { $RunForest } else { $RunForestCause })
        SameForest         = $sameForest
        DomainRole         = $domainRole
        IsDomainController = $isController
        IsExchangeServer   = $isExchange
        OperatingSystem    = ('{0} {1}' -f [string](Get-ExchObjectValue -InputObject $os -Name 'Caption' -Default ''), [string](Get-ExchObjectValue -InputObject $os -Name 'Version' -Default '')).Trim()
        LastBoot           = Get-ExchObjectValue -InputObject $os -Name 'LastBootUpTime'
    }
}

function New-ExchTargetVolumeRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)]$Volume
    )

    $capacity = Get-ExchObjectValue -InputObject $Volume -Name 'Capacity'
    $free = Get-ExchObjectValue -InputObject $Volume -Name 'FreeSpace'
    return [pscustomobject]@{
        Server              = $Server
        Volume              = [string](Get-ExchObjectValue -InputObject $Volume -Name 'Name' -Default '')
        DriveLetter         = [string](Get-ExchObjectValue -InputObject $Volume -Name 'DriveLetter' -Default '')
        FileSystem          = [string](Get-ExchObjectValue -InputObject $Volume -Name 'FileSystem' -Default '')
        CapacityGB          = $(if ($null -ne $capacity) { [math]::Round([double]$capacity / 1GB, 1) } else { $null })
        FreeGB              = $(if ($null -ne $free) { [math]::Round([double]$free / 1GB, 1) } else { $null })
        AllocationUnitBytes = Get-ExchObjectValue -InputObject $Volume -Name 'BlockSize'
    }
}

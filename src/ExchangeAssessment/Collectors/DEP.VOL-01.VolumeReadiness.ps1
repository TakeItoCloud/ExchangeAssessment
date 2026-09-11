<#
DEP.VOL-01 - The database and log volumes on the member servers that will become Exchange servers.

The P13 template promises DatabaseVolume and LogVolume: the volume - a drive letter or a mount point
path - that will hold the mailbox databases, and the one that will hold the transaction logs, on each
target server. Neither can be discovered, because the databases do not exist yet, so this collector
reads Deployment.TargetServers, Deployment.DatabaseVolume and Deployment.LogVolume and nothing else.
With no target server, or neither volume, it reports one Unknown finding naming the keys that are
missing and contacts nothing.

On each target, for each supplied volume, four checks, judged against Config/Thresholds.psd1
DeploymentVolumes, where every value carries the Learn page it was read from and the date:

  VolumeExists        a volume is mounted at exactly that path (Win32_Volume.Name). A path that is only
                      a folder on another volume is not the volume the plan names: it is reported with
                      the volume it would fall on, and that volume is never judged in its place.
  FreeSpace           free space at or above DeploymentVolumes.<key>MinimumFreeGB. Learn states no
                      absolute figure - it sizes the volumes from the calculated database size and the
                      log generation rate - so both values ship $null and the check is Unknown until the
                      operator supplies the figure their sizing gives.
  FileSystem          NTFS or ReFS: "Supported: NTFS and ReFS" (storage-configuration), and ReFS is
                      supported for mailbox databases and transaction logs (system-requirements).
  AllocationUnitSize  "Supported: All allocation unit sizes. Best practice: 64 KB for both .edb and log
                      file volumes." Another size is supported, so it is reported for the reader and
                      never failed; only the best practice is Compliant.

and once per target:

  DistinctVolumes     whether the database and log volumes are the same volume. The fact is always
                      reported. Learn states no requirement either way; its guidance depends on the
                      architecture - for a stand-alone server "move database (.edb) file and logs from
                      the same database to different volumes backed by different physical disks", for
                      high availability "Isolation of logs and databases isn't required", and with JBOD
                      one volume with separate directories. The deployment config does not say how many
                      database copies are planned, so a shared volume is reported for the reader to
                      judge (PartiallyCompliant) and never failed.

Not read: whether two distinct volumes sit on different physical disks, and ReFS integrity settings.

The target is read the DEP.TGT-01 way, over CIM only: Get-ExchTargetState -CimOnly with one
Win32_Volume query, and every check that needs the reading gated by Get-ExchTargetMechanismGate, so a
target that does not resolve or does not answer is Unknown on every check, naming the cause, and WinRM
is never contacted.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_DEP_VOL_01_VolumeReadiness {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'DEP.VOL-01'

    $targets = @(Get-ExchDeploymentTargetServer -Run $Run)
    $volumes = @(
        @{ Key = 'DatabaseVolume'; Path = [string](@(Get-ExchDeploymentValue -Run $Run -Key 'DatabaseVolume') | Select-Object -First 1) }
        @{ Key = 'LogVolume';      Path = [string](@(Get-ExchDeploymentValue -Run $Run -Key 'LogVolume') | Select-Object -First 1) }
    )
    $supplied = @($volumes | Where-Object { $_.Path })
    $notSupplied = @($volumes | Where-Object { -not $_.Path } | ForEach-Object { $_.Key })

    if ($targets.Count -eq 0 -or $supplied.Count -eq 0) {
        $missingKeys = @(@($(if ($targets.Count -eq 0) { 'TargetServers' })) + @($notSupplied) | Where-Object { $_ })
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Severity 'Info' -DataSource 'DeploymentConfig' `
                -Reason (Get-ExchNoVolumeReason -Keys $missingKeys) `
                -Remediation 'For a greenfield deployment, name the target servers and the database and log volumes in the Deployment section and pass the file with -ConfigPath. For an assessment of an existing organisation this finding is expected.'
        )
    }

    $requirements = Get-ExchVolumeRequirement -Run $Run
    $definitions = @(Get-ExchVolumeCheckDefinition)
    $dagName = [string](@(Get-ExchDeploymentValue -Run $Run -Key 'DagName') | Select-Object -First 1)
    $cimQuery = @(@{ Name = 'Volume'; ClassName = 'Win32_Volume'; Filter = 'DriveType = 3' })
    $gateDefinition = @{ Mechanisms = @('CIM'); CimClasses = @('Volume'); RemoteItems = @() }

    $serverRows = New-Object System.Collections.Generic.List[object]
    $checkRows  = New-Object System.Collections.Generic.List[object]

    foreach ($name in $targets) {
        $target = Get-ExchTargetState -Run $Run -ComputerName $name -ControlId $control.controlId -CimQuery $cimQuery -CimOnly
        $gate = Get-ExchTargetMechanismGate -Target $target -Definition $gateDefinition
        $read = @(Get-ExchTargetCimItem -Target $target -Name 'Volume')
        $serverRows.Add((New-ExchVolumeTargetRow -Target $target -VolumeCount $read.Count)) | Out-Null

        $matched = @{}
        foreach ($volume in $supplied) {
            $found = $null
            if (@($gate.Blocked).Count -eq 0) { $found = Find-ExchNamedVolume -Volumes $read -Path $volume.Path }
            $matched[$volume.Key] = $found
            foreach ($definition in @($definitions | Where-Object { $_.Scope -eq 'PerVolume' })) {
                $checkRows.Add((Invoke-ExchVolumeCheck -Definition $definition -Target $target -Gate $gate -Key $volume.Key `
                    -Path $volume.Path -Volume $found -Volumes $read -Requirements $requirements)) | Out-Null
            }
        }
        foreach ($definition in @($definitions | Where-Object { $_.Scope -eq 'PerTarget' })) {
            $checkRows.Add((Test-ExchVolumeSeparation -Definition $definition -Target $target -Gate $gate -Volumes $volumes `
                -Matched $matched -DagName $dagName)) | Out-Null
        }
    }

    $servers = @($serverRows.ToArray())
    $checks  = @($checkRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'deployment/volume-readiness.json' -ContentObject ([ordered]@{
        databaseVolume = $(if ($volumes[0].Path) { $volumes[0].Path } else { '' })
        logVolume      = $(if ($volumes[1].Path) { $volumes[1].Path } else { '' })
        notSupplied    = $notSupplied
        servers        = $servers
        checks         = $checks
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'deployment.volume-checks' -Title 'Deployment Database and Log Volume Checks' -Area 'Deployment' `
            -Columns @('Server', 'Role', 'Volume', 'Check', 'MechanismState', 'Outcome', 'Required', 'Measured', 'Cause', 'Source') `
            -Rows $checks
    )

    $unresolved  = @($servers | Where-Object { $_.Status -eq 'NameDoesNotResolve' })
    $unreachable = @($servers | Where-Object { $_.Status -eq 'Unreachable' })
    $readNames   = @($servers | Where-Object { $_.Status -eq 'Read' } | ForEach-Object { $_.Server })
    $failed      = @($checks | Where-Object { $_.Outcome -eq 'NonCompliant' })
    $partial     = @($checks | Where-Object { $_.Outcome -eq 'PartiallyCompliant' })
    # 'Not measured' and 'Not compared' rows follow from a volume that is absent or a key that was not
    # supplied, and the sentences for those already say so; every other Unknown names its own cause.
    $unjudged    = @($checks | Where-Object {
        $_.Outcome -eq 'Unknown' -and $readNames -contains $_.Server -and
            -not ([string]$_.Cause).StartsWith('Not measured:') -and -not ([string]$_.Cause).StartsWith('Not compared:')
    })
    $sameVolume  = @($checks | Where-Object { $_.Check -eq 'DistinctVolumes' -and ([string]$_.Measured).StartsWith('same volume') } | ForEach-Object { $_.Server })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($unresolved.Count -gt 0) {
        $problems.Add(("{0} supplied names do not resolve, so nothing was sent to them and none of their volumes was read - check Deployment.TargetServers for a typo, or whether the host has a DNS record yet: {1}" -f `
            $unresolved.Count, (($unresolved | ForEach-Object { "$($_.Server) ($(([string]$_.ResolveError).TrimEnd('.')))" }) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($unreachable.Count -gt 0) {
        $problems.Add(("{0} targets resolve but did not answer CIM, so none of their volumes was read: {1}" -f `
            $unreachable.Count, (($unreachable | ForEach-Object { "$($_.Server) ($(([string]$_.CimError).TrimEnd('.')))" }) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($notSupplied.Count -gt 0) {
        $problems.Add(("{0} was not supplied, so that volume was not checked and the two volumes were not compared. {1}" -f `
            (($notSupplied | ForEach-Object { "Deployment.$_" }) -join ', '), (Get-ExchDeploymentSupplyInstruction -Keys $notSupplied).TrimEnd('.'))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($failed.Count -gt 0) {
        $problems.Add(("{0} volume checks failed: {1}" -f $failed.Count, (Format-ExchVolumeRowList -Rows $failed))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($partial.Count -gt 0) {
        $problems.Add(("{0} volume checks are reported for the reader to judge - Learn states each as a best practice, not a requirement: {1}" -f $partial.Count, (Format-ExchVolumeRowList -Rows $partial))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($unjudged.Count -gt 0) {
        $problems.Add(("{0} volume checks on targets that answered could not be judged: {1}" -f $unjudged.Count, (Format-ExchVolumeRowList -Rows $unjudged))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    # Compliant is added only when nothing above fired. Get-ExchWorstOutcome would otherwise let a
    # Compliant check outvote an Unknown one, and an unread volume would pass.
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
                   elseif ($judged.Count -lt $checks.Count) { 'SoftFail' }
                   else { 'Pass' }

    $scope = ("{0} target servers named in Deployment.TargetServers were checked for the volumes the plan names - database volume {1}, log volume {2} - {3} checks, read over CIM from Win32_Volume (fixed disks)" -f `
        $servers.Count, $(if ($volumes[0].Path) { $volumes[0].Path } else { 'not supplied' }), $(if ($volumes[1].Path) { $volumes[1].Path } else { 'not supplied' }), $checks.Count)
    $limits = 'Not read: whether two distinct volumes sit on different physical disks, and ReFS integrity settings'
    $body = if ($problems.Count -gt 0) { @($scope) + @($problems.ToArray()) } else { @(('{0}, and every check on every server was read and met' -f $scope)) }
    $rationale = ((@($body) + @($limits)) -join '. ') + '.'

    $cimState = if (@($servers | Where-Object { $_.CimState -ne 'Succeeded' }).Count -eq 0) { 'Success' } else { 'Partial' }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome -Sufficiency $sufficiency `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Create the database and log volumes the plan names on every target server, formatted NTFS or ReFS, with the free space your sizing requires - supply that figure in DeploymentVolumes with -ConfigPath - and a 64 KB allocation unit, Learn''s best practice. Decide whether the database and log share a volume from Learn''s guidance for your architecture. https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/storage-configuration' `
        -Metrics @{
            targetCount              = $servers.Count
            databaseVolume           = $(if ($volumes[0].Path) { $volumes[0].Path } else { '' })
            logVolume                = $(if ($volumes[1].Path) { $volumes[1].Path } else { '' })
            notSupplied              = @($notSupplied)
            unresolvedNames          = @($unresolved | ForEach-Object { $_.Server })
            unreachableNames         = @($unreachable | ForEach-Object { $_.Server })
            sameVolumeServers        = @($sameVolume)
            checkCount               = $checks.Count
            compliantChecks          = @($checks | Where-Object { $_.Outcome -eq 'Compliant' }).Count
            nonCompliantChecks       = $failed.Count
            partiallyCompliantChecks = $partial.Count
            unknownChecks            = @($checks | Where-Object { $_.Outcome -eq 'Unknown' }).Count
            servers                  = $servers
            checks                   = $checks
        } `
        -Meta @{ dataSources = @{
            DeploymentConfig = @{ state = $(if ($notSupplied.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($notSupplied -join ', ') }
            CIM              = @{ state = $cimState; reason = (@($servers | Where-Object { $_.CimState -ne 'Succeeded' } | ForEach-Object { "$($_.Server): $($_.CimState)" }) -join ', ') }
        }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchNoVolumeReason {
    <#
    The rationale when there is nothing to check: no target server, or neither volume. The template
    path and both commands come from the P13 helper the preflight warning uses.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Keys)

    $named = ($Keys | ForEach-Object { "Deployment.$_" }) -join ', '
    return (("Not supplied: {0} {1} empty or absent, so no database or log volume was checked on any target server. " -f $named, $(if (@($Keys).Count -eq 1) { 'is' } else { 'are' })) +
        "This does not mean the volumes are ready - it means the plan does not name them yet, and the directory cannot name them because the databases do not exist yet. " +
        (Get-ExchDeploymentSupplyInstruction -Keys $Keys))
}

function Get-ExchVolumeRequirement {
    <#
    The DeploymentVolumes entries from the run's configuration, by key. A key the configuration does
    not carry is $null, and the check that reads it reports that rather than guessing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $table = Get-ExchThreshold -Run $Run -Name 'DeploymentVolumes' -Default @{}
    $result = @{}
    foreach ($key in @('FileSystems', 'AllocationUnitBytes', 'DatabaseVolumeMinimumFreeGB', 'LogVolumeMinimumFreeGB')) {
        $result[$key] = $null
        if ($table -is [System.Collections.IDictionary] -and $table.Contains($key)) { $result[$key] = $table[$key] }
    }
    return $result
}

function Get-ExchVolumeCheckDefinition {
    <#
    One definition per volume check: whether it runs on each supplied volume or once per target, and
    the Learn page behind it. A test counts these from this file's text.
    #>
    [CmdletBinding()]
    param()

    $storage      = 'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/storage-configuration#best-practices-for-supported-storage-configurations'
    $requirements = 'https://learn.microsoft.com/exchange/plan-and-deploy/system-requirements#hardware-requirements-for-exchange-server'

    return @(
        @{ Check = 'VolumeExists';       Scope = 'PerVolume'; Source = @($storage) }
        @{ Check = 'FreeSpace';          Scope = 'PerVolume'; Source = @($storage) }
        @{ Check = 'FileSystem';         Scope = 'PerVolume'; Source = @($storage, $requirements) }
        @{ Check = 'AllocationUnitSize'; Scope = 'PerVolume'; Source = @($storage) }
        @{ Check = 'DistinctVolumes';    Scope = 'PerTarget'; Source = @($storage) }
    )
}

function ConvertTo-ExchVolumeName {
    <#
    A supplied volume, or a Win32_Volume.Name, in one comparable form: trimmed, backslashes, and a
    trailing backslash - so 'D:', 'D:\' and 'd:/' all read 'D:\' (compared without regard to case).
    #>
    [CmdletBinding()]
    param([Parameter()][string]$Path = '')

    $text = $Path.Trim().Replace('/', '\')
    if (-not $text) { return '' }
    if (-not $text.EndsWith('\')) { $text = $text + '\' }
    return $text
}

function Find-ExchNamedVolume {
    <#
    The Win32_Volume mounted at exactly the supplied path, or $null. Unlike Find-ExchVolumeForPath it
    never falls back to the volume that holds the path: a folder is not the volume the plan names.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object[]]$Volumes = @(),
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path
    )

    $wanted = ConvertTo-ExchVolumeName -Path $Path
    foreach ($volume in @($Volumes)) {
        $name = ConvertTo-ExchVolumeName -Path ([string](Get-ExchObjectValue -InputObject $volume -Name 'Name' -Default ''))
        if ($name -and [string]::Equals($name, $wanted, [System.StringComparison]::OrdinalIgnoreCase)) { return $volume }
    }
    return $null
}

function New-ExchVolumeTargetRow {
    <#
    How far one target was reached. With one CIM query CimState is Succeeded or Failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Target,
        [Parameter()][int]$VolumeCount = 0
    )

    $status = if (-not $Target.Resolved) { 'NameDoesNotResolve' }
              elseif ($Target.CimState -ne 'Succeeded') { 'Unreachable' }
              else { 'Read' }
    return [pscustomobject]@{
        Server       = $Target.Name
        Status       = $status
        Resolves     = [string][bool]$Target.Resolved
        Addresses    = $Target.Addresses
        ResolveError = $Target.ResolveError
        CimState     = $Target.CimState
        CimError     = $Target.CimError
        VolumesRead  = $VolumeCount
    }
}

function New-ExchVolumeNoValue {
    <#
    The result for a DeploymentVolumes key that holds no Value. Nothing is judged against a value
    that is not there, and the measurement is still reported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key,
        [Parameter()]$Entry,
        [Parameter()][string]$Measured = ''
    )

    $note = [string](Get-ExchPrereqField -Entry $Entry -Name 'Note')
    $cause = ('No value: DeploymentVolumes.{0} holds no Value in the run''s configuration, so this check was not judged.' -f $Key)
    if ($note) { $cause = ('{0} {1}' -f $cause, $note) }
    return New-ExchPrereqResult -Outcome 'Unknown' -Measured $Measured -Cause $cause
}

function Invoke-ExchVolumeCheck {
    <#
    Runs one per-volume check on one target. A target whose Win32_Volume reading is missing is
    Unknown, naming the mechanism and the error, and is never passed to the evaluator.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Definition,
        [Parameter(Mandatory)][ValidateNotNull()]$Target,
        [Parameter(Mandatory)][ValidateNotNull()]$Gate,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter()]$Volume,
        [Parameter()][object[]]$Volumes = @(),
        [Parameter(Mandatory)][ValidateNotNull()][hashtable]$Requirements
    )

    $row = [ordered]@{
        Server         = $Target.Name
        Role           = $Key
        Volume         = $Path
        Check          = [string]$Definition.Check
        MechanismState = $Gate.MechanismState
        Outcome        = 'Unknown'
        Required       = ''
        Measured       = ''
        Cause          = ''
        Source         = (@($Definition.Source) -join ' ')
    }

    if (@($Gate.Blocked).Count -gt 0) {
        $row.Cause = ('Not read: {0}.' -f ((@($Gate.Blocked) | ForEach-Object { ([string]$_).TrimEnd('.') }) -join '; '))
        return [pscustomobject]$row
    }

    $result = Test-ExchVolumeCheck -Check ([string]$Definition.Check) -Server $Target.Name -Key $Key -Path $Path -Volume $Volume -Volumes $Volumes -Requirements $Requirements
    $row.Outcome  = [string]$result['Outcome']
    $row.Required = [string]$result['Required']
    $row.Measured = [string]$result['Measured']
    $row.Cause    = [string]$result['Cause']
    if ($row.Outcome -eq 'Unknown' -and -not $row.Cause) { $row.Cause = 'The check returned no verdict and no reason.' }
    return [pscustomobject]$row
}

function Test-ExchVolumeCheck {
    <#
    The per-volume evaluators. Each is reached only when the volumes were read, and each returns
    Unknown with a cause when the data cannot support a verdict. Every Compliant comes from
    New-ExchPrereqVerdict, so a pass is always the result of a comparison.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Check,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Server,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter()]$Volume,
        [Parameter()][object[]]$Volumes = @(),
        [Parameter(Mandatory)][ValidateNotNull()][hashtable]$Requirements
    )

    $wanted = ConvertTo-ExchVolumeName -Path $Path

    if ($Check -eq 'VolumeExists') {
        $required = ('a volume mounted at {0} (Win32_Volume.Name), as Deployment.{1} names it' -f $wanted, $Key)
        if ($null -ne $Volume) {
            return (New-ExchPrereqVerdict -Met $true -Required $required -Measured ('{0} present ({1})' -f `
                [string](Get-ExchObjectValue -InputObject $Volume -Name 'Name' -Default ''), [string](Get-ExchObjectValue -InputObject $Volume -Name 'DeviceID' -Default '')))
        }
        if ($wanted -notmatch '^[A-Za-z]:\\') {
            return (New-ExchPrereqVerdict -Met $false -Required $required -Measured ('no volume at {0}' -f $wanted) `
                -FailCause ('Deployment.{0} ''{1}'' is not a drive letter or a local mount point path, so it names no volume on {2}.' -f $Key, $Path, $Server))
        }
        $holder = Find-ExchVolumeForPath -Volumes $Volumes -Path $wanted
        if ($null -ne $holder) {
            $holderName = [string](Get-ExchObjectValue -InputObject $holder -Name 'Name' -Default '')
            return (New-ExchPrereqVerdict -Met $false -Required $required -Measured ('no volume at {0}; the path falls on {1}' -f $wanted, $holderName) `
                -FailCause ('No volume is mounted at {0} on {1}. The path would be a folder on {2}, which is not the volume Deployment.{3} names, so {2} was not judged in its place.' -f $wanted, $Server, $holderName, $Key))
        }
        return (New-ExchPrereqVerdict -Met $false -Required $required -Measured ('no volume at {0} among the {1} fixed volumes read' -f $wanted, @($Volumes).Count) `
            -FailCause ('No volume is mounted at {0} on {1}.' -f $wanted, $Server))
    }

    if ($null -eq $Volume) {
        return (New-ExchPrereqResult -Outcome 'Unknown' -Cause ('Not measured: no volume is mounted at {0} on {1}, so there is nothing to measure - see VolumeExists.' -f $wanted, $Server))
    }

    switch ($Check) {

        'FreeSpace' {
            $thresholdKey = '{0}MinimumFreeGB' -f $Key
            $entry = $Requirements[$thresholdKey]
            $minimum = Get-ExchPrereqValue -Entry $entry
            $free = Get-ExchObjectValue -InputObject $Volume -Name 'FreeSpace'
            $measured = if ($null -ne $free) { ('{0} GB free' -f [math]::Round([double]$free / 1GB, 1)) } else { '' }
            if ($null -eq $minimum) { return (New-ExchVolumeNoValue -Key $thresholdKey -Entry $entry -Measured $measured) }
            $floor = $null
            try { $floor = [double]$minimum } catch { return (New-ExchPrereqResult -Outcome 'Unknown' -Measured $measured -Cause ('DeploymentVolumes.{0} is not a number.' -f $thresholdKey)) }
            $required = ('>= {0} GB free (DeploymentVolumes.{1})' -f $minimum, $thresholdKey)
            if ($null -eq $free) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause 'Win32_Volume returned no FreeSpace for that volume.') }
            return (New-ExchPrereqVerdict -Met ([double]$free -ge ($floor * 1GB)) -Required $required -Measured $measured `
                -FailCause ('Less free space than the {0} GB set in DeploymentVolumes.{1}.' -f $minimum, $thresholdKey))
        }

        'FileSystem' {
            $entry = $Requirements['FileSystems']
            $allowed = Get-ExchPrereqValue -Entry $entry
            $fileSystem = [string](Get-ExchObjectValue -InputObject $Volume -Name 'FileSystem' -Default '')
            if ($null -eq $allowed) { return (New-ExchVolumeNoValue -Key 'FileSystems' -Entry $entry -Measured $fileSystem) }
            $required = ('one of {0}' -f (@($allowed) -join ', '))
            if (-not $fileSystem) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause 'Win32_Volume returned no FileSystem for that volume.') }
            return (New-ExchPrereqVerdict -Met (@($allowed) -contains $fileSystem) -Required $required -Measured $fileSystem `
                -FailCause ('{0} is not a file system Learn supports for Exchange database and log volumes: "Supported: NTFS and ReFS."' -f $fileSystem))
        }

        'AllocationUnitSize' {
            $entry = $Requirements['AllocationUnitBytes']
            $best = Get-ExchPrereqValue -Entry $entry
            $size = Get-ExchObjectValue -InputObject $Volume -Name 'BlockSize'
            $measured = if ($null -ne $size) { ('{0} bytes' -f [string]$size) } else { '' }
            if ($null -eq $best) { return (New-ExchVolumeNoValue -Key 'AllocationUnitBytes' -Entry $entry -Measured $measured) }
            $required = ('{0} bytes, Learn''s best practice; every allocation unit size is supported' -f [string]$best)
            if ($null -eq $size) { return (New-ExchPrereqResult -Outcome 'Unknown' -Required $required -Cause 'Win32_Volume returned no BlockSize for that volume.') }
            if ([int64]$size -eq [int64]$best) { return (New-ExchPrereqVerdict -Met $true -Required $required -Measured $measured) }
            return (New-ExchPrereqResult -Outcome 'PartiallyCompliant' -Required $required -Measured $measured `
                -Cause ('Learn: "Supported: All allocation unit sizes. Best practice: 64 KB for both .edb and log file volumes." {0} bytes is supported and is not the best practice, so it is reported for the reader, not failed.' -f [string]$size))
        }

        default {
            return (New-ExchPrereqResult -Outcome 'Unknown' -Cause ("No check is defined for the volume check '{0}', so it was not evaluated." -f $Check))
        }
    }
}

function Test-ExchVolumeSeparation {
    <#
    Whether the database and log volumes are the same volume on one target. The same path in both keys
    is the same volume on every target, which the config alone shows; otherwise both volumes must
    have been read and found. A shared volume is reported for the reader to judge, because Learn
    states a best practice that depends on the architecture and no requirement.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Definition,
        [Parameter(Mandatory)][ValidateNotNull()]$Target,
        [Parameter(Mandatory)][ValidateNotNull()]$Gate,
        [Parameter(Mandatory)][object[]]$Volumes,
        [Parameter(Mandatory)][ValidateNotNull()][hashtable]$Matched,
        [Parameter()][string]$DagName = ''
    )

    $database = [string](@($Volumes | Where-Object { $_.Key -eq 'DatabaseVolume' } | ForEach-Object { $_.Path }) | Select-Object -First 1)
    $log = [string](@($Volumes | Where-Object { $_.Key -eq 'LogVolume' } | ForEach-Object { $_.Path }) | Select-Object -First 1)

    $row = [ordered]@{
        Server         = $Target.Name
        Role           = 'DatabaseVolume+LogVolume'
        Volume         = ('{0} / {1}' -f $(if ($database) { $database } else { '(not supplied)' }), $(if ($log) { $log } else { '(not supplied)' }))
        Check          = [string]$Definition.Check
        MechanismState = $Gate.MechanismState
        Outcome        = 'Unknown'
        Required       = 'reported: whether the database and log volumes are the same volume (the physical disks behind two distinct volumes are not read)'
        Measured       = ''
        Cause          = ''
        Source         = (@($Definition.Source) -join ' ')
    }

    $missing = @(@(if (-not $database) { 'Deployment.DatabaseVolume' }) + @(if (-not $log) { 'Deployment.LogVolume' }) | Where-Object { $_ })
    if ($missing.Count -gt 0) {
        $row.Cause = ('Not compared: {0} was not supplied, so there is no second volume to compare with.' -f ($missing -join ', '))
        return [pscustomobject]$row
    }

    $databaseName = ConvertTo-ExchVolumeName -Path $database
    $logName = ConvertTo-ExchVolumeName -Path $log
    $same = $false
    $measured = ''

    if ([string]::Equals($databaseName, $logName, [System.StringComparison]::OrdinalIgnoreCase)) {
        $same = $true
        $row.MechanismState = 'Config'
        $measured = ('same volume: Deployment.DatabaseVolume and Deployment.LogVolume both name {0}' -f $databaseName)
    }
    else {
        if (@($Gate.Blocked).Count -gt 0) {
            $row.Cause = ('Not read: {0}.' -f ((@($Gate.Blocked) | ForEach-Object { ([string]$_).TrimEnd('.') }) -join '; '))
            return [pscustomobject]$row
        }
        $databaseVolume = $Matched['DatabaseVolume']
        $logVolume = $Matched['LogVolume']
        $absent = @(@(if ($null -eq $databaseVolume) { $databaseName }) + @(if ($null -eq $logVolume) { $logName }) | Where-Object { $_ })
        if ($absent.Count -gt 0) {
            $row.Cause = ('Not compared: no volume is mounted at {0} on {1} - see VolumeExists.' -f ($absent -join ' or '), $Target.Name)
            return [pscustomobject]$row
        }
        $databaseId = [string](Get-ExchObjectValue -InputObject $databaseVolume -Name 'DeviceID' -Default '')
        $logId = [string](Get-ExchObjectValue -InputObject $logVolume -Name 'DeviceID' -Default '')
        if ($databaseId -and [string]::Equals($databaseId, $logId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $same = $true
            $measured = ('same volume: {0} and {1} are both {2}' -f $databaseName, $logName, $databaseId)
        }
        else {
            $measured = ('distinct: databases on {0} ({1}), logs on {2} ({3})' -f $databaseName, $databaseId, $logName, $logId)
        }
    }

    if (-not $same) {
        $result = New-ExchPrereqVerdict -Met $true -Required $row.Required -Measured $measured
    }
    else {
        $plan = if ($DagName) { ('Deployment.DagName is supplied (''{0}''), so a DAG is planned' -f $DagName) } else { 'Deployment.DagName is not supplied' }
        $result = New-ExchPrereqResult -Outcome 'PartiallyCompliant' -Required $row.Required -Measured $measured `
            -Cause ('The database and log volumes are the same volume. Learn states no requirement either way; its guidance depends on the architecture. For a stand-alone server: "For recoverability, move database (.edb) file and logs from the same database to different volumes backed by different physical disks", and co-location is "not recommended in standalone architectures". For high availability: "Isolation of logs and databases isn''t required", and with JBOD "create a single volume with separate directories for database(s) and for log files". {0}; the number of database copies is not in the deployment config, so which applies is not decided here. Reported for the reader to judge, not failed.' -f $plan)
    }

    $row.Outcome  = [string]$result['Outcome']
    $row.Measured = [string]$result['Measured']
    $row.Cause    = [string]$result['Cause']
    return [pscustomobject]$row
}

function Format-ExchVolumeRowList {
    [CmdletBinding()]
    param([Parameter()][object[]]$Rows = @())

    return ((@($Rows) | ForEach-Object {
        $text = ('{0} {1} {2}' -f $_.Server, $_.Role, $_.Check)
        if ($_.Measured) { $text = ('{0} (found {1}{2})' -f $text, $_.Measured, $(if ($_.Required) { "; required $($_.Required)" } else { '' })) }
        if ($_.Cause) { $text = ('{0} - {1}' -f $text, ([string]$_.Cause).TrimEnd('.')) }
        $text
    }) -join '; ')
}

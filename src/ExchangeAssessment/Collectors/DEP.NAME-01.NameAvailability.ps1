<#
DEP.NAME-01 - Whether the names a greenfield deployment plans to use are free.

The planned names come from the P13 Deployment section and from nowhere else: TargetServers,
WitnessServer, DagName and InternalNames. Every check asks whether a name is FREE - held by nothing
that would collide with it - and a name that is already held is a finding naming what holds it,
never an error.

  DagName        NameLength             no longer than 15 characters (manage-dags)
                 NameCharacters         a valid computer name: A-Z, 0-9 and the minus sign, not only
                                        numerals, not starting or ending with a minus sign
                 ComputerObject         no computer object in the forest holds the name, and no
                                        planned server has it - "unique within the Active Directory forest"
                 ExistingExchangeObject no object under CN=Microsoft Exchange in the configuration
                                        partition holds the name, which is where an existing DAG lives
  TargetServers  ComputerObject         a target that is already a domain member holds its own computer
  WitnessServer                         account, and that is expected: the name is judged free when no
                                        object holds it or exactly one does whose dNSHostName is the
                                        supplied name. Another holder, or more than one, is a finding.
  InternalNames  DnsRecord              the name does not exist in DNS

What the instruments cannot see is stated in every rationale, so an absence is never read as proof:
the directory is searched in one global catalog of the assessment host's forest, and DNS is asked of
the resolvers configured on the assessment host, for A, AAAA and CNAME answers only.

The directory is read only through Find-ExchDirectoryComputer and Find-ExchDirectoryExchangeObject,
and DNS only through Resolve-ExchPlannedDnsName, so the tests can replace them.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_DEP_NAME_01_NameAvailability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'DEP.NAME-01'

    $targets  = @(Get-ExchDeploymentTargetServer -Run $Run)
    $witness  = Get-ExchDeploymentWitnessServer -Run $Run
    $dagName  = [string](@(Get-ExchDeploymentValue -Run $Run -Key 'DagName') | Select-Object -First 1)
    $internal = @(Get-ExchDeploymentValue -Run $Run -Key 'InternalNames')

    $missing = @(@(
        @{ Key = 'TargetServers'; Empty = ($targets.Count -eq 0) }
        @{ Key = 'WitnessServer'; Empty = (-not $witness) }
        @{ Key = 'DagName';       Empty = (-not $dagName) }
        @{ Key = 'InternalNames'; Empty = ($internal.Count -eq 0) }
    ) | Where-Object { $_.Empty } | ForEach-Object { $_.Key })

    if ($missing.Count -eq 4) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Severity 'Info' -DataSource 'DeploymentConfig' `
                -Reason (Get-ExchNoPlannedNameReason) `
                -Remediation 'For a greenfield deployment, fill in the planned names in the Deployment section and pass the file with -ConfigPath. For an assessment of an existing organisation this finding is expected.'
        )
    }

    $rules = Get-ExchThreshold -Run $Run -Name 'PlannedNames' -Default @{}
    $plannedServers = @(@($targets) + @($witness) | Where-Object { $_ })

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($name in $targets) { $rows.Add((Test-ExchServerNameHolder -Run $Run -Name $name -Role 'TargetServer' -ControlId $control.controlId)) | Out-Null }
    if ($witness) { $rows.Add((Test-ExchServerNameHolder -Run $Run -Name $witness -Role 'WitnessServer' -ControlId $control.controlId)) | Out-Null }
    if ($dagName) {
        foreach ($row in @(Test-ExchDagName -Run $Run -Name $dagName -Rules $rules -PlannedServers $plannedServers -ControlId $control.controlId)) { $rows.Add($row) | Out-Null }
    }
    foreach ($name in $internal) { $rows.Add((Test-ExchPlannedDnsName -Run $Run -Name $name -ControlId $control.controlId)) | Out-Null }
    foreach ($key in $missing) {
        $rows.Add((New-ExchNameRow -Role $key -Name '' -Check 'Supplied' -Instrument 'Config' -Outcome 'Unknown' -Status 'NotSupplied' `
            -Required ('Deployment.{0} is supplied' -f $key) -Cause ('Deployment.{0} is empty or absent, so it was not checked.' -f $key))) | Out-Null
    }

    $checks = @($rows.ToArray())
    $directoryScope = [string](@($checks | Where-Object { $_.Instrument -eq 'Directory' -and $_.Scope } | ForEach-Object { $_.Scope }) | Select-Object -First 1)
    if (-not $directoryScope) { $directoryScope = 'a global catalog of the assessment host''s forest' }
    $dnsScope = Get-ExchPlannedDnsScope

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'deployment/name-availability.json' -ContentObject ([ordered]@{
        targetServers  = $targets
        witnessServer  = $witness
        dagName        = $dagName
        internalNames  = $internal
        notSupplied    = $missing
        directoryScope = $directoryScope
        dnsScope       = $dnsScope
        checks         = $checks
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'deployment.planned-names' -Title 'Deployment Planned Name Availability' -Area 'Deployment' `
            -Columns @('Role', 'Name', 'Check', 'Instrument', 'Outcome', 'Status', 'Required', 'Measured', 'HeldBy', 'Cause', 'Scope', 'Source') `
            -Rows $checks
    )

    $failed   = @($checks | Where-Object { $_.Outcome -eq 'NonCompliant' })
    $partial  = @($checks | Where-Object { $_.Outcome -eq 'PartiallyCompliant' })
    $unjudged = @($checks | Where-Object { $_.Outcome -eq 'Unknown' -and $_.Status -ne 'NotSupplied' })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($failed.Count -gt 0) {
        $problems.Add(("{0} planned names are already in use: {1}" -f $failed.Count, (Format-ExchNameRowList -Rows $failed))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($partial.Count -gt 0) {
        $problems.Add(("{0} planned internal names already exist in DNS, and what holds them is listed; whether one is being reused on purpose is for the reader to decide: {1}" -f $partial.Count, (Format-ExchNameRowList -Rows $partial))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($unjudged.Count -gt 0) {
        $problems.Add(("{0} planned name checks could not be judged: {1}" -f $unjudged.Count, (Format-ExchNameRowList -Rows $unjudged))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($missing.Count -gt 0) {
        $problems.Add(("{0} were not supplied, so those names were not checked. {1}" -f (($missing | ForEach-Object { "Deployment.$_" }) -join ', '), (Get-ExchDeploymentSupplyInstruction -Keys $missing).TrimEnd('.'))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    # Compliant is added only when nothing above fired, so an unchecked name cannot pass.
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

    $scope = ("The planned names in the Deployment section were checked for availability - {0} target servers, {1} witness, {2} DAG name and {3} internal names, {4} checks" -f `
        $targets.Count, $(if ($witness) { 1 } else { 0 }), $(if ($dagName) { 1 } else { 0 }), $internal.Count, $checks.Count)
    $limits = ("What the instruments cannot see: computer objects and Exchange configuration objects were searched in {0} - an object in another forest, one created after this read, or one not yet replicated to that global catalog is not seen; DNS names were asked of {1} - a record held only in another DNS view, such as a split-brain or external zone, or on a resolver that was not queried is not seen. An absence here is an absence in those scopes, not proof that a name is free everywhere" -f `
        $directoryScope, $dnsScope)
    $body = if ($problems.Count -gt 0) { @($scope) + @($problems.ToArray()) } else { @(('{0}, and every name checked is free in the scopes searched' -f $scope)) }
    $rationale = ((@($body) + @($limits)) -join '. ') + '.'

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome -Sufficiency $sufficiency `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Choose another DAG name where one is taken or invalid - at most 15 characters, unique within the forest - resolve any server name held by a computer other than that server, and review every internal name that already exists in DNS before publishing the namespace. Where DNS or the directory could not be read, re-run from a host that can read them. https://learn.microsoft.com/exchange/high-availability/manage-ha/manage-dags#creating-dags' `
        -Metrics @{
            targetCount       = $targets.Count
            witnessServer     = $witness
            dagName           = $dagName
            internalNameCount = $internal.Count
            notSupplied       = $missing
            checkCount        = $checks.Count
            freeCount         = @($checks | Where-Object { $_.Outcome -eq 'Compliant' }).Count
            inUseCount        = ($failed.Count + $partial.Count)
            unknownCount      = @($checks | Where-Object { $_.Outcome -eq 'Unknown' }).Count
            directoryScope    = $directoryScope
            dnsScope          = $dnsScope
            checks            = $checks
        } `
        -Meta @{ dataSources = @{
            DeploymentConfig = @{ state = $(if ($missing.Count -eq 0) { 'Success' } else { 'Partial' }); reason = ($missing -join ', ') }
            Directory        = @{ state = $(if (@($checks | Where-Object { $_.Instrument -eq 'Directory' -and $_.Status -eq 'Error' }).Count -gt 0) { 'Partial' } else { 'Success' }); reason = $directoryScope }
            DNS              = @{ state = $(if (@($checks | Where-Object { $_.Instrument -eq 'DNS' -and $_.Status -eq 'Error' }).Count -gt 0) { 'Partial' } else { 'Success' }); reason = $dnsScope }
        }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchNoPlannedNameReason {
    <#
    The rationale when none of the planned names was supplied. The template path and both commands
    come from the P13 helper the preflight warning uses.
    #>
    [CmdletBinding()]
    param()

    return ("No planned names were supplied: Deployment.TargetServers, WitnessServer, DagName and InternalNames are all empty or absent, so no name was checked for availability. " +
        "This does not mean the names are free - it means none was named. " +
        (Get-ExchDeploymentSupplyInstruction -Keys @('TargetServers', 'WitnessServer', 'DagName', 'InternalNames')))
}

function Get-ExchNameCheckDefinition {
    <#
    The checks run per planned name, by role. A test holds this list to the checks the collector
    actually produces, so a check cannot be dropped from one without the other.
    #>
    [CmdletBinding()]
    param()

    return @(
        @{ Role = 'TargetServer';  Check = 'ComputerObject';         Instrument = 'Directory' }
        @{ Role = 'WitnessServer'; Check = 'ComputerObject';         Instrument = 'Directory' }
        @{ Role = 'DagName';       Check = 'NameLength';             Instrument = 'Config' }
        @{ Role = 'DagName';       Check = 'NameCharacters';         Instrument = 'Config' }
        @{ Role = 'DagName';       Check = 'ComputerObject';         Instrument = 'Directory' }
        @{ Role = 'DagName';       Check = 'ExistingExchangeObject'; Instrument = 'Directory' }
        @{ Role = 'InternalName';  Check = 'DnsRecord';              Instrument = 'DNS' }
    )
}

function New-ExchNameRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Role,
        [Parameter()][string]$Name = '',
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Check,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Instrument,
        [Parameter(Mandatory)][ValidateSet('Compliant', 'PartiallyCompliant', 'NonCompliant', 'Unknown')][string]$Outcome,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Status,
        [Parameter()][string]$Required = '',
        [Parameter()][string]$Measured = '',
        [Parameter()][string[]]$HeldBy = @(),
        [Parameter()][string]$Cause = '',
        [Parameter()][string]$Scope = '',
        [Parameter()][string[]]$Source = @()
    )

    return [pscustomobject]@{
        Role       = $Role
        Name       = $Name
        Check      = $Check
        Instrument = $Instrument
        Outcome    = $Outcome
        Status     = $Status
        Required   = $Required
        Measured   = $Measured
        HeldBy     = (@($HeldBy) -join '; ')
        Cause      = $Cause
        Scope      = $Scope
        Source     = (@($Source) -join ' ')
    }
}

function New-ExchNameVerdict {
    <#
    A row whose outcome comes from a comparison: Compliant when the name was found free, the given
    outcome with its cause when it was not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Row,
        [Parameter(Mandatory)][bool]$Free,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FreeStatus,
        [Parameter()][ValidateSet('PartiallyCompliant', 'NonCompliant')][string]$HeldOutcome = 'NonCompliant',
        [Parameter()][string]$HeldStatus = 'InUse',
        [Parameter()][string]$Cause = ''
    )

    $verdict = New-ExchPrereqVerdict -Met $Free -Required ([string]$Row['Required']) -Measured ([string]$Row['Measured']) -FailCause $Cause
    $Row['Outcome'] = if ($Free) { [string]$verdict['Outcome'] } else { $HeldOutcome }
    $Row['Status']  = if ($Free) { $FreeStatus } else { $HeldStatus }
    $Row['Cause']   = [string]$verdict['Cause']
    return New-ExchNameRow @Row
}

function Format-ExchComputerHolder {
    [CmdletBinding()]
    param([Parameter()]$Computer)

    return ("{0} (dNSHostName '{1}')" -f [string](Get-ExchPortItem -InputObject $Computer -Name 'DistinguishedName'), [string](Get-ExchPortItem -InputObject $Computer -Name 'DNSHostName'))
}

function Test-ExchServerNameHolder {
    <#
    A target or witness name. The server is supplied as a member server, so its own computer account
    is expected to hold its name: the name is free when no computer object holds it, or exactly one
    does whose dNSHostName is the supplied name. A different holder, or more than one, is a finding.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory)][ValidateSet('TargetServer', 'WitnessServer')][string]$Role,
        [Parameter()][string]$ControlId = ''
    )

    $fullName = $Name.TrimEnd('.')
    $short = $fullName.Split('.')[0]
    $fqdn = if ($fullName.Contains('.')) { $fullName } else { '' }
    $row = @{
        Role = $Role; Name = $Name; Check = 'ComputerObject'; Instrument = 'Directory'
        Required = 'no computer object holds the name, or exactly one does and it is this server''s own account (its dNSHostName is the supplied name)'
    }

    try { $lookup = Find-ExchDirectoryComputer -Run $Run -Name $short -Fqdn $fqdn }
    catch {
        $null = Write-ExchError -Run $Run -Context ('Directory search for the computer name {0}' -f $Name) -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning'
        return New-ExchNameRow @row -Outcome 'Unknown' -Status 'Error' -Cause ('The directory could not be searched for {0}: {1}.' -f $Name, ([string]$_.Exception.Message).TrimEnd('.'))
    }

    $row['Scope'] = [string](Get-ExchPortItem -InputObject $lookup -Name 'Scope')
    $computers = @(Get-ExchPortItem -InputObject $lookup -Name 'Computers' | Where-Object { $null -ne $_ })
    $row['HeldBy'] = @($computers | ForEach-Object { Format-ExchComputerHolder -Computer $_ })

    if ($computers.Count -eq 0) {
        $row['Measured'] = ('no computer object named {0}{1} in {2}' -f $short, $(if ($fqdn) { " or with DNS host name $fqdn" } else { '' }), $row['Scope'])
        return New-ExchNameVerdict -Row $row -Free $true -FreeStatus 'NoObjectFound'
    }
    if ($computers.Count -gt 1) {
        $row['Measured'] = ('{0} computer objects hold the name' -f $computers.Count)
        return New-ExchNameVerdict -Row $row -Free $false -FreeStatus 'OwnAccount' -HeldStatus 'Duplicate' -Cause ('More than one computer object holds the name {0}, so it does not identify one server: {1}.' -f $Name, (@($row['HeldBy']) -join '; '))
    }

    $dnsHostName = ([string](Get-ExchPortItem -InputObject $computers[0] -Name 'DNSHostName')).TrimEnd('.')
    if (-not $fqdn) {
        $row['Measured'] = ('one computer object holds the name: {0}' -f @($row['HeldBy'])[0])
        return New-ExchNameRow @row -Outcome 'Unknown' -Status 'NotComparable' -Cause ('{0} was supplied without a domain, so whether the object is this server''s own account cannot be told.' -f $Name)
    }
    $own = $dnsHostName -and $dnsHostName.Equals($fqdn, [System.StringComparison]::OrdinalIgnoreCase)
    $row['Measured'] = if ($own) { ('held by its own computer account: {0}' -f @($row['HeldBy'])[0]) } else { ('held by {0}' -f @($row['HeldBy'])[0]) }
    return New-ExchNameVerdict -Row $row -Free $own -FreeStatus 'OwnAccount' -HeldStatus 'HeldByAnother' -Cause ('The name is held by a computer object whose DNS host name is ''{0}'', not {1} - another computer holds it.' -f $dnsHostName, $fqdn)
}

function Test-ExchDagName {
    <#
    The four DAG name checks: length, characters, no computer object or planned server holding the
    name, and no object under CN=Microsoft Exchange holding it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter()]$Rules = @{},
        [Parameter()][string[]]$PlannedServers = @(),
        [Parameter()][string]$ControlId = ''
    )

    $lengthEntry  = if ($Rules -is [System.Collections.IDictionary] -and $Rules.Contains('DagNameMaxLength')) { $Rules['DagNameMaxLength'] } else { $null }
    $patternEntry = if ($Rules -is [System.Collections.IDictionary] -and $Rules.Contains('ComputerNamePattern')) { $Rules['ComputerNamePattern'] } else { $null }
    $maximum = Get-ExchPrereqValue -Entry $lengthEntry
    $pattern = Get-ExchPrereqValue -Entry $patternEntry
    $lengthSource = @(Get-ExchPrereqField -Entry $lengthEntry -Name 'Source')
    $patternSource = @(Get-ExchPrereqField -Entry $patternEntry -Name 'Source')

    # NameLength
    $row = @{ Role = 'DagName'; Name = $Name; Check = 'NameLength'; Instrument = 'Config'; Source = $lengthSource; Measured = ('{0} characters' -f $Name.Length) }
    if ($null -eq $maximum) { New-ExchNameRow @row -Outcome 'Unknown' -Status 'NoValue' -Cause 'No value: PlannedNames.DagNameMaxLength holds no Value, so the length was not judged.' }
    else {
        $row['Required'] = ('at most {0} characters' -f $maximum)
        New-ExchNameVerdict -Row $row -Free ($Name.Length -le [int]$maximum) -FreeStatus 'Valid' -HeldStatus 'Invalid' -Cause ('The DAG name is longer than the {0} characters Learn allows.' -f $maximum)
    }

    # NameCharacters
    $row = @{ Role = 'DagName'; Name = $Name; Check = 'NameCharacters'; Instrument = 'Config'; Source = $patternSource; Measured = $Name }
    if (-not $pattern) { New-ExchNameRow @row -Outcome 'Unknown' -Status 'NoValue' -Cause 'No value: PlannedNames.ComputerNamePattern holds no Value, so the characters were not judged.' }
    else {
        $row['Required'] = ('a valid computer name: matches {0}, not only numerals, first character alphabetic or numeric, last not a minus sign' -f $pattern)
        $reasons = @()
        if ($Name -notmatch [string]$pattern) { $reasons += 'it holds a character other than A-Z, 0-9 and the minus sign' }
        if ($Name -match '^[0-9]+$') { $reasons += 'it holds only numerals' }
        if ($Name.StartsWith('-')) { $reasons += 'it starts with a minus sign' }
        if ($Name.EndsWith('-')) { $reasons += 'it ends with a minus sign' }
        New-ExchNameVerdict -Row $row -Free ($reasons.Count -eq 0) -FreeStatus 'Valid' -HeldStatus 'Invalid' -Cause ('The DAG name is not a valid computer name: {0}.' -f ($reasons -join '; '))
    }

    # ComputerObject
    $row = @{
        Role = 'DagName'; Name = $Name; Check = 'ComputerObject'; Instrument = 'Directory'; Source = $lengthSource
        Required = 'no computer object in the forest and no planned server holds the name'
    }
    $collisions = @($PlannedServers | Where-Object { $_ -and $_.TrimEnd('.').Split('.')[0] -eq $Name })
    $lookup = $null
    try { $lookup = Find-ExchDirectoryComputer -Run $Run -Name $Name -Fqdn '' }
    catch {
        $null = Write-ExchError -Run $Run -Context ('Directory search for the computer name {0}' -f $Name) -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning'
        $message = ([string]$_.Exception.Message).TrimEnd('.')
        if ($collisions.Count -gt 0) {
            $row['HeldBy'] = @($collisions | ForEach-Object { "planned server $_" })
            $row['Measured'] = 'the directory was not read'
            New-ExchNameVerdict -Row $row -Free $false -FreeStatus 'NoObjectFound' -Cause ('The DAG name is the name of a planned server; the directory could not be searched as well: {0}.' -f $message)
        }
        else { New-ExchNameRow @row -Outcome 'Unknown' -Status 'Error' -Cause ('The directory could not be searched for {0}: {1}.' -f $Name, $message) }
        $lookup = $null
    }
    if ($null -ne $lookup) {
        $row['Scope'] = [string](Get-ExchPortItem -InputObject $lookup -Name 'Scope')
        $computers = @(Get-ExchPortItem -InputObject $lookup -Name 'Computers' | Where-Object { $null -ne $_ })
        $row['HeldBy'] = @(@($computers | ForEach-Object { Format-ExchComputerHolder -Computer $_ }) + @($collisions | ForEach-Object { "planned server $_" }))
        $row['Measured'] = if (@($row['HeldBy']).Count -eq 0) { ('no computer object named {0} in {1}, and no planned server has the name' -f $Name, $row['Scope']) } else { ('held by {0}' -f (@($row['HeldBy']) -join '; ')) }
        New-ExchNameVerdict -Row $row -Free (@($row['HeldBy']).Count -eq 0) -FreeStatus 'NoObjectFound' -Cause ('The DAG name must be unique within the Active Directory forest, and it is already held: {0}.' -f (@($row['HeldBy']) -join '; '))
    }

    # ExistingExchangeObject
    $row = @{
        Role = 'DagName'; Name = $Name; Check = 'ExistingExchangeObject'; Instrument = 'Directory'; Source = $lengthSource
        Required = 'no object under CN=Microsoft Exchange in the configuration partition holds the name'
    }
    try {
        $exchange = Find-ExchDirectoryExchangeObject -Run $Run -Name $Name
        $row['Scope'] = [string](Get-ExchPortItem -InputObject $exchange -Name 'Scope')
        if (-not [bool](Get-ExchPortItem -InputObject $exchange -Name 'ContainerExists')) {
            $row['Measured'] = ('{0} does not exist, so Active Directory is not prepared for Exchange and no DAG object exists' -f $row['Scope'])
            New-ExchNameVerdict -Row $row -Free $true -FreeStatus 'NoExchangeOrganization'
        }
        else {
            $objects = @(Get-ExchPortItem -InputObject $exchange -Name 'Objects' | Where-Object { $null -ne $_ })
            $row['HeldBy'] = @($objects | ForEach-Object { '{0} ({1})' -f [string](Get-ExchPortItem -InputObject $_ -Name 'DistinguishedName'), [string](Get-ExchPortItem -InputObject $_ -Name 'ObjectClass') })
            $row['Measured'] = if ($objects.Count -eq 0) { ('no object named {0} under {1}' -f $Name, $row['Scope']) } else { ('held by {0}' -f (@($row['HeldBy']) -join '; ')) }
            New-ExchNameVerdict -Row $row -Free ($objects.Count -eq 0) -FreeStatus 'NoObjectFound' -Cause ('An Exchange configuration object already holds the name, which is where an existing DAG is recorded: {0}.' -f (@($row['HeldBy']) -join '; '))
        }
    }
    catch {
        $null = Write-ExchError -Run $Run -Context ('Exchange configuration search for {0}' -f $Name) -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning'
        New-ExchNameRow @row -Outcome 'Unknown' -Status 'Error' -Cause ('The Exchange configuration could not be searched for {0}: {1}.' -f $Name, ([string]$_.Exception.Message).TrimEnd('.'))
    }
}

function Test-ExchPlannedDnsName {
    <#
    One planned internal name. Free when the resolver answers that the name does not exist. A name
    that resolves, or exists holding other record types, is reported with what holds it, and is not
    judged a failure: whether it is being reused on purpose is for the reader.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter()][string]$ControlId = ''
    )

    $row = @{
        Role = 'InternalName'; Name = $Name; Check = 'DnsRecord'; Instrument = 'DNS'; Scope = (Get-ExchPlannedDnsScope)
        Required = 'the name does not exist in DNS'
    }
    $answer = $null
    try { $answer = Resolve-ExchPlannedDnsName -Name $Name }
    catch { $answer = [pscustomobject]@{ Status = 'Error'; Records = @(); Error = [string]$_.Exception.Message } }

    $status = [string](Get-ExchPortItem -InputObject $answer -Name 'Status')
    $records = @(Get-ExchPortItem -InputObject $answer -Name 'Records' | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $row['HeldBy'] = $records
    switch ($status) {
        'NameDoesNotExist' {
            $row['Measured'] = 'the resolver answered that the name does not exist (NXDOMAIN)'
            return New-ExchNameVerdict -Row $row -Free $true -FreeStatus 'NameDoesNotExist'
        }
        'Resolves' {
            $row['Measured'] = ('resolves: {0}' -f ($records -join '; '))
            return New-ExchNameVerdict -Row $row -Free $false -FreeStatus 'NameDoesNotExist' -HeldOutcome 'PartiallyCompliant' -HeldStatus 'InUse' -Cause 'The name already resolves, so it is in use; what holds it is listed.'
        }
        'NoAddressRecord' {
            $row['Measured'] = ('the name exists without an address record: {0}' -f ($records -join '; '))
            return New-ExchNameVerdict -Row $row -Free $false -FreeStatus 'NameDoesNotExist' -HeldOutcome 'PartiallyCompliant' -HeldStatus 'NameExists' -Cause 'The DNS server answered for the name with no A, AAAA or CNAME record, so the name exists in DNS holding other record types.'
        }
    }
    $message = ([string](Get-ExchPortItem -InputObject $answer -Name 'Error')).TrimEnd('.')
    if (-not $message) { $message = ("the lookup returned status '{0}'" -f $status) }
    $null = Write-ExchEvent -Run $Run -Level WARN -Message 'Planned DNS name not resolved' -Data @{ controlId = $ControlId; name = $Name; error = $message }
    return New-ExchNameRow @row -Outcome 'Unknown' -Status 'Error' -Cause ('The name {0} could not be looked up: {1}.' -f $Name, $message)
}

function Format-ExchNameRowList {
    [CmdletBinding()]
    param([Parameter()][object[]]$Rows = @())

    return ((@($Rows) | ForEach-Object {
        $label = if ($_.Name) { "$($_.Role) $($_.Name)" } else { $_.Role }
        $text = ('{0} {1} ({2})' -f $label, $_.Check, $_.Measured)
        if ($_.Cause) { $text = ('{0} - {1}' -f $text, ([string]$_.Cause).TrimEnd('.')) }
        $text
    }) -join '; ')
}

function Get-ExchPlannedDnsScope {
    [CmdletBinding()]
    param()

    return 'the DNS servers configured on the assessment host (Resolve-DnsName -DnsOnly), for A and AAAA answers and the CNAMEs followed to them'
}

function Find-ExchDirectoryComputer {
    <#
    The computer objects holding a name - by cn, by sAMAccountName and, when a full name is given,
    by dNSHostName - searched in a global catalog of the assessment host's forest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter()][string]$Fqdn = ''
    )

    Assert-ExchADModule -Run $Run
    $catalog = Get-ExchDirectoryGlobalCatalog
    $escaped = ConvertTo-ExchLdapFilterValue -Value $Name
    $clauses = @(('(cn={0})' -f $escaped), ('(sAMAccountName={0}$)' -f $escaped))
    if ($Fqdn) { $clauses += ('(dNSHostName={0})' -f (ConvertTo-ExchLdapFilterValue -Value $Fqdn)) }
    $filter = '(&(objectCategory=computer)(|{0}))' -f ($clauses -join '')
    $computers = @(Get-ADComputer -LDAPFilter $filter -Server $catalog.Server -Properties DNSHostName -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Name; SamAccountName = [string]$_.SamAccountName; DNSHostName = [string]$_.DNSHostName; DistinguishedName = [string]$_.DistinguishedName }
    })
    return [pscustomobject]@{ Scope = $catalog.Scope; Computers = $computers }
}

function Find-ExchDirectoryExchangeObject {
    <#
    The objects holding a name under CN=Microsoft Exchange,CN=Services in the configuration
    partition, which /PrepareAD creates and where Exchange records an existing DAG. When that
    container does not exist, the directory is not prepared for Exchange and nothing there holds any
    name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )

    Assert-ExchADModule -Run $Run
    $rootDse = Get-ADRootDSE -ErrorAction Stop
    $services = 'CN=Services,{0}' -f [string]$rootDse.configurationNamingContext
    $scope = 'CN=Microsoft Exchange,{0}' -f $services
    $container = @(Get-ADObject -LDAPFilter '(cn=Microsoft Exchange)' -SearchBase $services -SearchScope OneLevel -ErrorAction Stop)
    if ($container.Count -eq 0) { return [pscustomobject]@{ Scope = $scope; ContainerExists = $false; Objects = @() } }

    $objects = @(Get-ADObject -LDAPFilter ('(cn={0})' -f (ConvertTo-ExchLdapFilterValue -Value $Name)) -SearchBase ([string]$container[0].DistinguishedName) -SearchScope Subtree -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ DistinguishedName = [string]$_.DistinguishedName; ObjectClass = [string]$_.ObjectClass }
    })
    return [pscustomobject]@{ Scope = $scope; ContainerExists = $true; Objects = $objects }
}

function Resolve-ExchPlannedDnsName {
    <#
    One DNS lookup of a planned name, asked of the assessment host's own resolvers only. Status is
    NameDoesNotExist (the server answered NXDOMAIN), Resolves (an answer came back), NoAddressRecord
    (the server answered for the name with no address record - measured on the dev VM, a name that
    exists without A or AAAA comes back as an Authority SOA only), or Error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name)

    $records = @()
    try { $records = @(Resolve-DnsName -Name $Name -DnsOnly -ErrorAction Stop) }
    catch {
        if ([string]$_.FullyQualifiedErrorId -like 'DNS_ERROR_RCODE_NAME_ERROR*') { return [pscustomobject]@{ Status = 'NameDoesNotExist'; Records = @(); Error = '' } }
        return [pscustomobject]@{ Status = 'Error'; Records = @(); Error = [string]$_.Exception.Message }
    }

    $answers = @($records | Where-Object { [string](Get-ExchObjectValue -InputObject $_ -Name 'Section' -Default '') -eq 'Answer' })
    if ($answers.Count -eq 0) {
        return [pscustomobject]@{ Status = 'NoAddressRecord'; Error = ''; Records = @($records | ForEach-Object {
            '{0} {1} in {2}' -f [string](Get-ExchObjectValue -InputObject $_ -Name 'Type' -Default ''), [string](Get-ExchObjectValue -InputObject $_ -Name 'Name' -Default ''), [string](Get-ExchObjectValue -InputObject $_ -Name 'Section' -Default '')
        }) }
    }
    return [pscustomobject]@{ Status = 'Resolves'; Error = ''; Records = @($answers | ForEach-Object {
        $data = [string](Get-ExchObjectValue -InputObject $_ -Name 'IPAddress' -Default '')
        if (-not $data) { $data = [string](Get-ExchObjectValue -InputObject $_ -Name 'NameHost' -Default '') }
        '{0} {1} {2}' -f [string](Get-ExchObjectValue -InputObject $_ -Name 'Type' -Default ''), [string](Get-ExchObjectValue -InputObject $_ -Name 'Name' -Default ''), $data
    }) }
}

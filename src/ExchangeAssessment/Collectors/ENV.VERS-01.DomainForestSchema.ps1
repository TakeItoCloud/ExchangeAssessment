<#
ENV.VERS-01 - Domain/forest functional level and Exchange Active Directory preparation.

Reports the forest and domain functional levels and the three values Exchange setup actually
gates on: rangeUpper on ms-Exch-Schema-Version-Pt, objectVersion on the organisation container
in the configuration naming context, and objectVersion on Microsoft Exchange System Objects in
the default naming context.

It also checks the Schema Master itself. Microsoft's supportability matrix carries an Important
note that a Schema Master running Windows Server 2025 must be on build 10.0.26100.7171 or later
(KB5068861) before any Exchange /PrepareSchema or /PrepareAD. That is a precondition of the
preparation this control reports on, so it belongs here; a Schema Master whose operating system
cannot be read makes that one item Unknown rather than taking the control down.

A functional level outside the configured lists is reported as not listed in Microsoft's
supported set, naming the levels that are - not asserted to be broken.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_ENV_VERS_01_DomainForestSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'ENV.VERS-01'

    try { Assert-ExchADModule -Run $Run }
    catch {
        $reason = "The ActiveDirectory module is not available, so forest, domain and Exchange schema state could not be read: $($_.Exception.Message)"
        $null = Write-ExchError -Run $Run -Context 'Import ActiveDirectory module' -ErrorRecord $_ -ControlId $control.controlId
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason -DataSource 'ActiveDirectory' `
                -Remediation 'Install RSAT Active Directory PowerShell on the Exchange server, or run the assessment from a host that has it, then re-run.'
        )
    }

    try {
        $root   = Get-ADRootDSE -ErrorAction Stop
        $forest = Get-ADForest -ErrorAction Stop
        $domain = Get-ADDomain -ErrorAction Stop
    }
    catch {
        $reason = "Active Directory could not be queried for forest, domain or RootDSE information: $($_.Exception.Message)"
        $null = Write-ExchError -Run $Run -Context 'Get-ADRootDSE / Get-ADForest / Get-ADDomain' -ErrorRecord $_ -ControlId $control.controlId
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason -DataSource 'ActiveDirectory' `
                -Remediation 'Confirm the account running the assessment can read the forest, domain and schema naming contexts, then re-run.'
        )
    }

    $forestMode = [string]$forest.ForestMode
    $domainMode = [string]$domain.DomainMode
    $adPrep = Get-ExchAdPreparationState -RootDse $root -Domain $domain
    $schemaMaster = Get-ExchSchemaMasterState -Run $Run -Forest $forest -ControlId $control.controlId

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'environment/domain-forest-schema.json' -ContentObject ([ordered]@{
        rootDse             = $root
        forest              = $forest
        domain              = $domain
        adSchemaVersion     = $adPrep.AdSchemaVersion
        exchangePreparation = $adPrep
        schemaMaster        = $schemaMaster
    })

    $forestLevel = Resolve-ExchFunctionalLevel -Run $Run -Mode $forestMode -Scope 'Forest'
    $domainLevel = Resolve-ExchFunctionalLevel -Run $Run -Mode $domainMode -Scope 'Domain'
    $prep = Resolve-ExchAdPreparation -Run $Run `
        -RangeUpper $adPrep.RangeUpper `
        -ObjectVersionConfiguration $adPrep.ObjectVersionConfiguration `
        -ObjectVersionDefault $adPrep.ObjectVersionDefault

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'environment.forest' -Title 'Active Directory Forest' -Area 'Environment' `
            -Columns @('Name', 'ForestMode', 'SchemaMaster', 'DomainNamingMaster', 'Domains', 'Sites', 'GlobalCatalogs') `
            -Rows @($forest)

        New-ExchInventorySection -Run $Run -Key 'environment.domain' -Title 'Active Directory Domain' -Area 'Environment' `
            -Columns @('Name', 'DNSRoot', 'NetBIOSName', 'DomainMode', 'PDCEmulator', 'DistinguishedName') `
            -Rows @($domain)

        New-ExchInventorySection -Run $Run -Key 'environment.ad-preparation' -Title 'Exchange Active Directory Preparation' -Area 'Environment' `
            -Columns @('RangeUpper', 'ObjectVersionConfiguration', 'ObjectVersionDefault', 'PreparedFor', 'MeetsTarget', 'TargetRangeUpper', 'TargetObjectVersionConfiguration', 'TargetObjectVersionDefault') `
            -Rows @($prep)

        New-ExchInventorySection -Run $Run -Key 'environment.schema-master' -Title 'Schema Master Readiness' -Area 'Environment' `
            -Columns @('SchemaMaster', 'OperatingSystem', 'Version', 'IsWindowsServer2025', 'MinimumBuild', 'MeetsMinimum', 'Assessed', 'Error') `
            -Rows @($schemaMaster)
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    foreach ($pair in @(
        @{ Label = 'Forest functional level'; Level = $forestLevel; Scope = 'Forest' },
        @{ Label = 'Domain functional level'; Level = $domainLevel; Scope = 'Domain' }
    )) {
        if (-not $pair.Level.Supported) {
            $problems.Add(("{0} {1} is not listed by Microsoft as supported for the Exchange versions this assessment covers; the levels that are listed are {2}" -f `
                $pair.Label, $pair.Level.Mode, ((@(Get-ExchThreshold -Run $Run -Name ("ActiveDirectory.Supported{0}Modes" -f $pair.Scope) -Default @())) -join ', '))) | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
        elseif (-not $pair.Level.Recommended) {
            $problems.Add(("{0} {1} is listed as supported but below the recommended level" -f $pair.Label, $pair.Level.Mode)) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }
        else {
            $outcomes.Add('Compliant') | Out-Null
        }
    }

    if ($adPrep.ReadErrors.Count -gt 0) {
        $problems.Add(("Exchange preparation values could not all be read: {0}" -f ($adPrep.ReadErrors -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif (-not $prep.MeetsTarget) {
        $problems.Add(("Active Directory is prepared for '{0}' (rangeUpper {1}, config objectVersion {2}), below the target rangeUpper {3} / objectVersion {4}" -f `
            $prep.PreparedFor, $prep.RangeUpper, $prep.ObjectVersionConfiguration, $prep.TargetRangeUpper, $prep.TargetObjectVersionConfiguration)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    else {
        $outcomes.Add('Compliant') | Out-Null
    }

    if (-not $schemaMaster.Assessed) {
        $problems.Add(("The Schema Master {0} could not be read, so its readiness for Exchange schema preparation is unknown: {1}" -f `
            $schemaMaster.SchemaMaster, $schemaMaster.Error)) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif ($schemaMaster.IsWindowsServer2025 -and -not $schemaMaster.MeetsMinimum) {
        $problems.Add(("The Schema Master {0} runs {1} build {2}, below the {3} that Microsoft requires on a Windows Server 2025 Schema Master before Exchange /PrepareSchema or /PrepareAD is run" -f `
            $schemaMaster.SchemaMaster, $schemaMaster.OperatingSystem, $schemaMaster.Version, $schemaMaster.MinimumBuild)) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Medium' }
        'Unknown'            { 'High' }
        default              { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) {
        ($problems -join '. ') + '.'
    }
    else {
        ("Forest level {0} and domain level {1} are listed as supported and recommended; Active Directory is prepared for {2}; the Schema Master {3} runs {4}, which is ready for Exchange schema preparation." -f `
            $forestMode, $domainMode, $prep.PreparedFor, $schemaMaster.SchemaMaster, $schemaMaster.OperatingSystem)
    }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($adPrep.ReadErrors.Count -gt 0 -or -not $schemaMaster.Assessed) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation ('Raise forest and domain functional levels to a recommended level, and run Exchange setup /PrepareSchema and /PrepareAD so the directory reaches the target preparation level. ' + `
            'Patch a Windows Server 2025 Schema Master to the required build first - see ' + `
            'https://learn.microsoft.com/exchange/plan-and-deploy/supportability-matrix#supported-active-directory-environments') `
        -Metrics @{
            forestMode                 = $forestMode
            domainMode                 = $domainMode
            adSchemaVersion            = $adPrep.AdSchemaVersion
            rangeUpper                 = $prep.RangeUpper
            objectVersionConfiguration = $prep.ObjectVersionConfiguration
            objectVersionDefault       = $prep.ObjectVersionDefault
            preparedFor                = $prep.PreparedFor
            meetsTarget                = $prep.MeetsTarget
            schemaMaster               = $schemaMaster.SchemaMaster
            schemaMasterOs             = $schemaMaster.OperatingSystem
            schemaMasterReady          = $(if ($schemaMaster.Assessed) { -not ($schemaMaster.IsWindowsServer2025 -and -not $schemaMaster.MeetsMinimum) } else { 'Unknown' })
        } `
        -Meta @{ dataSources = @{
            ActiveDirectory = @{ state = $(if ($adPrep.ReadErrors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($adPrep.ReadErrors -join '; ') }
            WinRM           = @{ state = $(if ($schemaMaster.Assessed) { 'Success' } else { 'Error' }); reason = [string]$schemaMaster.Error }
        }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchAdPreparationState {
    <#
    Reads the three Exchange preparation values out of Active Directory. Each is read
    independently so that one unreadable value does not hide the other two.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RootDse,
        [Parameter(Mandatory)]$Domain
    )

    $errors = New-Object System.Collections.Generic.List[string]

    $adSchemaVersion = $null
    try { $adSchemaVersion = [int]($RootDse.schemaVersion | Select-Object -First 1) }
    catch { $errors.Add('AD schema version unreadable') | Out-Null }

    $rangeUpper = $null
    try {
        $schemaDn = [string]$RootDse.schemaNamingContext
        $obj = Get-ADObject -Identity "CN=ms-Exch-Schema-Version-Pt,$schemaDn" -Properties rangeUpper -ErrorAction Stop
        $rangeUpper = [int]$obj.rangeUpper
    }
    catch { $errors.Add("ms-Exch-Schema-Version-Pt rangeUpper unreadable: $($_.Exception.Message)") | Out-Null }

    $objectVersionConfiguration = $null
    $organisationName = ''
    try {
        $configDn = [string]$RootDse.configurationNamingContext
        $org = Get-ADObject -SearchBase "CN=Microsoft Exchange,CN=Services,$configDn" `
            -Filter { objectClass -eq 'msExchOrganizationContainer' } -Properties objectVersion -ErrorAction Stop |
            Select-Object -First 1
        if ($org) {
            $objectVersionConfiguration = [int]$org.objectVersion
            $organisationName = [string]$org.Name
        }
        else { $errors.Add('No Exchange organisation container found in the configuration naming context') | Out-Null }
    }
    catch { $errors.Add("Exchange organisation objectVersion unreadable: $($_.Exception.Message)") | Out-Null }

    $objectVersionDefault = $null
    try {
        $domainDn = [string]$Domain.DistinguishedName
        $meso = Get-ADObject -Identity "CN=Microsoft Exchange System Objects,$domainDn" -Properties objectVersion -ErrorAction Stop
        $objectVersionDefault = [int]$meso.objectVersion
    }
    catch { $errors.Add("Microsoft Exchange System Objects objectVersion unreadable: $($_.Exception.Message)") | Out-Null }

    [pscustomobject]@{
        AdSchemaVersion            = $adSchemaVersion
        RangeUpper                 = $rangeUpper
        ObjectVersionConfiguration = $objectVersionConfiguration
        ObjectVersionDefault       = $objectVersionDefault
        OrganisationName           = $organisationName
        ReadErrors                 = @($errors.ToArray())
    }
}

function Get-ExchSchemaMasterState {
    <#
    Reads the Schema Master's operating system and says whether it is ready for Exchange schema
    preparation.

    The only version-specific rule Microsoft states here is the Windows Server 2025 one: a
    Schema Master on that release must be on ActiveDirectory.MinimumSchemaMaster2025Build or
    later before /PrepareSchema or /PrepareAD. Every other release is reported as read, with no
    verdict invented for it.

    Assessed is $false when the operating system could not be read at all. The caller reports
    that item as Unknown; it does not lose the rest of the control.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNull()]$Forest,
        [Parameter()][string]$ControlId = 'ENV.VERS-01'
    )

    $minimumBuild = [string](Get-ExchThreshold -Run $Run -Name 'ActiveDirectory.MinimumSchemaMaster2025Build' -Default '10.0.26100.7171')
    $knownBuilds  = @(Get-ExchThreshold -Run $Run -Name 'OperatingSystem.KnownBuilds' -Default @())

    $state = [pscustomobject]@{
        SchemaMaster        = [string](Get-ExchObjectValue -InputObject $Forest -Name 'SchemaMaster' -Default '')
        OperatingSystem     = 'Unread'
        Version             = ''
        IsWindowsServer2025 = $false
        MinimumBuild        = $minimumBuild
        MeetsMinimum        = $false
        Assessed            = $false
        Error               = ''
    }

    if (-not $state.SchemaMaster) {
        $state.Error = 'The forest did not report a Schema Master.'
        return $state
    }

    $osVersion = $null
    try {
        $target = $state.SchemaMaster
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $target -ErrorAction Stop
        $state.Version = [string]$os.Version
        $osVersion = [version]$state.Version
    }
    catch {
        $state.Error = [string]$_.Exception.Message
        $null = Write-ExchError -Run $Run -Context ('Get-CimInstance Win32_OperatingSystem on Schema Master {0}' -f $state.SchemaMaster) `
            -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning'
        return $state
    }

    $state.Assessed = $true

    $trimmed = [version]::new($osVersion.Major, $osVersion.Minor, [Math]::Max($osVersion.Build, 0))
    $state.OperatingSystem = Resolve-ExchOsBuildName -Build $trimmed -KnownBuilds $knownBuilds -Fallback $state.Version

    $minimum = $null
    try { $minimum = [version]$minimumBuild } catch { $minimum = $null }
    if ($null -eq $minimum) {
        $state.Assessed = $false
        $state.Error = "ActiveDirectory.MinimumSchemaMaster2025Build is '$minimumBuild', which is not a version number."
        return $state
    }

    # "Is this Windows Server 2025" is derived from the configured minimum rather than a literal
    # build, so the rule and the release it applies to cannot drift apart.
    $state.IsWindowsServer2025 = ($trimmed -eq [version]::new($minimum.Major, $minimum.Minor, $minimum.Build))
    $state.MeetsMinimum = (-not $state.IsWindowsServer2025) -or ($osVersion -ge $minimum)

    return $state
}

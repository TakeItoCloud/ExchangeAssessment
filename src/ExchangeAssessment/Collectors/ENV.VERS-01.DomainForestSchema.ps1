<#
ENV.VERS-01 - Domain/forest functional level and Exchange Active Directory preparation.

Reports the forest and domain functional levels and the three values Exchange setup actually
gates on: rangeUpper on ms-Exch-Schema-Version-Pt, objectVersion on the organisation container
in the configuration naming context, and objectVersion on Microsoft Exchange System Objects in
the default naming context.
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

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'environment/domain-forest-schema.json' -ContentObject ([ordered]@{
        rootDse             = $root
        forest              = $forest
        domain              = $domain
        adSchemaVersion     = $adPrep.AdSchemaVersion
        exchangePreparation = $adPrep
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
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    foreach ($pair in @(
        @{ Label = 'Forest functional level'; Level = $forestLevel },
        @{ Label = 'Domain functional level'; Level = $domainLevel }
    )) {
        if (-not $pair.Level.Supported) {
            $problems.Add(("{0} {1} is not supported for Exchange" -f $pair.Label, $pair.Level.Mode)) | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
        elseif (-not $pair.Level.Recommended) {
            $problems.Add(("{0} {1} is supported but below the recommended level" -f $pair.Label, $pair.Level.Mode)) | Out-Null
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
        ("Forest level {0} and domain level {1} are supported and recommended; Active Directory is prepared for {2}." -f $forestMode, $domainMode, $prep.PreparedFor)
    }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($adPrep.ReadErrors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Raise forest and domain functional levels to a recommended level, and run Exchange setup /PrepareSchema and /PrepareAD so the directory reaches the target preparation level.' `
        -Metrics @{
            forestMode                 = $forestMode
            domainMode                 = $domainMode
            adSchemaVersion            = $adPrep.AdSchemaVersion
            rangeUpper                 = $prep.RangeUpper
            objectVersionConfiguration = $prep.ObjectVersionConfiguration
            objectVersionDefault       = $prep.ObjectVersionDefault
            preparedFor                = $prep.PreparedFor
            meetsTarget                = $prep.MeetsTarget
        } `
        -Meta @{ dataSources = @{ ActiveDirectory = @{ state = $(if ($adPrep.ReadErrors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($adPrep.ReadErrors -join '; ') } }; evaluationStatus = 'Complete' }

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

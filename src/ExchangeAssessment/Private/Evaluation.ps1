<#
Shared evaluation helpers.

Every judgement about a version, build or functional level goes through one of these, so the
supportability rules live in exactly one place instead of being restated by each collector that
happens to care. They read their thresholds from the run configuration and return a decision
plus the reason for it - the reason is what ends up in the finding's rationale.
#>

Set-StrictMode -Version Latest

function Resolve-ExchProductFamily {
    <#
    Maps an Exchange AdminDisplayVersion onto its product family and support state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][int]$Major,
        [Parameter(Mandatory)][int]$Minor,
        [Parameter()][int]$Build = 0
    )

    $families = @(Get-ExchThreshold -Run $Run -Name 'Exchange.Families' -Default @())

    foreach ($family in $families) {
        if ([int]$family.Major -ne $Major) { continue }
        if ([int]$family.Minor -ne $Minor) { continue }
        if ($Build -lt [int]$family.MinBuild) { continue }

        return [pscustomobject]@{
            Name         = [string]$family.Name
            Supported    = [bool]$family.Supported
            EndOfSupport = [string]$family.EndOfSupport
            Matched      = $true
        }
    }

    return [pscustomobject]@{
        Name         = ("Unrecognised Exchange build {0}.{1}.{2}" -f $Major, $Minor, $Build)
        Supported    = $false
        EndOfSupport = ''
        Matched      = $false
    }
}

function Resolve-ExchOsSupport {
    <#
    Decides whether a Windows Server build is supported for the Exchange version installed on
    that server, and names both sides.

    The supported operating system list is per Exchange version, not global: Exchange Server SE
    and 2019 want Windows Server 2019 or later, while Exchange Server 2016 wants Windows Server
    2016 or earlier. A single ">= this build" floor gets the second case exactly backwards, so
    the decision is made against the product's explicit SupportedBuilds list.

    Matched is $false when the product has no row in the matrix. That is "cannot judge", and the
    caller must report it as Unknown rather than as a verdict either way.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][string]$Version,
        [Parameter()][string]$Product = ''
    )

    $result = [pscustomobject]@{
        Name             = 'Unknown'
        Product          = $Product
        Supported        = $false
        Recommended      = $false
        Parsed           = $false
        Matched          = $false
        MinimumBuild     = ''
        RecommendedBuild = ''
        SupportedNames   = ''
    }

    if (-not $Version) { return $result }

    $parsed = $null
    try { $parsed = [version]$Version } catch { return $result }
    $result.Parsed = $true

    # Match on major.minor.build; the revision differs with every update.
    $trimmed = [version]::new($parsed.Major, $parsed.Minor, [Math]::Max($parsed.Build, 0))

    $known = @(Get-ExchThreshold -Run $Run -Name 'OperatingSystem.KnownBuilds' -Default @())
    $result.Name = Resolve-ExchOsBuildName -Build $trimmed -KnownBuilds $known -Fallback $Version

    $row = $null
    foreach ($candidate in @(Get-ExchThreshold -Run $Run -Name 'OperatingSystem.SupportMatrix' -Default @())) {
        if ([string]$candidate.Product -eq $Product) { $row = $candidate; break }
    }
    if ($null -eq $row) { return $result }

    $result.Matched          = $true
    $result.MinimumBuild     = [string]$row.MinimumBuild
    $result.RecommendedBuild = [string]$row.RecommendedBuild

    $supportedNames = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($row.SupportedBuilds)) {
        $supportedVersion = $null
        try { $supportedVersion = [version]$entry } catch { continue }
        $supportedNames.Add((Resolve-ExchOsBuildName -Build $supportedVersion -KnownBuilds $known -Fallback ([string]$entry))) | Out-Null
        if ($trimmed -eq $supportedVersion) { $result.Supported = $true }
    }
    $result.SupportedNames = ($supportedNames.ToArray() -join ', ')

    if ($result.Supported -and $row.RecommendedBuild) {
        $recommended = $null
        try { $recommended = [version]$row.RecommendedBuild } catch { $recommended = $null }
        if ($recommended) { $result.Recommended = ($trimmed -ge $recommended) }
    }

    return $result
}

function Resolve-ExchOsBuildName {
    <#
    Names a Windows Server build from the configured build-to-name list, falling back to the
    build string when the list does not know it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][version]$Build,
        [Parameter()][object[]]$KnownBuilds = @(),
        [Parameter()][string]$Fallback = ''
    )

    foreach ($known in @($KnownBuilds)) {
        $knownVersion = $null
        try { $knownVersion = [version]$known.Build } catch { continue }
        if ($Build -eq $knownVersion) { return [string]$known.Name }
    }

    if ($Fallback) { return $Fallback }
    return $Build.ToString()
}

function Resolve-ExchFunctionalLevel {
    <#
    Classifies a forest or domain functional level as supported, recommended, or neither.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][string]$Mode,
        [Parameter(Mandatory)][ValidateSet('Forest', 'Domain')][string]$Scope
    )

    $supported   = @(Get-ExchThreshold -Run $Run -Name ("ActiveDirectory.Supported{0}Modes" -f $Scope)   -Default @())
    $recommended = @(Get-ExchThreshold -Run $Run -Name ("ActiveDirectory.Recommended{0}Modes" -f $Scope) -Default @())

    return [pscustomobject]@{
        Mode        = $Mode
        Supported   = [bool]($Mode -and ($supported   -contains $Mode))
        Recommended = [bool]($Mode -and ($recommended -contains $Mode))
    }
}

function Resolve-ExchAdPreparation {
    <#
    Names the Exchange version the directory is prepared for, and says whether it reaches the
    target level configured for the assessment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()]$RangeUpper,
        [Parameter()]$ObjectVersionConfiguration,
        [Parameter()]$ObjectVersionDefault
    )

    $targetRange   = [int](Get-ExchThreshold -Run $Run -Name 'ActiveDirectory.TargetSchemaRangeUpper'           -Default 17003)
    $targetConfig  = [int](Get-ExchThreshold -Run $Run -Name 'ActiveDirectory.TargetObjectVersionConfiguration' -Default 16763)
    $targetDefault = [int](Get-ExchThreshold -Run $Run -Name 'ActiveDirectory.TargetObjectVersionDefault'       -Default 13243)

    $range   = if ($null -ne $RangeUpper)                 { [int]$RangeUpper }                 else { 0 }
    $config  = if ($null -ne $ObjectVersionConfiguration) { [int]$ObjectVersionConfiguration } else { 0 }
    $default = if ($null -ne $ObjectVersionDefault)       { [int]$ObjectVersionDefault }       else { 0 }

    $name = ''
    foreach ($level in @(Get-ExchThreshold -Run $Run -Name 'ActiveDirectory.KnownPreparationLevels' -Default @())) {
        if ([int]$level.RangeUpper -eq $range -and [int]$level.ConfigVersion -eq $config) {
            $name = [string]$level.Name
            break
        }
    }

    return [pscustomobject]@{
        RangeUpper                 = $range
        ObjectVersionConfiguration = $config
        ObjectVersionDefault       = $default
        PreparedFor                = $(if ($name) { $name } else { 'Unrecognised preparation level' })
        MeetsTarget                = ($range -ge $targetRange -and $config -ge $targetConfig -and $default -ge $targetDefault)
        TargetRangeUpper           = $targetRange
        TargetObjectVersionConfiguration = $targetConfig
        TargetObjectVersionDefault = $targetDefault
    }
}

function Get-ExchWorstOutcome {
    <#
    Combines per-item verdicts into one control outcome. NonCompliant beats
    PartiallyCompliant beats Compliant; Unknown only wins when there is nothing else.
    #>
    [CmdletBinding()]
    param([Parameter()][string[]]$Outcomes = @())

    $set = @($Outcomes | Where-Object { $_ })
    if ($set.Count -eq 0) { return 'Unknown' }
    if ($set -contains 'NonCompliant')       { return 'NonCompliant' }
    if ($set -contains 'PartiallyCompliant') { return 'PartiallyCompliant' }
    if ($set -contains 'Compliant')          { return 'Compliant' }
    return 'Unknown'
}

function New-ExchControlFinding {
    <#
    Builds a finding from a catalog control, so a collector states only what it measured and
    concluded. Domain, id, title, target, framework mappings and Microsoft references all come
    from the catalog entry and cannot drift from it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Control,
        [Parameter(Mandatory)][ValidateSet('Info','Low','Medium','High','Critical')][string]$Severity,
        [Parameter(Mandatory)][ValidateSet('Compliant','PartiallyCompliant','NonCompliant','Unknown')][string]$Outcome,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Rationale,
        [Parameter()][object[]]$Evidence = @(),
        [Parameter()][string]$Remediation = '',
        [Parameter()][ValidateSet('Pass','SoftFail','HardFail')][string]$Sufficiency = 'Pass',
        [Parameter()][hashtable]$Metrics = @{},
        [Parameter()][hashtable]$Meta = @{}
    )

    New-ExchFinding `
        -ControlDomain ([string]$Control.domain) `
        -ControlId ([string]$Control.controlId) `
        -Severity $Severity `
        -Title ([string]$Control.title) `
        -Description ([string]$Control.target) `
        -Outcome $Outcome `
        -Rationale $Rationale `
        -Evidence $Evidence `
        -Remediation $Remediation `
        -FrameworkMappings @($Control.mappings) `
        -References (Get-ExchControlReference -Control $Control) `
        -Sufficiency $Sufficiency `
        -Metrics $Metrics `
        -Meta $Meta
}

function New-ExchUnavailableFinding {
    <#
    The finding for "this control could not be evaluated". Always Unknown/HardFail with the
    reason attached - never a quiet pass.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Control,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason,
        [Parameter()][string]$Remediation = '',
        [Parameter()][string]$DataSource = 'Exchange',
        [Parameter()][ValidateSet('Info','Low','Medium','High','Critical')][string]$Severity = 'High'
    )

    New-ExchControlFinding -Control $Control -Severity $Severity -Outcome 'Unknown' -Sufficiency 'HardFail' `
        -Rationale $Reason `
        -Remediation $Remediation `
        -Metrics @{ error = $Reason } `
        -Meta @{ dataSources = @{ $DataSource = @{ state = 'Error'; reason = $Reason } }; evaluationStatus = 'Failed' }
}

function Invoke-ExchQuery {
    <#
    Runs one Exchange query and records, rather than swallows, its failure.

    Collectors that read several independent configuration objects use this so that one missing
    cmdlet does not hide the others - and so the finding can say exactly which query failed
    instead of reporting a silent pass.

    The short message goes into $Errors for the finding's rationale. When -Run is supplied the
    full error detail - exception type, error id, target, script position, stack trace and the
    inner exception chain - is written to the run log and the run's error list as well.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label,
        # AllowEmptyCollection: an empty error list is the normal case, and PowerShell
        # otherwise refuses to bind it to a mandatory collection parameter.
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors,
        [Parameter(Mandatory)][scriptblock]$Script,
        [Parameter()]$Run,
        [Parameter()][string]$ControlId = ''
    )

    try { return & $Script }
    catch {
        $Errors.Add(("{0}: {1}" -f $Label, $_.Exception.Message)) | Out-Null

        if ($Run) {
            try { $null = Write-ExchError -Run $Run -Context $Label -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning' }
            catch { Write-Warning ("Could not record the failure of {0}: {1}" -f $Label, $_.Exception.Message) }
        }

        return @()
    }
}

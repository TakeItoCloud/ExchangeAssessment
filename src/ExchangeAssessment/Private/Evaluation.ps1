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
    Decides whether a Windows Server build is supported for Exchange, and names it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][string]$Version
    )

    $result = [pscustomobject]@{
        Name        = 'Unknown'
        Supported   = $false
        Recommended = $false
        Parsed      = $false
    }

    if (-not $Version) { return $result }

    $parsed = $null
    try { $parsed = [version]$Version } catch { return $result }
    $result.Parsed = $true

    $minimum = $null
    $recommended = $null
    try { $minimum = [version](Get-ExchThreshold -Run $Run -Name 'OperatingSystem.MinimumBuild' -Default '10.0.17763') } catch { $minimum = $null }
    try { $recommended = [version](Get-ExchThreshold -Run $Run -Name 'OperatingSystem.RecommendedBuild' -Default '10.0.20348') } catch { $recommended = $null }

    # Match on major.minor.build; the revision differs with every update.
    $trimmed = [version]::new($parsed.Major, $parsed.Minor, [Math]::Max($parsed.Build, 0))

    foreach ($known in @(Get-ExchThreshold -Run $Run -Name 'OperatingSystem.KnownBuilds' -Default @())) {
        $knownVersion = $null
        try { $knownVersion = [version]$known.Build } catch { continue }
        if ($trimmed -eq $knownVersion) { $result.Name = [string]$known.Name; break }
    }
    if ($result.Name -eq 'Unknown') { $result.Name = $Version }

    if ($minimum)     { $result.Supported   = ($trimmed -ge $minimum) }
    if ($recommended) { $result.Recommended = ($trimmed -ge $recommended) }

    return $result
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label,
        # AllowEmptyCollection: an empty error list is the normal case, and PowerShell
        # otherwise refuses to bind it to a mandatory collection parameter.
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors,
        [Parameter(Mandatory)][scriptblock]$Script
    )

    try { return & $Script }
    catch {
        $Errors.Add(("{0}: {1}" -f $Label, $_.Exception.Message)) | Out-Null
        return @()
    }
}

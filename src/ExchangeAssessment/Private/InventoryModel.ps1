<#
The inventory model.

A collector reports two separate things: the configuration it found (inventory sections) and
the judgements it reached about that configuration (findings). Keeping them apart is what lets
the CSV and JSON writers stay generic - they render whatever sections exist without knowing
anything about Exchange - and it removes the old pressure on a collector to invent a finding
when all it really had was an inventory to report.

A section is a table: a stable key, a display title, an area, an ordered column list, and rows
already flattened to CSV-safe scalars.
#>

Set-StrictMode -Version Latest

function New-ExchInventorySection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:\.[a-z0-9\-]+)*$')][string]$Key,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Title,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Area,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Columns,
        [Parameter()][object[]]$Rows = @(),
        # Sections whose row count scales with the size of the organisation (mailboxes, mobile
        # devices, public folders, queues). These are summarised unless -FullInventory was asked
        # for, so that assessment.json stays uploadable. The CSV always holds every row.
        [Parameter()][switch]$HighCardinality
    )

    $source = @($Rows | Where-Object { $null -ne $_ })
    $flat = @($source | ForEach-Object { ConvertTo-ExchFlatRow -Columns $Columns -InputObject $_ })

    $total = $flat.Count
    $truncated = $false
    $emitted = $flat

    if ($HighCardinality -and -not (Get-ExchRunFlag -Run $Run -Name 'FullInventory')) {
        $max = [int](Get-ExchThreshold -Run $Run -Name 'MaxRowsPerSection' -Default 500)
        if ($max -gt 0 -and $total -gt $max) {
            $emitted = @($flat | Select-Object -First $max)
            $truncated = $true
        }
    }

    [pscustomobject]@{
        key             = $Key
        title           = $Title
        area            = $Area
        columns         = @($Columns)
        rows            = $emitted
        totalRows       = $total
        truncated       = $truncated
        highCardinality = [bool]$HighCardinality
        # Rows always land in full on disk; only the JSON view is ever trimmed.
        allRows         = $flat
    }
}

function New-ExchCollectorResult {
    <#
    The value every collector returns: what it found, and what it concluded.
    Either list may be empty - a pure inventory collector returns no findings, and a collector
    that could not reach its data source returns a finding and no sections.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object[]]$Sections = @(),
        [Parameter()][object[]]$Findings = @()
    )

    [pscustomobject]@{
        sections = @(@($Sections) | Where-Object { $null -ne $_ })
        findings = @(@($Findings) | Where-Object { $null -ne $_ })
    }
}

function ConvertTo-ExchCollectorResult {
    <#
    Normalises whatever a collector returned into the sections/findings shape. A collector that
    returns nothing yields an empty result rather than a null the dispatcher has to guard.
    #>
    [CmdletBinding()]
    param([Parameter()]$InputObject)

    if ($null -eq $InputObject) { return (New-ExchCollectorResult) }

    $hasSections = [bool]($InputObject.PSObject.Properties.Match('sections') | Select-Object -First 1)
    $hasFindings = [bool]($InputObject.PSObject.Properties.Match('findings') | Select-Object -First 1)

    if ($hasSections -or $hasFindings) {
        $sections = if ($hasSections) { $InputObject.sections } else { @() }
        $findings = if ($hasFindings) { $InputObject.findings } else { @() }
        return (New-ExchCollectorResult -Sections @($sections) -Findings @($findings))
    }

    # A bare finding object.
    return (New-ExchCollectorResult -Findings @($InputObject))
}

function New-ExchCollectorFailureFinding {
    <#
    The finding raised when a collector throws. An assessment that quietly loses a control is
    worse than one that reports it could not run the control, so the failure is carried into
    the findings rather than left in the log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ControlId,
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Message
    )

    $control = $null
    try { $control = Get-ExchControlById -ControlId $ControlId } catch { $control = $null }

    $domain = 'Other'
    $title = "$ControlId collector"
    $target = 'Control could not be evaluated.'
    $mappings = @()
    $references = @()

    if ($control) {
        $domain = [string]$control.domain
        $title = [string]$control.title
        $target = [string]$control.target
        $mappings = @($control.mappings)
        if ($control.Contains('references')) { $references = @($control.references) }
    }

    New-ExchFinding `
        -ControlDomain $domain `
        -ControlId $ControlId `
        -Severity 'High' `
        -Title $title `
        -Description $target `
        -Outcome 'Unknown' `
        -Sufficiency 'HardFail' `
        -Rationale ("The {0} collector threw and the control was not evaluated: {1}" -f $ControlId, $Message) `
        -Remediation 'Review the run log, resolve the underlying error, and re-run the assessment. This control has no result until it does.' `
        -FrameworkMappings $mappings `
        -References $references `
        -Metrics @{ error = $Message; area = $Area } `
        -Meta @{ dataSources = @{ Collector = @{ state = 'Error'; reason = $Message } }; evaluationStatus = 'Failed' }
}

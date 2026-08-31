<#
Writes assessment.json - the one file that carries the whole assessment.

It holds the configuration inventory, the findings with their rationale and Microsoft
references, and the control catalog, so that a reader who has never seen the organisation can
work out what is configured, what is wrong, and what the vendor says about it.

Large organisations produce inventories that no upload will accept, so sections marked
high-cardinality are summarised unless -FullInventory was requested, and if the file is still
over budget the inventory splits into per-area parts that each stay uploadable. The CSVs keep
every row either way.
#>

function New-ExchAssessmentJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][object[]]$Sections = @(),
        [Parameter()][object[]]$Findings = @(),
        [Parameter()]$Collection
    )

    $ErrorActionPreference = 'Stop'

    $findingList = @($Findings | Where-Object { $null -ne $_ })
    $sectionList = @($Sections | Where-Object { $null -ne $_ })

    $summary = [ordered]@{
        totalFindings = $findingList.Count
        byOutcome     = (Get-ExchGroupCount -Items $findingList -Selector { param($f) $f.result.outcome })
        bySeverity    = (Get-ExchGroupCount -Items $findingList -Selector { param($f) $f.severity })
        byArea        = (Get-ExchGroupCount -Items $findingList -Selector { param($f) $f.controlDomain })
        sections      = $sectionList.Count
        inventoryRows = (($sectionList | Measure-Object -Property totalRows -Sum).Sum)
    }

    if ($Collection) {
        $summary['collectorsRun']     = @($Collection.Ran)
        $summary['collectorsSkipped'] = @($Collection.Skipped)
        $summary['collectorsFailed']  = @($Collection.Failed)
    }

    $inventory = [ordered]@{}
    foreach ($s in $sectionList) {
        $inventory[$s.key] = [ordered]@{
            title     = $s.title
            area      = $s.area
            columns   = @($s.columns)
            totalRows = $s.totalRows
            truncated = $s.truncated
            rows      = @($s.rows)
        }
    }

    $catalog = @()
    try { $catalog = @(Get-ExchControlCatalog) } catch { $catalog = @() }

    $document = [ordered]@{
        schemaVersion = '2.0'
        meta          = [ordered]@{
            runId         = $Run.RunId
            tenantHint    = $Run.TenantHint
            generatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
            toolVersion   = (Get-ExchModuleVersion)
            fullInventory = (Get-ExchRunFlag -Run $Run -Name 'FullInventory')
            includeCloud  = (Get-ExchRunFlag -Run $Run -Name 'IncludeExchangeOnline')
            configPath    = $(if ($Run.ConfigPath) { $Run.ConfigPath } else { 'default' })
            parts         = @()
        }
        summary       = $summary
        inventory     = $inventory
        findings      = $findingList
        controls      = $catalog
    }

    $mainPath = Join-Path $Run.RunFolder 'assessment.json'
    $json = $document | ConvertTo-Json -Depth 20
    $budget = [int](Get-ExchThreshold -Run $Run -Name 'MaxAssessmentJsonBytes' -Default 8388608)

    $written = New-Object System.Collections.Generic.List[string]

    if ($budget -gt 0 -and ([System.Text.Encoding]::UTF8.GetByteCount($json)) -gt $budget -and $inventory.Count -gt 0) {
        # Split the inventory out per area so each file stays uploadable on its own.
        $byArea = @{}
        foreach ($s in $sectionList) {
            $area = if ($s.area) { $s.area } else { 'Other' }
            if (-not $byArea.ContainsKey($area)) { $byArea[$area] = [ordered]@{} }
            $byArea[$area][$s.key] = $inventory[$s.key]
        }

        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($area in ($byArea.Keys | Sort-Object)) {
            $slug = ($area.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
            $partName = "assessment-inventory-$slug.json"
            $partPath = Join-Path $Run.RunFolder $partName
            $partDoc = [ordered]@{
                schemaVersion = '2.0'
                meta          = [ordered]@{
                    runId        = $Run.RunId
                    tenantHint   = $Run.TenantHint
                    generatedUtc = $document.meta.generatedUtc
                    area         = $area
                    partOf       = 'assessment.json'
                }
                inventory     = $byArea[$area]
            }
            ($partDoc | ConvertTo-Json -Depth 20) | Set-Content -Path $partPath -Encoding UTF8
            $parts.Add($partName) | Out-Null
            $written.Add($partPath) | Out-Null
        }

        $document.meta.parts = $parts.ToArray()
        $document.inventory = [ordered]@{}
        $document.summary['inventorySplit'] = $true
        $json = $document | ConvertTo-Json -Depth 20
    }

    $json | Set-Content -Path $mainPath -Encoding UTF8
    $written.Add($mainPath) | Out-Null

    Write-ExchEvent -Run $Run -Level INFO -Message 'Assessment JSON written' -Data @{
        path  = $mainPath
        bytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
        parts = @($document.meta.parts).Count
    }

    return $mainPath
}

function Get-ExchGroupCount {
    <#
    Counts items by a selector, as an ordered hashtable that survives JSON serialisation.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object[]]$Items = @(),
        [Parameter(Mandatory)][scriptblock]$Selector
    )

    $counts = @{}
    foreach ($item in @($Items)) {
        $key = [string](& $Selector $item)
        if (-not $key) { $key = 'Unknown' }
        if (-not $counts.ContainsKey($key)) { $counts[$key] = 0 }
        $counts[$key] += 1
    }

    $ordered = [ordered]@{}
    foreach ($key in ($counts.Keys | Sort-Object)) { $ordered[$key] = $counts[$key] }
    return $ordered
}

function Get-ExchModuleVersion {
    [CmdletBinding()]
    param()

    try {
        $manifest = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'ExchangeAssessment.psd1'
        if (Test-Path -LiteralPath $manifest) {
            return [string](Import-PowerShellDataFile -Path $manifest).ModuleVersion
        }
    }
    catch {
        Write-Verbose ("Unable to read module version: {0}" -f $_.Exception.Message)
    }
    return 'unknown'
}

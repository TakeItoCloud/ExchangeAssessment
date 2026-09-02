<#
EX.CH-01 - Exchange product version and build currency.

Two separate questions, answered separately:
  1. Is the product version still supported? Exchange 2016 and 2019 reached end of support on
     14 October 2025; only Exchange Server SE is supported.
  2. Is the build current? Answered from Config/BuildTable.psd1, which carries the date it was
     last refreshed. A build newer than the table is reported as unverifiable, never as current,
     and once the table itself is older than Exchange.MaxBuildTableAgeDays the finding says so -
     currency judged against a stale reference is a weaker statement, and the report should not
     hide that.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_EX_CH_01_ExchangeVersionCU {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'EX.CH-01'

    try { $servers = @(Get-ExchangeServer -ErrorAction Stop) }
    catch {
        $reason = "Get-ExchangeServer failed, so no Exchange build could be read: $($_.Exception.Message)"
        $null = Write-ExchError -Run $Run -Context 'Get-ExchangeServer' -ErrorRecord $_ -ControlId $control.controlId
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason `
                -Remediation 'Run the assessment from an Exchange Management Shell using an account that can enumerate servers.'
        )
    }

    if ($servers.Count -eq 0) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control `
                -Reason 'Get-ExchangeServer returned no servers, so no build could be assessed.' `
                -Remediation 'Confirm the session is connected to the intended Exchange organisation.'
        )
    }

    $maxAgeDays = [int](Get-ExchThreshold -Run $Run -Name 'Exchange.MaxBuildAgeDays' -Default 180)
    $flagMixed  = [bool](Get-ExchThreshold -Run $Run -Name 'Exchange.FlagMixedVersions' -Default $true)
    $maxTableAgeDays = [int](Get-ExchThreshold -Run $Run -Name 'Exchange.MaxBuildTableAgeDays' -Default 60)

    # Loaded once. A missing or unparseable table throws rather than degrading to "nothing is
    # known", which would look like a clean run.
    try { $table = Get-ExchBuildTable -Run $Run }
    catch {
        $reason = "The Exchange build table could not be loaded, so build currency could not be assessed: $($_.Exception.Message)"
        $null = Write-ExchError -Run $Run -Context 'Get-ExchBuildTable' -ErrorRecord $_ -ControlId $control.controlId
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason -DataSource 'BuildTable' `
                -Remediation 'Restore src/ExchangeAssessment/Config/BuildTable.psd1, or pass a valid copy with -BuildTablePath.'
        )
    }
    $tableAgeDays = [int][math]::Round(((Get-Date) - $table.TableAsOf).TotalDays, 0)

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($srv in $servers) {
        $adv = $srv.AdminDisplayVersion
        $major = 0; $minor = 0; $build = 0; $revision = 0
        try { $major = [int]$adv.Major; $minor = [int]$adv.Minor; $build = [int]$adv.Build } catch { $major = 0 }
        try { $revision = [int]$adv.Revision } catch { $revision = 0 }

        $family = Resolve-ExchProductFamily -Run $Run -Major $major -Minor $minor -Build $build
        $buildString = ('{0}.{1}.{2}.{3}' -f $major, $minor, $build, $revision)
        $known = Resolve-ExchBuild -Build $buildString -Product $family.Name -Table $table

        $ageDays = $null
        if ($known.Known -and $known.Released) { $ageDays = [math]::Round(((Get-Date) - $known.Released).TotalDays, 0) }

        $records.Add([pscustomobject]@{
            Server        = [string]$srv.Name
            Edition       = [string]$srv.Edition
            Product       = $family.Name
            Supported     = $family.Supported
            EndOfSupport  = $family.EndOfSupport
            Build         = $buildString
            AdminDisplayVersion = [string]$adv
            Release       = $(if ($known.Known) { $known.Release } elseif ($known.NewerThanTable) { 'Newer than the build table' } else { 'Unrecognised build' })
            BuildKnown    = $known.Known
            ReleaseDate   = $known.Released
            BuildAgeDays  = $ageDays
        }) | Out-Null
    }

    $recArr = @($records.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'exchange/builds.json' -ContentObject ([ordered]@{
        servers          = $recArr
        buildTableAsOf   = $table.TableAsOf
        buildTableSource = $table.Source
        buildTablePath   = $table.Path
        buildTableRows   = @($table.Builds).Count
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'exchange.builds' -Title 'Exchange Server Builds' -Area 'Exchange' `
            -Columns @('Server', 'Edition', 'Product', 'Supported', 'EndOfSupport', 'Build', 'Release', 'ReleaseDate', 'BuildAgeDays', 'BuildKnown') `
            -Rows $recArr
    )

    $unsupported = @($recArr | Where-Object { -not $_.Supported })
    $products    = @($recArr | ForEach-Object { $_.Product } | Sort-Object -Unique)
    $stale       = @($recArr | Where-Object { $null -ne $_.BuildAgeDays -and $_.BuildAgeDays -gt $maxAgeDays })
    $unverified  = @($recArr | Where-Object { -not $_.BuildKnown })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($unsupported.Count -gt 0) {
        $detail = ($unsupported | ForEach-Object {
            if ($_.EndOfSupport) { "$($_.Server) runs $($_.Product), out of support since $($_.EndOfSupport)" }
            else { "$($_.Server) runs $($_.Product), which is not a supported version" }
        }) -join '; '
        $problems.Add($detail) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    if ($flagMixed -and $products.Count -gt 1) {
        $problems.Add(("The organisation runs more than one Exchange product version at once ({0}), which is a migration state rather than a steady one" -f ($products -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($stale.Count -gt 0) {
        $problems.Add(("{0} servers run a build released more than {1} days ago: {2}" -f `
            $stale.Count, $maxAgeDays, (($stale | ForEach-Object { "$($_.Server) $($_.Release) ($($_.BuildAgeDays)d)" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($unverified.Count -gt 0) {
        $problems.Add(("Build currency could not be verified for {0} servers because their build is not in the build table, which was last refreshed on {1}: {2}" -f `
            $unverified.Count, $table.TableAsOf.ToString('yyyy-MM-dd'), (($unverified | ForEach-Object { "$($_.Server) $($_.Build)" }) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    $tableStale = ($maxTableAgeDays -gt 0 -and $tableAgeDays -gt $maxTableAgeDays)
    if ($tableStale) {
        $problems.Add(("Build currency is being judged against a build table last refreshed on {0}, {1} days ago, which is beyond the {2}-day limit - a build reported as current may since have been superseded by a security update" -f `
            $table.TableAsOf.ToString('yyyy-MM-dd'), $tableAgeDays, $maxTableAgeDays)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Medium' }
        'Unknown'            { 'Medium' }
        default              { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else { ("All {0} servers run {1} on a current build." -f $recArr.Count, ($products -join ', ')) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($unverified.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Move to Exchange Server SE and apply the current cumulative update and security updates. Where servers sit on different product versions, complete the migration rather than running mixed indefinitely.' `
        -Metrics @{
            serverCount      = $recArr.Count
            products         = $products
            unsupportedCount = $unsupported.Count
            staleBuildCount  = $stale.Count
            unverifiedCount  = $unverified.Count
            buildTableAsOf   = $table.TableAsOf.ToString('yyyy-MM-dd')
            buildTableAgeDays = $tableAgeDays
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = 'Success'; reason = '' } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

<#
UPG-01 - Exchange Subscription Edition readiness (roll-up).
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_UPG_01_SEReadiness {
    # $Run is part of the collector calling convention; this roll-up derives everything from
    # the findings it is handed and does not log through the run itself.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Run')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][object]$DomainFinding,
        [Parameter()][object]$OsFinding,
        [Parameter()][object]$ExchangeFinding
    )

    $control = Get-ExchControlById -ControlId 'UPG-01'

    $domainMetrics = $null; $domainEvidence=@()
    try { $domainMetrics = $DomainFinding.result.metrics; $domainEvidence = @($DomainFinding.evidence) } catch {}

    $osMetrics = $null; $osEvidence=@()
    try { $osMetrics = $OsFinding.result.metrics; $osEvidence = @($OsFinding.evidence) } catch {}

    $exchMetrics = $null; $exchEvidence=@()
    try { $exchMetrics = $ExchangeFinding.result.metrics; $exchEvidence = @($ExchangeFinding.evidence) } catch {}

    $issues = New-Object System.Collections.Generic.List[string]

    # Domain readiness
    $domainReady = $null
    try {
        $forestMode = $domainMetrics.forestMode
        $domainMode = $domainMetrics.domainMode
        $schemaVersion = $domainMetrics.schemaVersion
        if ($forestMode -and $domainMode -and $null -ne $schemaVersion) {
            $domainReady = ($forestMode -match '2016|2019|2022') -and ($domainMode -match '2016|2019|2022') -and ([int]$schemaVersion -ge 87)
            if (-not $domainReady) { $issues.Add('Raise forest/domain level to 2016+ and update Exchange schema.') | Out-Null }
        }
    } catch { }

    # OS readiness (Windows Server 2022 preferred)
    $osReady = $null
    try {
        $servers = @($osMetrics.servers)
        if ($servers.Count -gt 0) {
            $pref2022 = [version]'10.0.20348'
            $min2016 = [version]'10.0.14393'
            $unsupported = $servers | Where-Object { $_.version -and ([version]$_.version -lt $min2016) }
            $below2022 = $servers | Where-Object { $_.version -and ([version]$_.version -lt $pref2022) }
            if ($unsupported.Count -gt 0) {
                $osReady = $false
                $issues.Add('One or more Exchange servers are below Windows Server 2016.') | Out-Null
            }
            elseif ($below2022.Count -gt 0) {
                $osReady = $false
                $issues.Add('Upgrade Exchange server OS to Windows Server 2022 for SE readiness.') | Out-Null
            }
            else {
                $osReady = $true
            }
        }
    } catch { }

    # Exchange build readiness
    $exchReady = $null
    try {
        $servers = @($exchMetrics.servers)
        if ($servers.Count -gt 0) {
            $hasLegacy = $servers | Where-Object { $_.major -lt 15 }
            $has2016 = $servers | Where-Object { $_.major -eq 15 -and $_.minor -lt 2 }
            if ($hasLegacy.Count -gt 0) {
                $exchReady = $false
                $issues.Add('Upgrade legacy Exchange versions to supported builds.') | Out-Null
            }
            elseif ($has2016.Count -gt 0) {
                $exchReady = $false
                $issues.Add('Move from Exchange 2016 to Exchange 2019 CU (latest or -1).') | Out-Null
            }
            else {
                $exchReady = $true
            }
        }
    } catch { }

    $missing = @()
    if ($null -eq $domainReady) { $missing += 'Domain/forest/schema' }
    if ($null -eq $osReady) { $missing += 'OS' }
    if ($null -eq $exchReady) { $missing += 'Exchange build' }

    $outcome = 'Unknown'
    $sev = 'High'
    $suff = if ($missing.Count -gt 0) { 'SoftFail' } else { 'Pass' }
    $rat = ''

    if ($missing.Count -gt 0) {
        $outcome = 'Unknown'
        $rat = 'Missing signals: ' + ($missing -join ', ')
    }
    elseif ($issues.Count -gt 0) {
        $outcome = 'NonCompliant'
        $rat = $issues -join ' '
    }
    else {
        $outcome = 'Compliant'
        $sev = 'Medium'
        $rat = 'Domain/forest schema, OS, and Exchange versions align to SE prerequisites.'
    }

    $evidence = @()
    $evidence += $domainEvidence
    $evidence += $osEvidence
    $evidence += $exchEvidence

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence $evidence `
        -Remediation 'Ensure domain/forest functional level is 2016+, schema updated, Exchange servers on supported Exchange 2019 CU and Windows Server 2022.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{
            domainReady  = $domainReady
            osReady      = $osReady
            exchangeReady= $exchReady
            missingSignals = $missing
        } `
        -Meta @{ dataSources = @{ rollup = @{ state= if($missing.Count -gt 0){'Partial'} else {'Success'} ; reason = if($missing.Count -gt 0){'Missing prerequisite signals'} else {''} } }; evaluationStatus = 'Complete' }
}

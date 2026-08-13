<#
HYB-01 - Hybrid configuration and OAuth readiness.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_HYB_01_HybridConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'HYB-01'

    $hyb = @()
    $ioc = @()
    $errors = New-Object System.Collections.Generic.List[string]

    try { $hyb = Get-HybridConfiguration -ErrorAction Stop }
    catch { $errors.Add('Get-HybridConfiguration failed: ' + $_.Exception.Message) | Out-Null }

    try { $ioc = Get-IntraOrganizationConnector -ErrorAction Stop }
    catch { $errors.Add('Get-IntraOrganizationConnector failed: ' + $_.Exception.Message) | Out-Null }

    $orgCfg = $null
    try { $orgCfg = Get-OrganizationConfig -ErrorAction Stop }
    catch { $errors.Add('Get-OrganizationConfig failed: ' + $_.Exception.Message) | Out-Null }

    $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'hybrid/config.json' -ContentObject ([ordered]@{
        hybridConfiguration = $hyb
        intraOrgConnectors  = $ioc
        organizationConfig  = $orgCfg
        errors              = @($errors)
    })

    $hybArr = @($hyb)
    $iocArr = @($ioc)

    $hasHybrid = ($hybArr.Count -gt 0)
    $hasIOC = ($iocArr.Count -gt 0)

    $outcome = 'Unknown'
    $sev = 'Medium'
    $suff = if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }
    $rat = 'Hybrid configuration data captured.'

    if ($hasHybrid -and $hasIOC) {
        $outcome = 'Compliant'
        $sev = 'Medium'
        $rat = 'Hybrid configuration present with intra-organization connector(s).'
    }
    elseif ($hasHybrid -and -not $hasIOC) {
        $outcome = 'PartiallyCompliant'
        $sev = 'High'
        $rat = 'Hybrid configuration present but no intra-organization connector detected.'
    }
    elseif (-not $hasHybrid) {
        $outcome = 'Unknown'
        $sev = 'Medium'
        $rat = 'No hybrid configuration detected (may be on-prem only).' 
    }

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence @($evidencePath) `
        -Remediation 'If hybrid is expected, re-run HCW and validate OAuth/intra-organization connectors; otherwise mark on-prem only.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{ hybridConfigs=$hybArr.Count; intraOrgConnectors=$iocArr.Count; errors=$errors.Count } `
        -Meta @{ dataSources = @{ Exchange = @{ state= if($errors.Count -gt 0){'Partial'} else {'Success'} ; reason = if($errors.Count -gt 0){'One or more queries failed'} else {''} } }; evaluationStatus = 'Complete' }
}

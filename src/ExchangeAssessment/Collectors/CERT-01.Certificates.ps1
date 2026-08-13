<#
CERT-01 - Certificate bindings and expiry.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_CERT_01_Certificates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'CERT-01'

    $certs = @()
    try { $certs = Get-ExchangeCertificate -ErrorAction Stop }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'Get-ExchangeCertificate failed' -Data @{ error=$_.Exception.Message }
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'High' -Title $control.title -Description $control.target -Evidence @() -Remediation 'Run from EMS with rights to read Exchange certificates.' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale 'Unable to read Exchange certificates.' -Metrics @{ error=$_.Exception.Message } -Meta @{ dataSources = @{ Exchange = @{ state='Error'; reason=$_.Exception.Message } }; evaluationStatus = 'Partial' }
    }

    $certSlim = @($certs | Select-Object Thumbprint, Services, NotAfter, NotBefore, Subject, Issuer, Status, CertificateDomains, FriendlyName)
    $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'certificates/state.json' -ContentObject $certSlim

    if ($certSlim.Count -eq 0) {
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'High' -Title $control.title -Description $control.target -Evidence @($evidencePath) -Remediation 'Ensure Exchange services have valid certificates bound.' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale 'No certificates returned for Exchange services.' -Metrics @{ certCount=0 } -Meta @{ dataSources = @{ Exchange = @{ state='Success'; reason='No certificates returned' } }; evaluationStatus = 'Complete' }
    }

    $now = Get-Date
    $daysToExpiry = @($certSlim | ForEach-Object { if ($_.NotAfter) { ([datetime]$_.NotAfter - $now).TotalDays } else { $null } }) | Where-Object { $null -ne $_ }
    $minDays = if ($daysToExpiry.Count -gt 0) { [math]::Round([double]($daysToExpiry | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum),2) } else { $null }

    $outcome = 'Compliant'
    $sev = 'Low'
    $suff = 'Pass'
    $rat = 'Certificates present; no imminent expirations detected.'

    if ($null -ne $minDays -and $minDays -le 30) {
        $outcome = 'NonCompliant'
        $sev = 'High'
        $rat = 'At least one certificate expires within 30 days.'
    }
    elseif ($null -ne $minDays -and $minDays -le 90) {
        $outcome = 'PartiallyCompliant'
        $sev = 'Medium'
        $rat = 'Certificate(s) expire within 90 days.'
    }

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence @($evidencePath) `
        -Remediation 'Renew and bind Exchange certificates before expiry; remove unused/expired certs.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{ certCount=$certSlim.Count; minDaysToExpiry=$minDays } `
        -Meta @{ dataSources = @{ Exchange = @{ state='Success'; reason='' } }; evaluationStatus = 'Complete' }
}

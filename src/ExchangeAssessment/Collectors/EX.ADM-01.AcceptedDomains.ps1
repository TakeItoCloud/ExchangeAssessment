<#
EX.ADM-01 - Accepted domains inventory.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_EX_ADM_01_AcceptedDomains {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'EX.ADM-01'

    $domains = @()
    try { $domains = Get-AcceptedDomain -ErrorAction Stop }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'Get-AcceptedDomain failed' -Data @{ error=$_.Exception.Message }
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'Medium' -Title $control.title -Description $control.target -Evidence @() -Remediation 'Run from EMS with rights to read accepted domains.' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale 'Unable to enumerate accepted domains.' -Metrics @{ error=$_.Exception.Message } -Meta @{ dataSources = @{ Exchange = @{ state='Error'; reason=$_.Exception.Message } }; evaluationStatus = 'Partial' }
    }

    $domSlim = @($domains | Select-Object Name,DomainName,DomainType,Default,MatchSubDomains,AddressBookEnabled)
    $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'exchange/accepted-domains.json' -ContentObject $domSlim

    $total = $domSlim.Count
    $authoritative = @($domSlim | Where-Object { $_.DomainType -eq 'Authoritative' }).Count
    $internal = @($domSlim | Where-Object { $_.DomainType -eq 'InternalRelay' }).Count
    $external = @($domSlim | Where-Object { $_.DomainType -eq 'ExternalRelay' }).Count

    $outcome = 'Compliant'
    $sev = 'Low'
    $suff = 'Pass'
    $rat = ("Accepted domains inventoried (Total {0})." -f $total)

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence @($evidencePath) `
        -Remediation 'Review accepted domains for correctness and cleanup unused domains.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{ total=$total; authoritative=$authoritative; internalRelay=$internal; externalRelay=$external } `
        -Meta @{ dataSources = @{ Exchange = @{ state='Success'; reason='' } }; evaluationStatus = 'Complete' }
}

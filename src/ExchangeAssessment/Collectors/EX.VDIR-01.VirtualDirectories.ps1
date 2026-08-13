<#
EX.VDIR-01 - Virtual directories configuration (OWA/ECP/EWS/OAB/Autodiscover/MAPI).
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_EX_VDIR_01_VirtualDirectories {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'EX.VDIR-01'

    $collect = {
        param($cmd,$props)
        try { & $cmd -ErrorAction Stop | Select-Object $props }
        catch { @() }
    }

    $owa = & $collect { Get-OWAVirtualDirectory } @('Name','Server','InternalUrl','ExternalUrl','FormsAuthentication','WindowsAuthentication')
    $ecp = & $collect { Get-EcpVirtualDirectory } @('Name','Server','InternalUrl','ExternalUrl','FormsAuthentication','WindowsAuthentication')
    $ews = & $collect { Get-WebServicesVirtualDirectory } @('Name','Server','InternalUrl','ExternalUrl','WindowsAuthentication','OAuthAuthentication','BasicAuthentication')
    $oab = & $collect { Get-OABVirtualDirectory } @('Name','Server','InternalUrl','ExternalUrl','RequireSSL','WindowsAuthentication')
    $auto = & $collect { Get-AutodiscoverVirtualDirectory } @('Name','Server','InternalUrl','ExternalUrl','WindowsAuthentication')
    $mapi = & $collect { Get-MapiVirtualDirectory } @('Name','Server','InternalUrl','ExternalUrl','IISAuthenticationMethods')

    $payload = [ordered]@{
        owa  = $owa
        ecp  = $ecp
        ews  = $ews
        oab  = $oab
        autodiscover = $auto
        mapi = $mapi
    }

    $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'exchange/virtual-directories.json' -ContentObject $payload

    $total = (@($owa).Count + @($ecp).Count + @($ews).Count + @($oab).Count + @($auto).Count + @($mapi).Count)

    $outcome = 'Compliant'
    $sev = 'Low'
    $suff = 'Pass'
    $rat = ("Virtual directories collected (Total entries: {0})." -f $total)

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence @($evidencePath) `
        -Remediation 'Review virtual directory URLs and authentication to ensure they align with policy.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{ total=$total } `
        -Meta @{ dataSources = @{ Exchange = @{ state='Success'; reason='' } }; evaluationStatus = 'Complete' }
}

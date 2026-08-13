<#
TR.CO-01 - Transport connectors (send/receive).
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_TR_CO_01_TransportConnectors {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'TR.CO-01'

    $send = @()
    $receive = @()
    $sendErr = $null; $recvErr = $null

    try { $send = Get-SendConnector -ErrorAction Stop }
    catch { $sendErr = $_.Exception.Message; Write-ExchEvent -Run $Run -Level WARN -Message 'Get-SendConnector failed' -Data @{ error=$sendErr } }

    try { $receive = Get-ReceiveConnector -ErrorAction Stop }
    catch { $recvErr = $_.Exception.Message; Write-ExchEvent -Run $Run -Level WARN -Message 'Get-ReceiveConnector failed' -Data @{ error=$recvErr } }

    if ($sendErr -and $recvErr) {
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'High' -Title $control.title -Description $control.target -Evidence @() -Remediation 'Run from EMS with rights to enumerate transport connectors.' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale 'Unable to read send/receive connectors.' -Metrics @{ sendError=$sendErr; receiveError=$recvErr } -Meta @{ dataSources = @{ Exchange = @{ state='Error'; reason='Connector queries failed' } }; evaluationStatus = 'Partial' }
    }

    $sendSlim = @($send | Select-Object Name, AddressSpaces, DNSRoutingEnabled, TLSAuthLevel, SourceTransportServers, MaxMessageSize)
    $recvSlim = @($receive | Select-Object Name, PermissionGroups, AuthMechanism, RemoteIPRanges, Bindings, Fqdn, RequireEHLODomain, MaxMessageSize)

    $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'transport/connectors.json' -ContentObject ([ordered]@{ send=$sendSlim; receive=$recvSlim; sendError=$sendErr; receiveError=$recvErr })

    $openRelay = @()
    foreach ($rc in @($receive)) {
        $perm = @($rc.PermissionGroups)
        $ips = @($rc.RemoteIPRanges)
        $hasAnon = $perm -contains 'AnonymousUsers'
        $openAll = $false
        foreach ($ip in $ips) { if ($ip -and ($ip.ToString() -eq '0.0.0.0-255.255.255.255')) { $openAll = $true } }
        if ($hasAnon -and $openAll) { $openRelay += $rc }
    }

    $outcome = 'PartiallyCompliant'
    $sev = 'Medium'
    $suff = 'Pass'
    $rat = 'Connector configuration captured; review for mail hygiene and relay controls.'

    if ($openRelay.Count -gt 0) {
        $outcome = 'NonCompliant'
        $sev = 'High'
        $rat = 'Anonymous receive connector allows 0.0.0.0/0 (potential open relay).' 
    }
    elseif ($sendSlim.Count -eq 0 -and $recvSlim.Count -eq 0) {
        $outcome = 'Unknown'
        $sev = 'High'
        $suff = 'SoftFail'
        $rat = 'No connectors returned from Exchange.'
    }

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence @($evidencePath) `
        -Remediation 'Restrict anonymous receive connectors to scoped IP ranges; validate send connector auth/TLS and limits.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{ sendCount=$sendSlim.Count; receiveCount=$recvSlim.Count; openRelay=$openRelay.Count } `
        -Meta @{ dataSources = @{ Exchange = @{ state='Success'; reason='' } }; evaluationStatus = 'Complete' }
}

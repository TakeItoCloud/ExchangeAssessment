<#
CLD.CONN-01 - Exchange Online mail flow connectors.

An inbound connector that accepts mail from a wide address range without requiring TLS or a
matching certificate is how a tenant ends up relaying someone else's mail, so it is the main
thing this control looks for.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_CLD_CONN_01_TenantConnector {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'CLD.CONN-01'

    $state = Get-ExchCloudState -Run $Run
    if ($null -eq $state -or -not $state.Connected) {
        return New-ExchCollectorResult -Findings @(New-ExchCloudUnavailableFinding -Control $control -Run $Run)
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $inbound  = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-InboundConnector'  -Errors $errors -ControlId $control.controlId)
    $outbound = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-OutboundConnector' -Errors $errors -ControlId $control.controlId)
    $rules    = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-TransportRule'     -Errors $errors -ControlId $control.controlId)

    $inboundRows = foreach ($c in $inbound) {
        $senderIps = @(Get-ExchCloudProperty -Object $c -Name 'SenderIPAddresses')
        [pscustomobject]@{
            Name                     = [string]$c.Name
            Enabled                  = (ConvertTo-ExchFlatValue -Value $c.Enabled)
            ConnectorType            = [string](Get-ExchCloudProperty -Object $c -Name 'ConnectorType')
            ConnectorSource          = [string](Get-ExchCloudProperty -Object $c -Name 'ConnectorSource')
            SenderDomains            = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $c -Name 'SenderDomains'))
            SenderIPAddresses        = (ConvertTo-ExchFlatValue -Value $senderIps)
            RequireTls               = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $c -Name 'RequireTls'))
            RestrictDomainsToIPAddresses = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $c -Name 'RestrictDomainsToIPAddresses'))
            RestrictDomainsToCertificate = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $c -Name 'RestrictDomainsToCertificate'))
            TlsSenderCertificateName = [string](Get-ExchCloudProperty -Object $c -Name 'TlsSenderCertificateName')
            CloudServicesMailEnabled = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $c -Name 'CloudServicesMailEnabled'))
            UnrestrictedSenders      = (Test-ExchUnrestrictedRange -Ranges @($senderIps | ForEach-Object { [string]$_ }) -KnownUnrestricted @())
        }
    }

    $outboundRows = foreach ($c in $outbound) {
        [pscustomobject]@{
            Name                 = [string]$c.Name
            Enabled              = (ConvertTo-ExchFlatValue -Value $c.Enabled)
            ConnectorType        = [string](Get-ExchCloudProperty -Object $c -Name 'ConnectorType')
            RecipientDomains     = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $c -Name 'RecipientDomains'))
            SmartHosts           = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $c -Name 'SmartHosts'))
            TlsSettings          = [string](Get-ExchCloudProperty -Object $c -Name 'TlsSettings')
            TlsDomain            = [string](Get-ExchCloudProperty -Object $c -Name 'TlsDomain')
            UseMXRecord          = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $c -Name 'UseMXRecord'))
            IsValidated          = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $c -Name 'IsValidated'))
            IsTransportRuleScoped= (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $c -Name 'IsTransportRuleScoped'))
        }
    }

    $ruleRows = foreach ($r in $rules) {
        [pscustomobject]@{
            Name        = [string]$r.Name
            State       = [string]$r.State
            Mode        = [string](Get-ExchCloudProperty -Object $r -Name 'Mode')
            Priority    = [string](Get-ExchCloudProperty -Object $r -Name 'Priority')
            Description = (Get-ExchTruncatedText -Text ([string](Get-ExchCloudProperty -Object $r -Name 'Description')) -Length 400)
        }
    }

    $inboundArr  = @($inboundRows)
    $outboundArr = @($outboundRows)
    $ruleArr     = @($ruleRows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'cloud/connectors.json' -ContentObject ([ordered]@{
        inboundConnectors  = $inboundArr
        outboundConnectors = $outboundArr
        transportRules     = $ruleArr
        errors             = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'cloud.inbound-connectors' -Title 'Exchange Online Inbound Connectors' -Area 'Cloud' `
            -Columns @('Name', 'Enabled', 'ConnectorType', 'ConnectorSource', 'SenderDomains', 'SenderIPAddresses', 'RequireTls', 'RestrictDomainsToIPAddresses', 'RestrictDomainsToCertificate', 'TlsSenderCertificateName', 'CloudServicesMailEnabled', 'UnrestrictedSenders') `
            -Rows $inboundArr

        New-ExchInventorySection -Run $Run -Key 'cloud.outbound-connectors' -Title 'Exchange Online Outbound Connectors' -Area 'Cloud' `
            -Columns @('Name', 'Enabled', 'ConnectorType', 'RecipientDomains', 'SmartHosts', 'TlsSettings', 'TlsDomain', 'UseMXRecord', 'IsValidated', 'IsTransportRuleScoped') `
            -Rows $outboundArr

        New-ExchInventorySection -Run $Run -Key 'cloud.transport-rules' -Title 'Exchange Online Transport Rules' -Area 'Cloud' `
            -Columns @('Name', 'State', 'Mode', 'Priority', 'Description') -Rows $ruleArr -HighCardinality
    )

    $requireTls = [bool](Get-ExchThreshold -Run $Run -Name 'Cloud.RequireConnectorTls' -Default $true)

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    $openInbound = @($inboundArr | Where-Object {
        $_.Enabled -eq $true -and $_.UnrestrictedSenders -eq $true -and
        $_.RestrictDomainsToCertificate -ne $true -and $_.RequireTls -ne $true
    })
    if ($openInbound.Count -gt 0) {
        $problems.Add(("{0} enabled inbound connectors accept mail from any address without requiring TLS or a matching certificate: {1}" -f `
            $openInbound.Count, (($openInbound | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    if ($requireTls) {
        $noTlsInbound = @($inboundArr | Where-Object { $_.Enabled -eq $true -and $_.RequireTls -ne $true -and $_.UnrestrictedSenders -ne $true })
        if ($noTlsInbound.Count -gt 0) {
            $problems.Add(("{0} enabled inbound connectors do not require TLS: {1}" -f $noTlsInbound.Count, `
                (($noTlsInbound | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }

        $noTlsOutbound = @($outboundArr | Where-Object { $_.Enabled -eq $true -and [string]$_.TlsSettings -notmatch 'Encryption|Validation|DomainValidation' })
        if ($noTlsOutbound.Count -gt 0) {
            $problems.Add(("{0} enabled outbound connectors do not enforce TLS (TlsSettings is {1}): {2}" -f $noTlsOutbound.Count, `
                (($noTlsOutbound | ForEach-Object { if ($_.TlsSettings) { $_.TlsSettings } else { 'unset' } } | Sort-Object -Unique) -join '/'), `
                (($noTlsOutbound | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }
    }

    $unvalidated = @($outboundArr | Where-Object { $_.Enabled -eq $true -and $_.IsValidated -eq $false })
    if ($unvalidated.Count -gt 0) {
        $problems.Add(("{0} enabled outbound connectors have never validated, so mail routed through them may be failing: {1}" -f `
            $unvalidated.Count, (($unvalidated | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($errors.Count -gt 0) {
        $problems.Add(("Some connector configuration could not be read: {0}" -f ($errors -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
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
                 else { ("{0} inbound and {1} outbound connectors are scoped and enforce TLS, and {2} transport rules are in place." -f `
                        $inboundArr.Count, $outboundArr.Count, $ruleArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Scope every inbound connector to the specific sender IP addresses or certificate subject it should accept, require TLS on both directions, and validate outbound connectors after any change.' `
        -Metrics @{
            inboundConnectors  = $inboundArr.Count
            outboundConnectors = $outboundArr.Count
            transportRules     = $ruleArr.Count
            openInbound        = $openInbound.Count
        } `
        -Meta @{ dataSources = @{ ExchangeOnline = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

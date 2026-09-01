<#
HYB-01 - Hybrid configuration and OAuth.

A purely on-premises organisation is a valid design, so the absence of hybrid is reported as a
fact rather than scored as a failure. Where hybrid is deployed, the pieces that actually carry
free/busy and cross-premises mail flow are checked: intra-organization connectors, the OAuth
authorization server, the partner application, federation trust and organization relationships.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_HYB_01_HybridConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'HYB-01'

    $errors = New-Object System.Collections.Generic.List[string]

    $hybrid       = @(Invoke-ExchQuery -Label 'Get-HybridConfiguration'       -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-HybridConfiguration -ErrorAction Stop })
    $intraOrg     = @(Invoke-ExchQuery -Label 'Get-IntraOrganizationConnector' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-IntraOrganizationConnector -ErrorAction Stop })
    $orgConfig    = @(Invoke-ExchQuery -Label 'Get-OrganizationConfig'        -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-OrganizationConfig -ErrorAction Stop })
    $authServers  = @(Invoke-ExchQuery -Label 'Get-AuthServer'                -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-AuthServer -ErrorAction Stop })
    $partnerApps  = @(Invoke-ExchQuery -Label 'Get-PartnerApplication'        -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-PartnerApplication -ErrorAction Stop })
    $federation   = @(Invoke-ExchQuery -Label 'Get-FederationTrust'           -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-FederationTrust -ErrorAction Stop })
    $orgRelations = @(Invoke-ExchQuery -Label 'Get-OrganizationRelationship'  -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-OrganizationRelationship -ErrorAction Stop })
    $migration    = @(Invoke-ExchQuery -Label 'Get-MigrationEndpoint'         -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-MigrationEndpoint -ErrorAction Stop })

    $hybridRows = foreach ($h in $hybrid) {
        [pscustomobject]@{
            Name              = [string]$h.Name
            Domains           = (ConvertTo-ExchFlatValue -Value $h.Domains)
            Features          = (ConvertTo-ExchFlatValue -Value $h.Features)
            ExternalIPAddresses = (ConvertTo-ExchFlatValue -Value $h.ExternalIPAddresses)
            OnPremisesSmartHost = [string]$h.OnPremisesSmartHost
            ReceivingTransportServers = (ConvertTo-ExchFlatValue -Value $h.ReceivingTransportServers)
            SendingTransportServers   = (ConvertTo-ExchFlatValue -Value $h.SendingTransportServers)
            TlsCertificateName        = [string]$h.TlsCertificateName
            ServiceInstance   = [string]$h.ServiceInstance
        }
    }

    $connectorRows = foreach ($c in $intraOrg) {
        [pscustomobject]@{
            Name           = [string]$c.Name
            Enabled        = [bool]$c.Enabled
            TargetAddressDomains = (ConvertTo-ExchFlatValue -Value $c.TargetAddressDomains)
            DiscoveryEndpoint    = [string]$c.DiscoveryEndpoint
            TargetSharingEpr     = [string]$c.TargetSharingEpr
        }
    }

    $oauthRows = New-Object System.Collections.Generic.List[object]
    foreach ($s in $authServers) {
        $oauthRows.Add([pscustomobject]@{
            Kind     = 'AuthServer'
            Name     = [string]$s.Name
            Enabled  = [bool]$s.Enabled
            Detail   = ("Type={0}; IssuerIdentifier={1}" -f [string]$s.Type, [string]$s.IssuerIdentifier)
        }) | Out-Null
    }
    foreach ($p in $partnerApps) {
        $oauthRows.Add([pscustomobject]@{
            Kind     = 'PartnerApplication'
            Name     = [string]$p.Name
            Enabled  = [bool]$p.Enabled
            Detail   = ("ApplicationIdentifier={0}; AcceptSecurityIdentifierInformation={1}" -f [string]$p.ApplicationIdentifier, [string]$p.AcceptSecurityIdentifierInformation)
        }) | Out-Null
    }
    foreach ($f in $federation) {
        $oauthRows.Add([pscustomobject]@{
            Kind     = 'FederationTrust'
            Name     = [string]$f.Name
            Enabled  = $true
            Detail   = ("TokenIssuerUri={0}; OrgCertificateExpiry={1}" -f [string]$f.TokenIssuerUri, (ConvertTo-ExchFlatValue -Value $f.OrgCertificateNotAfter))
        }) | Out-Null
    }

    $relationshipRows = foreach ($r in $orgRelations) {
        [pscustomobject]@{
            Name             = [string]$r.Name
            Enabled          = [bool]$r.Enabled
            DomainNames      = (ConvertTo-ExchFlatValue -Value $r.DomainNames)
            FreeBusyAccessEnabled = [bool]$r.FreeBusyAccessEnabled
            FreeBusyAccessLevel   = [string]$r.FreeBusyAccessLevel
            MailboxMoveEnabled    = [bool]$r.MailboxMoveEnabled
            TargetAutodiscoverEpr = [string]$r.TargetAutodiscoverEpr
        }
    }

    $migrationRows = foreach ($m in $migration) {
        [pscustomobject]@{
            Identity      = [string]$m.Identity
            EndpointType  = [string]$m.EndpointType
            RemoteServer  = [string]$m.RemoteServer
            MaxConcurrentMigrations = [string]$m.MaxConcurrentMigrations
        }
    }

    $hybridArr       = @($hybridRows)
    $connectorArr    = @($connectorRows)
    $oauthArr        = @($oauthRows.ToArray())
    $relationshipArr = @($relationshipRows)
    $migrationArr    = @($migrationRows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'hybrid/config.json' -ContentObject ([ordered]@{
        hybridConfiguration    = $hybridArr
        intraOrgConnectors     = $connectorArr
        oauth                  = $oauthArr
        organizationRelationships = $relationshipArr
        migrationEndpoints     = $migrationArr
        organizationConfig     = ($orgConfig | Select-Object -First 1)
        errors                 = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'hybrid.configuration' -Title 'Hybrid Configuration' -Area 'Hybrid' `
            -Columns @('Name', 'Domains', 'Features', 'ExternalIPAddresses', 'OnPremisesSmartHost', 'ReceivingTransportServers', 'SendingTransportServers', 'TlsCertificateName', 'ServiceInstance') -Rows $hybridArr

        New-ExchInventorySection -Run $Run -Key 'hybrid.intra-org-connectors' -Title 'Intra-Organization Connectors' -Area 'Hybrid' `
            -Columns @('Name', 'Enabled', 'TargetAddressDomains', 'DiscoveryEndpoint', 'TargetSharingEpr') -Rows $connectorArr

        New-ExchInventorySection -Run $Run -Key 'hybrid.oauth' -Title 'OAuth and Federation' -Area 'Hybrid' `
            -Columns @('Kind', 'Name', 'Enabled', 'Detail') -Rows $oauthArr

        New-ExchInventorySection -Run $Run -Key 'hybrid.organization-relationships' -Title 'Organization Relationships' -Area 'Hybrid' `
            -Columns @('Name', 'Enabled', 'DomainNames', 'FreeBusyAccessEnabled', 'FreeBusyAccessLevel', 'MailboxMoveEnabled', 'TargetAutodiscoverEpr') -Rows $relationshipArr

        New-ExchInventorySection -Run $Run -Key 'hybrid.migration-endpoints' -Title 'Migration Endpoints' -Area 'Hybrid' `
            -Columns @('Identity', 'EndpointType', 'RemoteServer', 'MaxConcurrentMigrations') -Rows $migrationArr
    )

    if ($hybridArr.Count -eq 0) {
        $rationale = 'No hybrid configuration exists, so this organisation is not in a hybrid deployment with Exchange Online.'
        if ($errors.Count -gt 0) { $rationale += (" Some hybrid cmdlets could not be read: {0}." -f ($errors -join '; ')) }

        $finding = New-ExchControlFinding -Control $control -Severity 'Info' `
            -Outcome $(if ($errors.Count -gt 0) { 'Unknown' } else { 'Compliant' }) `
            -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
            -Rationale $rationale `
            -Evidence @($evidence) `
            -Remediation 'No action required for a purely on-premises organisation. If hybrid with Exchange Online is intended, run the Hybrid Configuration Wizard.' `
            -Metrics @{ hybridConfigured = $false } `
            -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

        return New-ExchCollectorResult -Sections $sections -Findings @($finding)
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    $enabledConnectors = @($connectorArr | Where-Object { $_.Enabled })
    if ($enabledConnectors.Count -eq 0) {
        $problems.Add('Hybrid is configured but no intra-organization connector is enabled, so cross-premises free/busy and mail flow will not work') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    $enabledAuthServers = @($oauthArr | Where-Object { $_.Kind -eq 'AuthServer' -and $_.Enabled })
    if ($enabledAuthServers.Count -eq 0) {
        $problems.Add('No enabled OAuth authorization server is configured, so OAuth-based hybrid features will fall back or fail') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    $enabledPartnerApps = @($oauthArr | Where-Object { $_.Kind -eq 'PartnerApplication' -and $_.Enabled })
    if ($enabledPartnerApps.Count -eq 0) {
        $problems.Add('No enabled partner application is configured for OAuth between on-premises Exchange and Exchange Online') | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $freeBusy = @($relationshipArr | Where-Object { $_.Enabled -and $_.FreeBusyAccessEnabled })
    if ($freeBusy.Count -eq 0) {
        $problems.Add('No enabled organization relationship grants free/busy access, so cross-premises availability lookups will fail') | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($errors.Count -gt 0) {
        $problems.Add(("Some hybrid configuration could not be read: {0}" -f ($errors -join '; '))) | Out-Null
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
                 else { ("Hybrid is configured with {0} enabled intra-organization connectors, an enabled OAuth authorization server and {1} free/busy organization relationships." -f $enabledConnectors.Count, $freeBusy.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Re-run the Hybrid Configuration Wizard to restore intra-organization connectors, OAuth and organization relationships, then verify free/busy in both directions.' `
        -Metrics @{
            hybridConfigured   = $true
            intraOrgConnectors = $connectorArr.Count
            authServers        = @($oauthArr | Where-Object { $_.Kind -eq 'AuthServer' }).Count
            partnerApplications= @($oauthArr | Where-Object { $_.Kind -eq 'PartnerApplication' }).Count
            organizationRelationships = $relationshipArr.Count
            migrationEndpoints = $migrationArr.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

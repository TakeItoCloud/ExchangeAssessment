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

    # Every property read below is guarded. The first live run lost this whole control to one
    # property the intra-organization connector did not return (TargetSharingEpr) under strict
    # mode, and every read after it had never met a real object. Inventory-only fields become a
    # blank cell when absent; the fields a verdict is reached from are listed in
    # UnreadableFields and turn that verdict to Unknown.
    $hybridRows = foreach ($h in $hybrid) {
        [pscustomobject]@{
            Name              = [string](Get-ExchObjectValue -InputObject $h -Name 'Name' -Default '')
            Domains           = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $h -Name 'Domains'))
            Features          = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $h -Name 'Features'))
            ExternalIPAddresses = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $h -Name 'ExternalIPAddresses'))
            OnPremisesSmartHost = [string](Get-ExchObjectValue -InputObject $h -Name 'OnPremisesSmartHost' -Default '')
            ReceivingTransportServers = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $h -Name 'ReceivingTransportServers'))
            SendingTransportServers   = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $h -Name 'SendingTransportServers'))
            TlsCertificateName        = [string](Get-ExchObjectValue -InputObject $h -Name 'TlsCertificateName' -Default '')
            ServiceInstance   = [string](Get-ExchObjectValue -InputObject $h -Name 'ServiceInstance' -Default '')
        }
    }

    $connectorRows = foreach ($c in $intraOrg) {
        [pscustomobject]@{
            Name           = [string](Get-ExchObjectValue -InputObject $c -Name 'Name' -Default '')
            Enabled        = (Get-ExchObjectBool -InputObject $c -Name 'Enabled')
            TargetAddressDomains = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $c -Name 'TargetAddressDomains'))
            DiscoveryEndpoint    = [string](Get-ExchObjectValue -InputObject $c -Name 'DiscoveryEndpoint' -Default '')
            TargetSharingEpr     = [string](Get-ExchObjectValue -InputObject $c -Name 'TargetSharingEpr' -Default '')
            UnreadableFields     = (Get-ExchMissingProperty -InputObject $c -Name @('Enabled'))
        }
    }

    $oauthRows = New-Object System.Collections.Generic.List[object]
    foreach ($s in $authServers) {
        $oauthRows.Add([pscustomobject]@{
            Kind     = 'AuthServer'
            Name     = [string](Get-ExchObjectValue -InputObject $s -Name 'Name' -Default '')
            Enabled  = (Get-ExchObjectBool -InputObject $s -Name 'Enabled')
            Detail   = ("Type={0}; IssuerIdentifier={1}" -f [string](Get-ExchObjectValue -InputObject $s -Name 'Type' -Default ''), [string](Get-ExchObjectValue -InputObject $s -Name 'IssuerIdentifier' -Default ''))
            UnreadableFields = (Get-ExchMissingProperty -InputObject $s -Name @('Enabled'))
        }) | Out-Null
    }
    foreach ($p in $partnerApps) {
        $oauthRows.Add([pscustomobject]@{
            Kind     = 'PartnerApplication'
            Name     = [string](Get-ExchObjectValue -InputObject $p -Name 'Name' -Default '')
            Enabled  = (Get-ExchObjectBool -InputObject $p -Name 'Enabled')
            Detail   = ("ApplicationIdentifier={0}; AcceptSecurityIdentifierInformation={1}" -f [string](Get-ExchObjectValue -InputObject $p -Name 'ApplicationIdentifier' -Default ''), [string](Get-ExchObjectValue -InputObject $p -Name 'AcceptSecurityIdentifierInformation' -Default ''))
            UnreadableFields = (Get-ExchMissingProperty -InputObject $p -Name @('Enabled'))
        }) | Out-Null
    }
    foreach ($f in $federation) {
        $oauthRows.Add([pscustomobject]@{
            Kind     = 'FederationTrust'
            Name     = [string](Get-ExchObjectValue -InputObject $f -Name 'Name' -Default '')
            Enabled  = $true
            Detail   = ("TokenIssuerUri={0}; OrgCertificateExpiry={1}" -f [string](Get-ExchObjectValue -InputObject $f -Name 'TokenIssuerUri' -Default ''), (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $f -Name 'OrgCertificateNotAfter')))
            UnreadableFields = ''
        }) | Out-Null
    }

    $relationshipRows = foreach ($r in $orgRelations) {
        [pscustomobject]@{
            Name             = [string](Get-ExchObjectValue -InputObject $r -Name 'Name' -Default '')
            Enabled          = (Get-ExchObjectBool -InputObject $r -Name 'Enabled')
            DomainNames      = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $r -Name 'DomainNames'))
            FreeBusyAccessEnabled = (Get-ExchObjectBool -InputObject $r -Name 'FreeBusyAccessEnabled')
            FreeBusyAccessLevel   = [string](Get-ExchObjectValue -InputObject $r -Name 'FreeBusyAccessLevel' -Default '')
            MailboxMoveEnabled    = (Get-ExchObjectBool -InputObject $r -Name 'MailboxMoveEnabled')
            TargetAutodiscoverEpr = [string](Get-ExchObjectValue -InputObject $r -Name 'TargetAutodiscoverEpr' -Default '')
            UnreadableFields      = (Get-ExchMissingProperty -InputObject $r -Name @('Enabled', 'FreeBusyAccessEnabled'))
        }
    }

    $migrationRows = foreach ($m in $migration) {
        [pscustomobject]@{
            Identity      = [string](Get-ExchObjectValue -InputObject $m -Name 'Identity' -Default '')
            EndpointType  = [string](Get-ExchObjectValue -InputObject $m -Name 'EndpointType' -Default '')
            RemoteServer  = [string](Get-ExchObjectValue -InputObject $m -Name 'RemoteServer' -Default '')
            MaxConcurrentMigrations = [string](Get-ExchObjectValue -InputObject $m -Name 'MaxConcurrentMigrations' -Default '')
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
            -Columns @('Name', 'Enabled', 'TargetAddressDomains', 'DiscoveryEndpoint', 'TargetSharingEpr', 'UnreadableFields') -Rows $connectorArr

        New-ExchInventorySection -Run $Run -Key 'hybrid.oauth' -Title 'OAuth and Federation' -Area 'Hybrid' `
            -Columns @('Kind', 'Name', 'Enabled', 'Detail', 'UnreadableFields') -Rows $oauthArr

        New-ExchInventorySection -Run $Run -Key 'hybrid.organization-relationships' -Title 'Organization Relationships' -Area 'Hybrid' `
            -Columns @('Name', 'Enabled', 'DomainNames', 'FreeBusyAccessEnabled', 'FreeBusyAccessLevel', 'MailboxMoveEnabled', 'TargetAutodiscoverEpr', 'UnreadableFields') -Rows $relationshipArr

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

    # A check whose population holds an unreadable row cannot conclude "none enabled": the
    # unread row may be the enabled one. Such a check is Unknown, naming the rows.
    $enabledConnectors = @($connectorArr | Where-Object { $_.Enabled -eq $true })
    $unreadConnectors  = @($connectorArr | Where-Object { $_.UnreadableFields })
    if ($enabledConnectors.Count -eq 0 -and $unreadConnectors.Count -gt 0) {
        $problems.Add(("No intra-organization connector was read as enabled, and {0} could not be judged because Enabled was not returned: {1}" -f $unreadConnectors.Count, (($unreadConnectors | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif ($enabledConnectors.Count -eq 0) {
        $problems.Add('Hybrid is configured but no intra-organization connector is enabled, so cross-premises free/busy and mail flow will not work') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    $enabledAuthServers = @($oauthArr | Where-Object { $_.Kind -eq 'AuthServer' -and $_.Enabled -eq $true })
    $unreadAuthServers  = @($oauthArr | Where-Object { $_.Kind -eq 'AuthServer' -and $_.UnreadableFields })
    if ($enabledAuthServers.Count -eq 0 -and $unreadAuthServers.Count -gt 0) {
        $problems.Add(("No OAuth authorization server was read as enabled, and {0} could not be judged because Enabled was not returned: {1}" -f $unreadAuthServers.Count, (($unreadAuthServers | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif ($enabledAuthServers.Count -eq 0) {
        $problems.Add('No enabled OAuth authorization server is configured, so OAuth-based hybrid features will fall back or fail') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    $enabledPartnerApps = @($oauthArr | Where-Object { $_.Kind -eq 'PartnerApplication' -and $_.Enabled -eq $true })
    $unreadPartnerApps  = @($oauthArr | Where-Object { $_.Kind -eq 'PartnerApplication' -and $_.UnreadableFields })
    if ($enabledPartnerApps.Count -eq 0 -and $unreadPartnerApps.Count -gt 0) {
        $problems.Add(("No partner application was read as enabled, and {0} could not be judged because Enabled was not returned: {1}" -f $unreadPartnerApps.Count, (($unreadPartnerApps | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif ($enabledPartnerApps.Count -eq 0) {
        $problems.Add('No enabled partner application is configured for OAuth between on-premises Exchange and Exchange Online') | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $freeBusy = @($relationshipArr | Where-Object { $_.Enabled -eq $true -and $_.FreeBusyAccessEnabled -eq $true })
    $unreadRelationships = @($relationshipArr | Where-Object { $_.UnreadableFields })
    if ($freeBusy.Count -eq 0 -and $unreadRelationships.Count -gt 0) {
        $problems.Add(("No organization relationship was read as granting free/busy, and {0} could not be judged because {1} was not returned" -f $unreadRelationships.Count, ((@($unreadRelationships | ForEach-Object { $_.UnreadableFields }) | Select-Object -Unique) -join ';'))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif ($freeBusy.Count -eq 0) {
        $problems.Add('No enabled organization relationship grants free/busy access, so cross-premises availability lookups will fail') | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($errors.Count -gt 0) {
        $problems.Add(("Some hybrid configuration could not be read: {0}" -f ($errors -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $incomplete = ($errors.Count -gt 0) -or ($outcomes -contains 'Unknown')

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
        -Sufficiency $(if ($incomplete) { 'SoftFail' } else { 'Pass' }) `
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
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($incomplete) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

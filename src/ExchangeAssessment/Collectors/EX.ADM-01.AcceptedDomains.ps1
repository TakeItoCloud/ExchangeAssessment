<#
EX.ADM-01 - Accepted and remote domain configuration.

Inventory plus the checks that matter: an external relay domain that nobody meant to create is
a spam path, a missing default domain breaks address generation, and remote domain settings
control what the organisation leaks to the outside world.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_EX_ADM_01_AcceptedDomains {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'EX.ADM-01'

    $errors = New-Object System.Collections.Generic.List[string]

    $accepted = @(Invoke-ExchQuery -Label 'Get-AcceptedDomain'      -Errors $errors -Script { Get-AcceptedDomain -ErrorAction Stop })
    $remote   = @(Invoke-ExchQuery -Label 'Get-RemoteDomain'        -Errors $errors -Script { Get-RemoteDomain -ErrorAction Stop })
    $policies = @(Invoke-ExchQuery -Label 'Get-EmailAddressPolicy'  -Errors $errors -Script { Get-EmailAddressPolicy -ErrorAction Stop })

    if ($accepted.Count -eq 0 -and @($errors | Where-Object { $_ -like 'Get-AcceptedDomain*' }).Count -gt 0) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control `
                -Reason ("Accepted domains could not be read: {0}" -f (($errors | Where-Object { $_ -like 'Get-AcceptedDomain*' }) -join '; ')) `
                -Remediation 'Run from an Exchange Management Shell with rights to read accepted domains.'
        )
    }

    $acceptedRows = foreach ($d in $accepted) {
        [pscustomobject]@{
            Name              = [string]$d.Name
            DomainName        = [string]$d.DomainName
            DomainType        = [string]$d.DomainType
            Default           = [bool]$d.Default
            MatchSubDomains   = [bool]$d.MatchSubDomains
            AddressBookEnabled= [bool]$d.AddressBookEnabled
        }
    }
    $acceptedArr = @($acceptedRows)

    $remoteRows = foreach ($r in $remote) {
        [pscustomobject]@{
            Name                       = [string]$r.Name
            DomainName                 = [string]$r.DomainName
            AllowedOOFType             = [string]$r.AllowedOOFType
            AutoForwardEnabled         = [bool]$r.AutoForwardEnabled
            AutoReplyEnabled           = [bool]$r.AutoReplyEnabled
            DeliveryReportEnabled      = [bool]$r.DeliveryReportEnabled
            NDREnabled                 = [bool]$r.NDREnabled
            MeetingForwardNotificationEnabled = [bool]$r.MeetingForwardNotificationEnabled
            TNEFEnabled                = (ConvertTo-ExchFlatValue -Value $r.TNEFEnabled)
        }
    }
    $remoteArr = @($remoteRows)

    $policyRows = foreach ($p in $policies) {
        [pscustomobject]@{
            Name                 = [string]$p.Name
            Priority             = [string]$p.Priority
            RecipientFilter      = [string]$p.RecipientFilter
            EnabledEmailAddressTemplates = (ConvertTo-ExchFlatValue -Value $p.EnabledEmailAddressTemplates)
            LastUpdatedRecipientFilter   = [string]$p.LastUpdatedRecipientFilter
        }
    }
    $policyArr = @($policyRows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'exchange/accepted-domains.json' -ContentObject ([ordered]@{
        acceptedDomains     = $acceptedArr
        remoteDomains       = $remoteArr
        emailAddressPolicies= $policyArr
        errors              = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'exchange.accepted-domains' -Title 'Accepted Domains' -Area 'Exchange' `
            -Columns @('Name', 'DomainName', 'DomainType', 'Default', 'MatchSubDomains', 'AddressBookEnabled') -Rows $acceptedArr

        New-ExchInventorySection -Run $Run -Key 'exchange.remote-domains' -Title 'Remote Domains' -Area 'Exchange' `
            -Columns @('Name', 'DomainName', 'AllowedOOFType', 'AutoForwardEnabled', 'AutoReplyEnabled', 'DeliveryReportEnabled', 'NDREnabled', 'MeetingForwardNotificationEnabled', 'TNEFEnabled') -Rows $remoteArr

        New-ExchInventorySection -Run $Run -Key 'exchange.email-address-policies' -Title 'Email Address Policies' -Area 'Exchange' `
            -Columns @('Name', 'Priority', 'RecipientFilter', 'EnabledEmailAddressTemplates', 'LastUpdatedRecipientFilter') -Rows $policyArr
    )

    $authoritative = @($acceptedArr | Where-Object { $_.DomainType -eq 'Authoritative' })
    $internalRelay = @($acceptedArr | Where-Object { $_.DomainType -eq 'InternalRelay' })
    $externalRelay = @($acceptedArr | Where-Object { $_.DomainType -eq 'ExternalRelay' })
    $wildcard      = @($acceptedArr | Where-Object { $_.DomainName -eq '*' })
    $defaults      = @($acceptedArr | Where-Object { $_.Default })
    $autoForward   = @($remoteArr | Where-Object { $_.DomainName -eq '*' -and $_.AutoForwardEnabled })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($wildcard.Count -gt 0) {
        $problems.Add(("A wildcard accepted domain (*) is configured as {0}, which makes the organisation accept mail for any domain" -f ($wildcard | ForEach-Object { $_.DomainType } | Sort-Object -Unique) -join '/')) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($externalRelay.Count -gt 0) {
        $problems.Add(("{0} accepted domains are configured as ExternalRelay, which relays mail on to a third party and must be deliberate: {1}" -f `
            $externalRelay.Count, (($externalRelay | ForEach-Object { $_.DomainName }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($defaults.Count -eq 0 -and $acceptedArr.Count -gt 0) {
        $problems.Add('No accepted domain is marked as the default, which breaks default address generation') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    elseif ($defaults.Count -gt 1) {
        $problems.Add(("{0} accepted domains are marked default, which is inconsistent" -f $defaults.Count)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($autoForward.Count -gt 0) {
        $problems.Add('The default remote domain (*) allows automatic forwarding, so mail can be auto-forwarded out of the organisation') | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($errors.Count -gt 0) {
        $problems.Add(("Some domain configuration could not be read: {0}" -f ($errors -join '; '))) | Out-Null
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
                 else { ("{0} accepted domains ({1} authoritative, {2} internal relay, {3} external relay) with one default, and {4} remote domains, are configured consistently." -f `
                        $acceptedArr.Count, $authoritative.Count, $internalRelay.Count, $externalRelay.Count, $remoteArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Remove wildcard accepted domains, confirm every ExternalRelay domain is intended, set exactly one default accepted domain, and disable automatic forwarding on the default remote domain unless the business requires it.' `
        -Metrics @{
            acceptedDomains = $acceptedArr.Count
            authoritative   = $authoritative.Count
            internalRelay   = $internalRelay.Count
            externalRelay   = $externalRelay.Count
            remoteDomains   = $remoteArr.Count
            emailAddressPolicies = $policyArr.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

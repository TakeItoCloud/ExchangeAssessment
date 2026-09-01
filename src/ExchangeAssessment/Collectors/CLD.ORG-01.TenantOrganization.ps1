<#
CLD.ORG-01 - Exchange Online organisation configuration.

Every tenant read goes through Invoke-ExchCloudQuery, which resolves the prefixed cmdlet name.
Calling Get-OrganizationConfig directly from inside the Exchange Management Shell would return
the on-premises organisation and label it as the tenant.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_CLD_ORG_01_TenantOrganization {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'CLD.ORG-01'

    $state = Get-ExchCloudState -Run $Run
    if ($null -eq $state -or -not $state.Connected) {
        return New-ExchCollectorResult -Findings @(New-ExchCloudUnavailableFinding -Control $control -Run $Run)
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $orgConfig = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-OrganizationConfig' -Errors $errors -ControlId $control.controlId) | Select-Object -First 1
    $domains   = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-AcceptedDomain'     -Errors $errors -ControlId $control.controlId)

    $orgRow = $null
    if ($orgConfig) {
        $orgRow = [pscustomobject]@{
            Name                        = [string]$orgConfig.Name
            DisplayName                 = [string]$orgConfig.DisplayName
            OAuth2ClientProfileEnabled  = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $orgConfig -Name 'OAuth2ClientProfileEnabled'))
            IsDehydrated                = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $orgConfig -Name 'IsDehydrated'))
            DefaultPublicFolderMailbox  = [string](Get-ExchCloudProperty -Object $orgConfig -Name 'DefaultPublicFolderMailbox')
            MailTipsAllTipsEnabled      = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $orgConfig -Name 'MailTipsAllTipsEnabled'))
            AuditDisabled               = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $orgConfig -Name 'AuditDisabled'))
            ExchangeVersion             = [string](Get-ExchCloudProperty -Object $orgConfig -Name 'ExchangeVersion')
            HybridConfigurationStatus   = [string](Get-ExchCloudProperty -Object $orgConfig -Name 'HybridConfigurationStatus')
        }
    }

    $domainRows = foreach ($d in $domains) {
        [pscustomobject]@{
            Name              = [string]$d.Name
            DomainName        = [string]$d.DomainName
            DomainType        = [string]$d.DomainType
            Default           = (ConvertTo-ExchFlatValue -Value $d.Default)
            MatchSubDomains   = (ConvertTo-ExchFlatValue -Value $d.MatchSubDomains)
            AuthenticationType = [string](Get-ExchCloudProperty -Object $d -Name 'AuthenticationType')
            InitialDomain     = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $d -Name 'InitialDomain'))
        }
    }
    $domainArr = @($domainRows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'cloud/organization.json' -ContentObject ([ordered]@{
        organizationConfig = $orgRow
        acceptedDomains    = $domainArr
        connection         = [ordered]@{ authMode = $state.AuthMode; organization = $state.Organization; prefix = $state.Prefix }
        errors             = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'cloud.organization' -Title 'Exchange Online Organisation' -Area 'Cloud' `
            -Columns @('Name', 'DisplayName', 'ExchangeVersion', 'OAuth2ClientProfileEnabled', 'IsDehydrated', 'HybridConfigurationStatus', 'DefaultPublicFolderMailbox', 'MailTipsAllTipsEnabled', 'AuditDisabled') `
            -Rows @($orgRow | Where-Object { $null -ne $_ })

        New-ExchInventorySection -Run $Run -Key 'cloud.accepted-domains' -Title 'Exchange Online Accepted Domains' -Area 'Cloud' `
            -Columns @('Name', 'DomainName', 'DomainType', 'Default', 'MatchSubDomains', 'AuthenticationType', 'InitialDomain') -Rows $domainArr
    )

    if ($null -eq $orgRow) {
        return New-ExchCollectorResult -Sections $sections -Findings @(
            New-ExchUnavailableFinding -Control $control -DataSource 'ExchangeOnline' -Severity 'Medium' `
                -Reason ("The tenant organisation configuration could not be read: {0}" -f ($errors -join '; ')) `
                -Remediation 'Confirm the account or application used for -IncludeExchangeOnline has at least View-Only Organization Management in the tenant.'
        )
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($orgRow.OAuth2ClientProfileEnabled -eq $false) {
        $problems.Add('Modern authentication (OAuth2ClientProfileEnabled) is disabled in the tenant, so clients fall back to legacy authentication') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($orgRow.AuditDisabled -eq $true) {
        $problems.Add('Tenant-wide mailbox auditing is disabled, so mailbox access is not recorded') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    $externalRelay = @($domainArr | Where-Object { $_.DomainType -eq 'ExternalRelay' })
    if ($externalRelay.Count -gt 0) {
        $problems.Add(("{0} tenant accepted domains are ExternalRelay and must be deliberate: {1}" -f $externalRelay.Count, `
            (($externalRelay | ForEach-Object { $_.DomainName }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($errors.Count -gt 0) {
        $problems.Add(("Some tenant configuration could not be read: {0}" -f ($errors -join '; '))) | Out-Null
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
                 else { ("Tenant {0} has modern authentication enabled, auditing on, and {1} accepted domains." -f $orgRow.Name, $domainArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Enable modern authentication and tenant-wide mailbox auditing, and confirm every ExternalRelay accepted domain is intended.' `
        -Metrics @{
            tenant          = $orgRow.Name
            acceptedDomains = $domainArr.Count
            externalRelay   = $externalRelay.Count
            authMode        = [string]$state.AuthMode
        } `
        -Meta @{ dataSources = @{ ExchangeOnline = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchCloudProperty {
    <#
    Reads a property that may or may not exist on a tenant object. Exchange Online adds and
    removes properties without notice, and Set-StrictMode turns a missing one into an exception
    that would cost the whole control.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties.Match($Name) | Select-Object -First 1
    if (-not $property) { return $null }
    return $property.Value
}

<#
CLD.SEC-01 - Exchange Online mail hygiene and Defender policies.

Exchange Online Protection is on by default, so the question is not whether policies exist but
whether anyone tightened them. A default anti-spam policy that quarantines nothing and an absent
anti-phishing policy are the two most common gaps.

Safe Links and Safe Attachments need Defender for Office 365. Their absence is reported as
"not licensed or not configured" rather than as a failure, because the tool cannot tell the two
apart from the Exchange Online session alone.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_CLD_SEC_01_TenantSecurity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'CLD.SEC-01'

    $state = Get-ExchCloudState -Run $Run
    if ($null -eq $state -or -not $state.Connected) {
        return New-ExchCollectorResult -Findings @(New-ExchCloudUnavailableFinding -Control $control -Run $Run)
    }

    $errors = New-Object System.Collections.Generic.List[string]

    $spam        = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-HostedContentFilterPolicy' -Errors $errors -ControlId $control.controlId)
    $outboundSpam= @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-HostedOutboundSpamFilterPolicy' -Errors $errors -ControlId $control.controlId)
    $malware     = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-MalwareFilterPolicy' -Errors $errors -ControlId $control.controlId)
    $phish       = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-AntiPhishPolicy' -Errors $errors -ControlId $control.controlId)
    $dkim        = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-DkimSigningConfig' -Errors $errors -ControlId $control.controlId)

    # Defender for Office 365 only. Absent on an Exchange Online Protection-only tenant.
    $safeLinks       = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-SafeLinksPolicy' -Errors $errors -ControlId $control.controlId)
    $safeAttachments = @(Invoke-ExchCloudQuery -Run $Run -Name 'Get-SafeAttachmentPolicy' -Errors $errors -ControlId $control.controlId)

    $policyRows = New-Object System.Collections.Generic.List[object]

    foreach ($p in $spam) {
        $policyRows.Add([pscustomobject]@{
            Kind    = 'Anti-spam (inbound)'
            Name    = [string]$p.Name
            IsDefault = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $p -Name 'IsDefault'))
            Enabled = $true
            Detail  = ("SpamAction={0}; HighConfidenceSpamAction={1}; PhishSpamAction={2}; BulkThreshold={3}; QuarantineRetentionDays={4}" -f `
                        [string](Get-ExchCloudProperty -Object $p -Name 'SpamAction'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'HighConfidenceSpamAction'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'PhishSpamAction'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'BulkThreshold'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'QuarantineRetentionPeriod'))
        }) | Out-Null
    }
    foreach ($p in $outboundSpam) {
        $policyRows.Add([pscustomobject]@{
            Kind    = 'Anti-spam (outbound)'
            Name    = [string]$p.Name
            IsDefault = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $p -Name 'IsDefault'))
            Enabled = $true
            Detail  = ("RecipientLimitExternalPerHour={0}; ActionWhenThresholdReached={1}; AutoForwardingMode={2}" -f `
                        [string](Get-ExchCloudProperty -Object $p -Name 'RecipientLimitExternalPerHour'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'ActionWhenThresholdReached'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'AutoForwardingMode'))
        }) | Out-Null
    }
    foreach ($p in $malware) {
        $policyRows.Add([pscustomobject]@{
            Kind    = 'Anti-malware'
            Name    = [string]$p.Name
            IsDefault = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $p -Name 'IsDefault'))
            Enabled = $true
            Detail  = ("EnableFileFilter={0}; ZapEnabled={1}" -f `
                        [string](Get-ExchCloudProperty -Object $p -Name 'EnableFileFilter'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'ZapEnabled'))
        }) | Out-Null
    }
    foreach ($p in $phish) {
        $policyRows.Add([pscustomobject]@{
            Kind    = 'Anti-phishing'
            Name    = [string]$p.Name
            IsDefault = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $p -Name 'IsDefault'))
            Enabled = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $p -Name 'Enabled'))
            Detail  = ("EnableSpoofIntelligence={0}; EnableMailboxIntelligence={1}; PhishThresholdLevel={2}; EnableTargetedUserProtection={3}" -f `
                        [string](Get-ExchCloudProperty -Object $p -Name 'EnableSpoofIntelligence'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'EnableMailboxIntelligence'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'PhishThresholdLevel'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'EnableTargetedUserProtection'))
        }) | Out-Null
    }
    foreach ($p in $safeLinks) {
        $policyRows.Add([pscustomobject]@{
            Kind    = 'Safe Links'
            Name    = [string]$p.Name
            IsDefault = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $p -Name 'IsDefault'))
            Enabled = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $p -Name 'EnableSafeLinksForEmail'))
            Detail  = ("ScanUrls={0}; DeliverMessageAfterScan={1}; TrackClicks={2}" -f `
                        [string](Get-ExchCloudProperty -Object $p -Name 'ScanUrls'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'DeliverMessageAfterScan'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'TrackClicks'))
        }) | Out-Null
    }
    foreach ($p in $safeAttachments) {
        $policyRows.Add([pscustomobject]@{
            Kind    = 'Safe Attachments'
            Name    = [string]$p.Name
            IsDefault = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $p -Name 'IsDefault'))
            Enabled = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $p -Name 'Enable'))
            Detail  = ("Action={0}; Redirect={1}" -f `
                        [string](Get-ExchCloudProperty -Object $p -Name 'Action'),
                        [string](Get-ExchCloudProperty -Object $p -Name 'Redirect'))
        }) | Out-Null
    }

    $dkimRows = foreach ($d in $dkim) {
        [pscustomobject]@{
            Domain    = [string]$d.Domain
            Enabled   = (ConvertTo-ExchFlatValue -Value $d.Enabled)
            Status    = [string](Get-ExchCloudProperty -Object $d -Name 'Status')
            Selector1CNAME = [string](Get-ExchCloudProperty -Object $d -Name 'Selector1CNAME')
            LastChecked    = (ConvertTo-ExchFlatValue -Value (Get-ExchCloudProperty -Object $d -Name 'LastChecked'))
        }
    }

    $policyArr = @($policyRows.ToArray())
    $dkimArr   = @($dkimRows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'cloud/security-policies.json' -ContentObject ([ordered]@{
        policies = $policyArr
        dkim     = $dkimArr
        errors   = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'cloud.security-policies' -Title 'Exchange Online Mail Hygiene Policies' -Area 'Cloud' `
            -Columns @('Kind', 'Name', 'IsDefault', 'Enabled', 'Detail') -Rows $policyArr

        New-ExchInventorySection -Run $Run -Key 'cloud.dkim' -Title 'DKIM Signing' -Area 'Cloud' `
            -Columns @('Domain', 'Enabled', 'Status', 'Selector1CNAME', 'LastChecked') -Rows $dkimArr
    )

    $requirePhish = [bool](Get-ExchThreshold -Run $Run -Name 'Cloud.RequireAntiPhishPolicy' -Default $true)

    $problems = New-Object System.Collections.Generic.List[string]
    $notes    = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if (@($policyArr | Where-Object { $_.Kind -eq 'Anti-spam (inbound)' }).Count -eq 0) {
        $problems.Add('No inbound anti-spam policy was returned, so spam handling could not be assessed') | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    if ($requirePhish) {
        $phishPolicies = @($policyArr | Where-Object { $_.Kind -eq 'Anti-phishing' })
        $enabledPhish = @($phishPolicies | Where-Object { $_.Enabled -eq $true })
        if ($phishPolicies.Count -eq 0) {
            $problems.Add('No anti-phishing policy exists, so impersonation and spoof protection are at their defaults only') | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
        elseif ($enabledPhish.Count -eq 0) {
            $problems.Add(("{0} anti-phishing policies exist but none is enabled" -f $phishPolicies.Count)) | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
    }

    # Only default policies means nobody has tailored hygiene for this tenant.
    $custom = @($policyArr | Where-Object { $_.IsDefault -eq $false })
    if ($policyArr.Count -gt 0 -and $custom.Count -eq 0) {
        $problems.Add('Every mail hygiene policy in the tenant is the built-in default; none has been tailored to this organisation') | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $unsignedDomains = @($dkimArr | Where-Object { $_.Enabled -eq $false })
    if ($unsignedDomains.Count -gt 0) {
        $problems.Add(("DKIM signing is disabled for {0} domains, so receivers cannot verify mail was sent by this tenant: {1}" -f `
            $unsignedDomains.Count, (($unsignedDomains | ForEach-Object { $_.Domain }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    # Defender-only features: absent is not the same as misconfigured.
    foreach ($item in @(
        @{ Kind = 'Safe Links';       Threshold = 'Cloud.RequireSafeLinks' },
        @{ Kind = 'Safe Attachments'; Threshold = 'Cloud.RequireSafeAttachments' }
    )) {
        if (-not [bool](Get-ExchThreshold -Run $Run -Name $item.Threshold -Default $true)) { continue }
        $present = @($policyArr | Where-Object { $_.Kind -eq $item.Kind })
        if ($present.Count -eq 0) {
            $notes.Add(("no {0} policy was returned, which means either Defender for Office 365 is not licensed or the feature is not configured" -f $item.Kind)) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }
        elseif (@($present | Where-Object { $_.Enabled -eq $true }).Count -eq 0) {
            $problems.Add(("{0} policies exist but none is enabled" -f $item.Kind)) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }
    }

    if ($errors.Count -gt 0) {
        # A missing Defender cmdlet is expected on an EOP-only tenant, so it is a note, not a fault.
        $realErrors = @($errors | Where-Object { $_ -notmatch 'SafeLinks|SafeAttachment' })
        if ($realErrors.Count -gt 0) {
            $problems.Add(("Some hygiene configuration could not be read: {0}" -f ($realErrors -join '; '))) | Out-Null
            $outcomes.Add('Unknown') | Out-Null
        }
    }
    if ($problems.Count -eq 0 -and $notes.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Medium' }
        'Unknown'            { 'Medium' }
        default              { 'Low' }
    }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($p in $problems) { $parts.Add($p) | Out-Null }
    if ($notes.Count -gt 0) { $parts.Add(("Also: {0}" -f ($notes -join '; '))) | Out-Null }

    $rationale = if ($parts.Count -gt 0) { ($parts -join '. ') + '.' }
                 else { ("{0} mail hygiene policies are configured including an enabled anti-phishing policy, and DKIM signs all {1} domains." -f $policyArr.Count, $dkimArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Create an anti-phishing policy with spoof and impersonation protection enabled, tighten the inbound anti-spam actions from their defaults, enable DKIM signing for every sending domain, and enable Safe Links and Safe Attachments where Defender for Office 365 is licensed. Microsoft publishes recommended Standard and Strict values.' `
        -Metrics @{
            policies        = $policyArr.Count
            customPolicies  = $custom.Count
            antiPhishPolicies = @($policyArr | Where-Object { $_.Kind -eq 'Anti-phishing' }).Count
            dkimDomains     = $dkimArr.Count
            dkimDisabled    = $unsignedDomains.Count
        } `
        -Meta @{ dataSources = @{ ExchangeOnline = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

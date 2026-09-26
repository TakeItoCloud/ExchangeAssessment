<#
CAS-01 - Client access policies and legacy authentication.

Basic authentication is the single most exploited path into an Exchange organisation, because it
sends a reusable credential and cannot carry multi-factor authentication. This control reports
whether an authentication policy blocks it, which legacy protocols are still enabled per mailbox,
and what mobile device policy applies.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_CAS_01_ClientAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'CAS-01'

    $errors = New-Object System.Collections.Generic.List[string]

    $authPolicies = @(Invoke-ExchQuery -Label 'Get-AuthenticationPolicy'   -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-AuthenticationPolicy -ErrorAction Stop })
    $orgConfig    = @(Invoke-ExchQuery -Label 'Get-OrganizationConfig'     -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-OrganizationConfig -ErrorAction Stop }) | Select-Object -First 1
    $owaPolicies  = @(Invoke-ExchQuery -Label 'Get-OwaMailboxPolicy'       -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-OwaMailboxPolicy -ErrorAction Stop })
    $easPolicies  = @(Invoke-ExchQuery -Label 'Get-MobileDeviceMailboxPolicy' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-MobileDeviceMailboxPolicy -ErrorAction Stop })
    $easOrg       = @(Invoke-ExchQuery -Label 'Get-ActiveSyncOrganizationSettings' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-ActiveSyncOrganizationSettings -ErrorAction Stop }) | Select-Object -First 1
    $casMailboxes = @(Invoke-ExchQuery -Label 'Get-CASMailbox'             -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-CASMailbox -ResultSize 5000 -ErrorAction Stop })
    $devices      = @(Invoke-ExchQuery -Label 'Get-MobileDevice'           -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-MobileDevice -ResultSize 5000 -ErrorAction Stop })

    # Every property read below is guarded. The first live run lost this whole control to one
    # property name that mobile device policies do not carry, under strict mode. Inventory-only
    # fields become a blank cell when absent; fields a verdict depends on are listed in
    # UnreadableFields and make that verdict Unknown.
    $authRows = foreach ($p in $authPolicies) {
        [pscustomobject]@{
            Name                        = [string](Get-ExchObjectValue -InputObject $p -Name 'Name' -Default '')
            AllowBasicAuthActiveSync    = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'AllowBasicAuthActiveSync'))
            AllowBasicAuthAutodiscover  = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'AllowBasicAuthAutodiscover'))
            AllowBasicAuthImap          = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'AllowBasicAuthImap'))
            AllowBasicAuthMapi          = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'AllowBasicAuthMapi'))
            AllowBasicAuthOutlookService= (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'AllowBasicAuthOutlookService'))
            AllowBasicAuthPop           = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'AllowBasicAuthPop'))
            AllowBasicAuthPowershell    = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'AllowBasicAuthPowershell'))
            AllowBasicAuthRpc           = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'AllowBasicAuthRpc'))
            AllowBasicAuthWebServices   = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'AllowBasicAuthWebServices'))
        }
    }
    $authArr = @($authRows)

    # '' is a measured "no default policy"; $null is "not read" - the query failed or the
    # organization config did not carry the property - and the two reach different verdicts.
    $defaultAuthPolicy = $null
    if ($orgConfig -and (Test-ExchObjectProperty -InputObject $orgConfig -Name 'DefaultAuthenticationPolicy')) {
        $defaultAuthPolicy = [string](Get-ExchObjectValue -InputObject $orgConfig -Name 'DefaultAuthenticationPolicy' -Default '')
    }

    $owaRows = foreach ($p in $owaPolicies) {
        [pscustomobject]@{
            Name                = [string](Get-ExchObjectValue -InputObject $p -Name 'Name' -Default '')
            IsDefault           = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'IsDefault'))
            DirectFileAccessOnPublicComputersEnabled  = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'DirectFileAccessOnPublicComputersEnabled'))
            DirectFileAccessOnPrivateComputersEnabled = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'DirectFileAccessOnPrivateComputersEnabled'))
            ActiveSyncIntegrationEnabled = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'ActiveSyncIntegrationEnabled'))
            ExplicitLogonEnabled= (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'ExplicitLogonEnabled'))
        }
    }

    # Mobile device mailbox policies carry AllowSimplePassword. AllowSimpleDevicePassword is the
    # name on the older ActiveSync mailbox policy cmdlets, which Exchange 2013 and later replace.
    # Source: https://learn.microsoft.com/powershell/module/exchangepowershell/set-mobiledevicemailboxpolicy?view=exchange-ps
    # and .../set-activesyncmailboxpolicy?view=exchange-ps - read 2026-09-26.
    $easRows = foreach ($p in $easPolicies) {
        [pscustomobject]@{
            Name                   = [string](Get-ExchObjectValue -InputObject $p -Name 'Name' -Default '')
            IsDefault              = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'IsDefault'))
            PasswordEnabled        = (Get-ExchObjectBool -InputObject $p -Name 'PasswordEnabled')
            MinPasswordLength      = [string](Get-ExchObjectValue -InputObject $p -Name 'MinPasswordLength' -Default '')
            AllowSimplePassword    = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'AllowSimplePassword'))
            RequireDeviceEncryption= (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'RequireDeviceEncryption'))
            MaxInactivityTimeLock  = [string](Get-ExchObjectValue -InputObject $p -Name 'MaxInactivityTimeLock' -Default '')
            AllowNonProvisionableDevices = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $p -Name 'AllowNonProvisionableDevices'))
            UnreadableFields       = (Get-ExchMissingProperty -InputObject $p -Name @('PasswordEnabled'))
        }
    }

    $protocolProperties = @('OWAEnabled', 'ActiveSyncEnabled', 'PopEnabled', 'ImapEnabled', 'MAPIEnabled', 'EwsEnabled')
    $casRows = foreach ($m in $casMailboxes) {
        [pscustomobject]@{
            Name                 = [string](Get-ExchObjectValue -InputObject $m -Name 'Name' -Default '')
            PrimarySmtpAddress   = [string](Get-ExchObjectValue -InputObject $m -Name 'PrimarySmtpAddress' -Default '')
            OWAEnabled           = (Get-ExchObjectBool -InputObject $m -Name 'OWAEnabled')
            ActiveSyncEnabled    = (Get-ExchObjectBool -InputObject $m -Name 'ActiveSyncEnabled')
            PopEnabled           = (Get-ExchObjectBool -InputObject $m -Name 'PopEnabled')
            ImapEnabled          = (Get-ExchObjectBool -InputObject $m -Name 'ImapEnabled')
            MAPIEnabled          = (Get-ExchObjectBool -InputObject $m -Name 'MAPIEnabled')
            EwsEnabled           = (Get-ExchObjectBool -InputObject $m -Name 'EwsEnabled')
            ActiveSyncMailboxPolicy = [string](Get-ExchObjectValue -InputObject $m -Name 'ActiveSyncMailboxPolicy' -Default '')
            OwaMailboxPolicy     = [string](Get-ExchObjectValue -InputObject $m -Name 'OwaMailboxPolicy' -Default '')
            UnreadableFields     = (Get-ExchMissingProperty -InputObject $m -Name $protocolProperties)
        }
    }

    $staleDays = [int](Get-ExchThreshold -Run $Run -Name 'ClientAccess.StaleDeviceDays' -Default 90)
    $now = Get-Date
    $deviceRows = foreach ($d in $devices) {
        $lastSync = $null
        $ageDays = $null
        $changed = Get-ExchObjectValue -InputObject $d -Name 'WhenChangedUTC'
        if ($changed) {
            try { $lastSync = [datetime]$changed; $ageDays = [math]::Round(($now - $lastSync).TotalDays, 1) } catch { $ageDays = $null }
        }
        [pscustomobject]@{
            UserDisplayName = [string](Get-ExchObjectValue -InputObject $d -Name 'UserDisplayName' -Default '')
            DeviceOS        = [string](Get-ExchObjectValue -InputObject $d -Name 'DeviceOS' -Default '')
            DeviceType      = [string](Get-ExchObjectValue -InputObject $d -Name 'DeviceType' -Default '')
            DeviceModel     = [string](Get-ExchObjectValue -InputObject $d -Name 'DeviceModel' -Default '')
            ClientType      = [string](Get-ExchObjectValue -InputObject $d -Name 'ClientType' -Default '')
            DeviceAccessState = [string](Get-ExchObjectValue -InputObject $d -Name 'DeviceAccessState' -Default '')
            LastChangedUtc  = $lastSync
            AgeDays         = $ageDays
            IsStale         = ($null -ne $ageDays -and $ageDays -gt $staleDays)
        }
    }

    $owaArr    = @($owaRows)
    $easArr    = @($easRows)
    $casArr    = @($casRows)
    $deviceArr = @($deviceRows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'client/access.json' -ContentObject ([ordered]@{
        authenticationPolicies    = $authArr
        defaultAuthenticationPolicy = $defaultAuthPolicy
        owaMailboxPolicies        = $owaArr
        mobileDeviceMailboxPolicies = $easArr
        activeSyncOrganizationSettings = $easOrg
        casMailboxes              = $casArr
        mobileDevices             = $deviceArr
        errors                    = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'client.authentication-policies' -Title 'Authentication Policies' -Area 'Client' `
            -Columns @('Name', 'AllowBasicAuthActiveSync', 'AllowBasicAuthAutodiscover', 'AllowBasicAuthImap', 'AllowBasicAuthMapi', 'AllowBasicAuthOutlookService', 'AllowBasicAuthPop', 'AllowBasicAuthPowershell', 'AllowBasicAuthRpc', 'AllowBasicAuthWebServices') `
            -Rows $authArr

        New-ExchInventorySection -Run $Run -Key 'client.owa-policies' -Title 'Outlook on the Web Mailbox Policies' -Area 'Client' `
            -Columns @('Name', 'IsDefault', 'DirectFileAccessOnPublicComputersEnabled', 'DirectFileAccessOnPrivateComputersEnabled', 'ActiveSyncIntegrationEnabled', 'ExplicitLogonEnabled') -Rows $owaArr

        New-ExchInventorySection -Run $Run -Key 'client.mobile-device-policies' -Title 'Mobile Device Mailbox Policies' -Area 'Client' `
            -Columns @('Name', 'IsDefault', 'PasswordEnabled', 'MinPasswordLength', 'AllowSimplePassword', 'RequireDeviceEncryption', 'MaxInactivityTimeLock', 'AllowNonProvisionableDevices', 'UnreadableFields') -Rows $easArr

        New-ExchInventorySection -Run $Run -Key 'client.cas-mailboxes' -Title 'Per-Mailbox Client Protocols' -Area 'Client' `
            -Columns @('Name', 'PrimarySmtpAddress', 'OWAEnabled', 'ActiveSyncEnabled', 'PopEnabled', 'ImapEnabled', 'MAPIEnabled', 'EwsEnabled', 'ActiveSyncMailboxPolicy', 'OwaMailboxPolicy', 'UnreadableFields') `
            -Rows $casArr -HighCardinality

        New-ExchInventorySection -Run $Run -Key 'client.mobile-devices' -Title 'Mobile Devices' -Area 'Client' `
            -Columns @('UserDisplayName', 'DeviceOS', 'DeviceType', 'DeviceModel', 'ClientType', 'DeviceAccessState', 'LastChangedUtc', 'AgeDays', 'IsStale') `
            -Rows $deviceArr -HighCardinality
    )

    $requireAuthPolicy = [bool](Get-ExchThreshold -Run $Run -Name 'ClientAccess.RequireAuthenticationPolicy' -Default $true)
    $requireDefault    = [bool](Get-ExchThreshold -Run $Run -Name 'ClientAccess.RequireDefaultAuthPolicy' -Default $true)
    $discouraged       = @(Get-ExchThreshold -Run $Run -Name 'ClientAccess.DiscouragedProtocols' -Default @())
    $requireEasPolicy  = [bool](Get-ExchThreshold -Run $Run -Name 'ClientAccess.RequireMobileDevicePolicy' -Default $true)

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    # A population that could not be read is not an empty one. Each check below first asks
    # whether the query it depends on succeeded; the first live run's account was refused
    # Get-AuthenticationPolicy by RBAC, and "no authentication policy exists" would have been
    # reported as NonCompliant about policies nobody had read.
    $failedQueries = @($errors | ForEach-Object { ($_ -split ':', 2)[0] })
    $authRead    = ($failedQueries -notcontains 'Get-AuthenticationPolicy')
    $easRead     = ($failedQueries -notcontains 'Get-MobileDeviceMailboxPolicy')

    if (-not $authRead) {
        $problems.Add('Authentication policies could not be read, so whether Basic authentication is blocked is unknown') | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif ($requireAuthPolicy -and $authArr.Count -eq 0) {
        $problems.Add('No authentication policy exists, so Basic authentication is available on every protocol') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    else {
        $blocking = @($authArr | Where-Object { Test-ExchPolicyBlocksBasicAuth -Policy $_ })
        if ($blocking.Count -eq 0 -and $authArr.Count -gt 0) {
            $problems.Add(("No authentication policy blocks Basic authentication on every protocol; {0} policies exist and each still permits it somewhere" -f $authArr.Count)) | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
        if ($requireDefault -and $null -eq $defaultAuthPolicy) {
            $problems.Add('The organisation default authentication policy could not be read, so whether mailboxes without an explicit assignment are protected is unknown') | Out-Null
            $outcomes.Add('Unknown') | Out-Null
        }
        elseif ($requireDefault -and -not $defaultAuthPolicy) {
            $problems.Add('No authentication policy is set as the organisation default, so mailboxes without an explicit assignment are unprotected') | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
    }

    $unreadCas = @($casArr | Where-Object { $_.UnreadableFields })
    if ($unreadCas.Count -gt 0) {
        $problems.Add(("{0} mailboxes were returned without some protocol settings, so whether those protocols are enabled on them is unknown: {1}" -f $unreadCas.Count, `
            ((@($unreadCas | ForEach-Object { $_.UnreadableFields -split ';' }) | Select-Object -Unique) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    foreach ($protocol in $discouraged) {
        $enabled = @($casArr | Where-Object { $_.$protocol -eq $true })
        if ($enabled.Count -gt 0) {
            $problems.Add(("{0} is enabled on {1} mailboxes; legacy protocols cannot carry multi-factor authentication" -f `
                ($protocol -replace 'Enabled$', ''), $enabled.Count)) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }
    }

    if (-not $easRead) {
        $problems.Add('Mobile device mailbox policies could not be read, so device password and policy coverage are unknown') | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif ($requireEasPolicy -and $easArr.Count -eq 0 -and $deviceArr.Count -gt 0) {
        $problems.Add(("{0} mobile devices are connected but no mobile device mailbox policy is defined" -f $deviceArr.Count)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $unreadEas = @($easArr | Where-Object { $_.UnreadableFields })
    if ($unreadEas.Count -gt 0) {
        $problems.Add(("{0} mobile device policies were returned without PasswordEnabled, so whether they require a device password is unknown: {1}" -f $unreadEas.Count, `
            (($unreadEas | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    $weakEas = @($easArr | Where-Object { $_.PasswordEnabled -eq $false })
    if ($weakEas.Count -gt 0) {
        $problems.Add(("{0} mobile device policies do not require a device password: {1}" -f $weakEas.Count, `
            (($weakEas | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $stale = @($deviceArr | Where-Object { $_.IsStale })
    if ($stale.Count -gt 0) {
        $problems.Add(("{0} mobile device partnerships have not synchronised in more than {1} days and are stale registrations" -f $stale.Count, $staleDays)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($errors.Count -gt 0) {
        $problems.Add(("Some client access configuration could not be read: {0}" -f ($errors -join '; '))) | Out-Null
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
                 else { ("An authentication policy blocks Basic authentication and is set as the organisation default, legacy protocols are off, and {0} mobile devices are covered by {1} device policies." -f `
                        $deviceArr.Count, $easArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($incomplete) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Create an authentication policy that denies Basic authentication on every protocol, set it as the organisation default, and disable POP and IMAP on mailboxes that do not need them. Require a device password in every mobile device policy and remove stale device partnerships.' `
        -Metrics @{
            authenticationPolicies = $authArr.Count
            defaultAuthenticationPolicy = $defaultAuthPolicy
            owaPolicies      = $owaArr.Count
            mobileDevicePolicies = $easArr.Count
            casMailboxes     = $casArr.Count
            mobileDevices    = $deviceArr.Count
            staleDevices     = $stale.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($incomplete) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Test-ExchPolicyBlocksBasicAuth {
    <#
    True when an authentication policy denies Basic authentication on every protocol it covers.
    A policy that still allows it anywhere leaves a usable credential-replay path, so one
    remaining $true is enough to fail the whole policy.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Policy)

    $protocols = @(
        'AllowBasicAuthActiveSync'
        'AllowBasicAuthAutodiscover'
        'AllowBasicAuthImap'
        'AllowBasicAuthMapi'
        'AllowBasicAuthOutlookService'
        'AllowBasicAuthPop'
        'AllowBasicAuthPowershell'
        'AllowBasicAuthRpc'
        'AllowBasicAuthWebServices'
    )

    foreach ($protocol in $protocols) {
        $property = $Policy.PSObject.Properties.Match($protocol) | Select-Object -First 1
        if ($property -and $property.Value -eq $true) { return $false }
    }

    return $true
}

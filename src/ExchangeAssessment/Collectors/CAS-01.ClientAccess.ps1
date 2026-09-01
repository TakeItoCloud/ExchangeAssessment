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

    $authRows = foreach ($p in $authPolicies) {
        [pscustomobject]@{
            Name                        = [string]$p.Name
            AllowBasicAuthActiveSync    = (ConvertTo-ExchFlatValue -Value $p.AllowBasicAuthActiveSync)
            AllowBasicAuthAutodiscover  = (ConvertTo-ExchFlatValue -Value $p.AllowBasicAuthAutodiscover)
            AllowBasicAuthImap          = (ConvertTo-ExchFlatValue -Value $p.AllowBasicAuthImap)
            AllowBasicAuthMapi          = (ConvertTo-ExchFlatValue -Value $p.AllowBasicAuthMapi)
            AllowBasicAuthOutlookService= (ConvertTo-ExchFlatValue -Value $p.AllowBasicAuthOutlookService)
            AllowBasicAuthPop           = (ConvertTo-ExchFlatValue -Value $p.AllowBasicAuthPop)
            AllowBasicAuthPowershell    = (ConvertTo-ExchFlatValue -Value $p.AllowBasicAuthPowershell)
            AllowBasicAuthRpc           = (ConvertTo-ExchFlatValue -Value $p.AllowBasicAuthRpc)
            AllowBasicAuthWebServices   = (ConvertTo-ExchFlatValue -Value $p.AllowBasicAuthWebServices)
        }
    }
    $authArr = @($authRows)

    $defaultAuthPolicy = ''
    if ($orgConfig) {
        $prop = $orgConfig.PSObject.Properties.Match('DefaultAuthenticationPolicy') | Select-Object -First 1
        if ($prop) { $defaultAuthPolicy = [string]$prop.Value }
    }

    $owaRows = foreach ($p in $owaPolicies) {
        [pscustomobject]@{
            Name                = [string]$p.Name
            IsDefault           = (ConvertTo-ExchFlatValue -Value $p.IsDefault)
            DirectFileAccessOnPublicComputersEnabled  = (ConvertTo-ExchFlatValue -Value $p.DirectFileAccessOnPublicComputersEnabled)
            DirectFileAccessOnPrivateComputersEnabled = (ConvertTo-ExchFlatValue -Value $p.DirectFileAccessOnPrivateComputersEnabled)
            ActiveSyncIntegrationEnabled = (ConvertTo-ExchFlatValue -Value $p.ActiveSyncIntegrationEnabled)
            ExplicitLogonEnabled= (ConvertTo-ExchFlatValue -Value $p.ExplicitLogonEnabled)
        }
    }

    $easRows = foreach ($p in $easPolicies) {
        [pscustomobject]@{
            Name                   = [string]$p.Name
            IsDefault              = (ConvertTo-ExchFlatValue -Value $p.IsDefault)
            PasswordEnabled        = (ConvertTo-ExchFlatValue -Value $p.PasswordEnabled)
            MinPasswordLength      = [string]$p.MinPasswordLength
            AllowSimpleDevicePassword = (ConvertTo-ExchFlatValue -Value $p.AllowSimpleDevicePassword)
            RequireDeviceEncryption= (ConvertTo-ExchFlatValue -Value $p.RequireDeviceEncryption)
            MaxInactivityTimeLock  = [string]$p.MaxInactivityTimeLock
            AllowNonProvisionableDevices = (ConvertTo-ExchFlatValue -Value $p.AllowNonProvisionableDevices)
        }
    }

    $casRows = foreach ($m in $casMailboxes) {
        [pscustomobject]@{
            Name                 = [string]$m.Name
            PrimarySmtpAddress   = [string]$m.PrimarySmtpAddress
            OWAEnabled           = (ConvertTo-ExchFlatValue -Value $m.OWAEnabled)
            ActiveSyncEnabled    = (ConvertTo-ExchFlatValue -Value $m.ActiveSyncEnabled)
            PopEnabled           = (ConvertTo-ExchFlatValue -Value $m.PopEnabled)
            ImapEnabled          = (ConvertTo-ExchFlatValue -Value $m.ImapEnabled)
            MAPIEnabled          = (ConvertTo-ExchFlatValue -Value $m.MAPIEnabled)
            EwsEnabled           = (ConvertTo-ExchFlatValue -Value $m.EwsEnabled)
            ActiveSyncMailboxPolicy = [string]$m.ActiveSyncMailboxPolicy
            OwaMailboxPolicy     = [string]$m.OwaMailboxPolicy
        }
    }

    $staleDays = [int](Get-ExchThreshold -Run $Run -Name 'ClientAccess.StaleDeviceDays' -Default 90)
    $now = Get-Date
    $deviceRows = foreach ($d in $devices) {
        $lastSync = $null
        $ageDays = $null
        $prop = $d.PSObject.Properties.Match('WhenChangedUTC') | Select-Object -First 1
        if ($prop -and $prop.Value) {
            try { $lastSync = [datetime]$prop.Value; $ageDays = [math]::Round(($now - $lastSync).TotalDays, 1) } catch { $ageDays = $null }
        }
        [pscustomobject]@{
            UserDisplayName = [string]$d.UserDisplayName
            DeviceOS        = [string]$d.DeviceOS
            DeviceType      = [string]$d.DeviceType
            DeviceModel     = [string]$d.DeviceModel
            ClientType      = [string]$d.ClientType
            DeviceAccessState = [string]$d.DeviceAccessState
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
            -Columns @('Name', 'IsDefault', 'PasswordEnabled', 'MinPasswordLength', 'AllowSimpleDevicePassword', 'RequireDeviceEncryption', 'MaxInactivityTimeLock', 'AllowNonProvisionableDevices') -Rows $easArr

        New-ExchInventorySection -Run $Run -Key 'client.cas-mailboxes' -Title 'Per-Mailbox Client Protocols' -Area 'Client' `
            -Columns @('Name', 'PrimarySmtpAddress', 'OWAEnabled', 'ActiveSyncEnabled', 'PopEnabled', 'ImapEnabled', 'MAPIEnabled', 'EwsEnabled', 'ActiveSyncMailboxPolicy', 'OwaMailboxPolicy') `
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

    if ($requireAuthPolicy -and $authArr.Count -eq 0) {
        $problems.Add('No authentication policy exists, so Basic authentication is available on every protocol') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    else {
        $blocking = @($authArr | Where-Object { Test-ExchPolicyBlocksBasicAuth -Policy $_ })
        if ($blocking.Count -eq 0 -and $authArr.Count -gt 0) {
            $problems.Add(("No authentication policy blocks Basic authentication on every protocol; {0} policies exist and each still permits it somewhere" -f $authArr.Count)) | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
        if ($requireDefault -and -not $defaultAuthPolicy) {
            $problems.Add('No authentication policy is set as the organisation default, so mailboxes without an explicit assignment are unprotected') | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
    }

    foreach ($protocol in $discouraged) {
        $enabled = @($casArr | Where-Object { $_.$protocol -eq $true })
        if ($enabled.Count -gt 0) {
            $problems.Add(("{0} is enabled on {1} mailboxes; legacy protocols cannot carry multi-factor authentication" -f `
                ($protocol -replace 'Enabled$', ''), $enabled.Count)) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }
    }

    if ($requireEasPolicy -and $easArr.Count -eq 0 -and $deviceArr.Count -gt 0) {
        $problems.Add(("{0} mobile devices are connected but no mobile device mailbox policy is defined" -f $deviceArr.Count)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $weakEas = @($easArr | Where-Object { $_.PasswordEnabled -ne $true })
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
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
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
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

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

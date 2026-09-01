<#
TR.CFG-01 - Organisation and server transport configuration.

The transport settings that sit behind the connectors: organisation-wide limits, shadow
redundancy and Safety Net, per-server transport service configuration, and the transport and
journal rules that quietly redirect or copy mail.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_TR_CFG_01_TransportConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'TR.CFG-01'

    $errors = New-Object System.Collections.Generic.List[string]

    $config    = @(Invoke-ExchQuery -Label 'Get-TransportConfig'           -Errors $errors -Script { Get-TransportConfig -ErrorAction Stop }) | Select-Object -First 1
    $services  = @(Invoke-ExchQuery -Label 'Get-TransportService'          -Errors $errors -Script { Get-TransportService -ErrorAction Stop })
    $frontend  = @(Invoke-ExchQuery -Label 'Get-FrontendTransportService'  -Errors $errors -Script { Get-FrontendTransportService -ErrorAction Stop })
    $rules     = @(Invoke-ExchQuery -Label 'Get-TransportRule'             -Errors $errors -Script { Get-TransportRule -ErrorAction Stop })
    $journal   = @(Invoke-ExchQuery -Label 'Get-JournalRule'               -Errors $errors -Script { Get-JournalRule -ErrorAction Stop })

    if ($null -eq $config) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control `
                -Reason ("Organisation transport configuration could not be read: {0}" -f ($errors -join '; ')) `
                -Remediation 'Run from an Exchange Management Shell with rights to read the organisation transport configuration.'
        )
    }

    $shadowEnabled = $true
    $shadowProp = $config.PSObject.Properties.Match('ShadowRedundancyEnabled') | Select-Object -First 1
    if ($shadowProp) { $shadowEnabled = [bool]$shadowProp.Value }

    $safetyNetHours = $null
    $safetyProp = $config.PSObject.Properties.Match('SafetyNetHoldTime') | Select-Object -First 1
    if ($safetyProp -and $safetyProp.Value) {
        try { $safetyNetHours = [math]::Round(([timespan]::Parse([string]$safetyProp.Value)).TotalHours, 2) } catch { $safetyNetHours = $null }
    }

    $configRow = [pscustomobject]@{
        MaxReceiveSize           = [string]$config.MaxReceiveSize
        MaxSendSize              = [string]$config.MaxSendSize
        MaxRecipientEnvelopeLimit= [string]$config.MaxRecipientEnvelopeLimit
        ShadowRedundancyEnabled  = $shadowEnabled
        SafetyNetHoldTime        = [string]$config.SafetyNetHoldTime
        SafetyNetHoldTimeHours   = $safetyNetHours
        ShadowMessageAutoDiscardInterval = [string]$config.ShadowMessageAutoDiscardInterval
        InternalSMTPServers      = (ConvertTo-ExchFlatValue -Value $config.InternalSMTPServers)
        ExternalPostmasterAddress= [string]$config.ExternalPostmasterAddress
        TLSReceiveDomainSecureList = (ConvertTo-ExchFlatValue -Value $config.TLSReceiveDomainSecureList)
        TLSSendDomainSecureList  = (ConvertTo-ExchFlatValue -Value $config.TLSSendDomainSecureList)
    }

    $serviceRows = foreach ($svc in $services) {
        [pscustomobject]@{
            Server                    = [string]$svc.Name
            MessageTrackingLogEnabled = (ConvertTo-ExchFlatValue -Value $svc.MessageTrackingLogEnabled)
            MessageTrackingLogPath    = [string]$svc.MessageTrackingLogPath
            MessageTrackingLogMaxAge  = [string]$svc.MessageTrackingLogMaxAge
            ConnectivityLogEnabled    = (ConvertTo-ExchFlatValue -Value $svc.ConnectivityLogEnabled)
            ReceiveProtocolLogPath    = [string]$svc.ReceiveProtocolLogPath
            SendProtocolLogPath       = [string]$svc.SendProtocolLogPath
            MaxConcurrentMailboxDeliveries = [string]$svc.MaxConcurrentMailboxDeliveries
            QueueMaxIdleTime          = [string]$svc.QueueMaxIdleTime
            ExternalDNSAdapterEnabled = (ConvertTo-ExchFlatValue -Value $svc.ExternalDNSAdapterEnabled)
        }
    }

    $frontendRows = foreach ($fe in $frontend) {
        [pscustomobject]@{
            Server                 = [string]$fe.Name
            ConnectivityLogEnabled = (ConvertTo-ExchFlatValue -Value $fe.ConnectivityLogEnabled)
            ReceiveProtocolLogPath = [string]$fe.ReceiveProtocolLogPath
            SendProtocolLogPath    = [string]$fe.SendProtocolLogPath
            ExternalDNSAdapterEnabled = (ConvertTo-ExchFlatValue -Value $fe.ExternalDNSAdapterEnabled)
        }
    }

    $ruleRows = foreach ($rule in $rules) {
        [pscustomobject]@{
            Name        = [string]$rule.Name
            State       = [string]$rule.State
            Mode        = [string]$rule.Mode
            Priority    = [string]$rule.Priority
            Description = (Get-ExchTruncatedText -Text ([string]$rule.Description) -Length 512)
            RedirectsMessage = ((([string]$rule.Description) -match 'redirect|forward|blind carbon copy|Bcc') -or ([string]$rule.Name -match 'redirect|forward'))
        }
    }

    $journalRows = foreach ($j in $journal) {
        [pscustomobject]@{
            Name             = [string]$j.Name
            Enabled          = [bool]$j.Enabled
            Scope            = [string]$j.Scope
            Recipient        = [string]$j.Recipient
            JournalEmailAddress = [string]$j.JournalEmailAddress
        }
    }

    $serviceArr  = @($serviceRows)
    $frontendArr = @($frontendRows)
    $ruleArr     = @($ruleRows)
    $journalArr  = @($journalRows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'transport/configuration.json' -ContentObject ([ordered]@{
        transportConfig   = $configRow
        transportServices = $serviceArr
        frontendServices  = $frontendArr
        transportRules    = $ruleArr
        journalRules      = $journalArr
        errors            = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'transport.configuration' -Title 'Organisation Transport Configuration' -Area 'Transport' `
            -Columns @('MaxReceiveSize', 'MaxSendSize', 'MaxRecipientEnvelopeLimit', 'ShadowRedundancyEnabled', 'SafetyNetHoldTime', 'SafetyNetHoldTimeHours', 'ShadowMessageAutoDiscardInterval', 'InternalSMTPServers', 'ExternalPostmasterAddress', 'TLSReceiveDomainSecureList', 'TLSSendDomainSecureList') `
            -Rows @($configRow)

        New-ExchInventorySection -Run $Run -Key 'transport.services' -Title 'Transport Services' -Area 'Transport' `
            -Columns @('Server', 'MessageTrackingLogEnabled', 'MessageTrackingLogPath', 'MessageTrackingLogMaxAge', 'ConnectivityLogEnabled', 'ReceiveProtocolLogPath', 'SendProtocolLogPath', 'MaxConcurrentMailboxDeliveries', 'QueueMaxIdleTime', 'ExternalDNSAdapterEnabled') `
            -Rows $serviceArr

        New-ExchInventorySection -Run $Run -Key 'transport.frontend-services' -Title 'Frontend Transport Services' -Area 'Transport' `
            -Columns @('Server', 'ConnectivityLogEnabled', 'ReceiveProtocolLogPath', 'SendProtocolLogPath', 'ExternalDNSAdapterEnabled') `
            -Rows $frontendArr

        New-ExchInventorySection -Run $Run -Key 'transport.rules' -Title 'Transport Rules' -Area 'Transport' `
            -Columns @('Name', 'State', 'Mode', 'Priority', 'RedirectsMessage', 'Description') `
            -Rows $ruleArr -HighCardinality

        New-ExchInventorySection -Run $Run -Key 'transport.journal-rules' -Title 'Journal Rules' -Area 'Transport' `
            -Columns @('Name', 'Enabled', 'Scope', 'Recipient', 'JournalEmailAddress') `
            -Rows $journalArr
    )

    $requireShadow  = [bool](Get-ExchThreshold -Run $Run -Name 'Transport.RequireShadowRedundancy' -Default $true)
    $requireSafety  = [bool](Get-ExchThreshold -Run $Run -Name 'Transport.RequireSafetyNet' -Default $true)
    $minSafetyHours = [double](Get-ExchThreshold -Run $Run -Name 'Transport.MinSafetyNetHoldTimeHours' -Default 2)

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($requireShadow -and -not $shadowEnabled) {
        $problems.Add('Shadow redundancy is disabled, so mail in transit is lost if a transport server fails before delivery') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($requireSafety -and $null -ne $safetyNetHours -and $safetyNetHours -lt $minSafetyHours) {
        $problems.Add(("Safety Net hold time is {0} hours, below the {1} hour minimum, which shortens the window for resubmitting mail after a failure" -f $safetyNetHours, $minSafetyHours)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $redirecting = @($ruleArr | Where-Object { $_.State -eq 'Enabled' -and $_.RedirectsMessage })
    if ($redirecting.Count -gt 0) {
        $problems.Add(("{0} enabled transport rules appear to redirect, forward or blind-copy mail and are worth confirming as intended: {1}" -f `
            $redirecting.Count, (($redirecting | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    # Compare against $false, not the string 'False': PowerShell coerces the right side of an
    # -eq to the left side's type, and every non-empty string is a true boolean.
    $noTracking = @($serviceArr | Where-Object { $_.MessageTrackingLogEnabled -eq $false })
    if ($noTracking.Count -gt 0) {
        $problems.Add(("Message tracking is disabled on {0} servers, so mail flow cannot be traced after the fact: {1}" -f `
            $noTracking.Count, (($noTracking | ForEach-Object { $_.Server }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($errors.Count -gt 0) {
        $problems.Add(("Some transport configuration could not be read: {0}" -f ($errors -join '; '))) | Out-Null
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
                 else { ("Shadow redundancy and Safety Net are configured, message tracking is on across {0} transport services, and {1} transport rules and {2} journal rules are in place." -f `
                        $serviceArr.Count, $ruleArr.Count, $journalArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Enable shadow redundancy and keep Safety Net at or above the configured hold time, leave message tracking enabled on every transport server, and review each rule that redirects or copies mail against what the business actually asked for.' `
        -Metrics @{
            shadowRedundancyEnabled = $shadowEnabled
            safetyNetHoldTimeHours  = $safetyNetHours
            transportServices       = $serviceArr.Count
            transportRules          = $ruleArr.Count
            enabledRedirectingRules = $redirecting.Count
            journalRules            = $journalArr.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchTruncatedText {
    <#
    Caps a free-text field so one verbose transport rule cannot dominate the report.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$Text,
        [Parameter()][int]$Length = 512
    )

    if (-not $Text) { return '' }
    $single = ($Text -replace '\s+', ' ').Trim()
    if ($single.Length -le $Length) { return $single }
    return ($single.Substring(0, $Length) + '...')
}

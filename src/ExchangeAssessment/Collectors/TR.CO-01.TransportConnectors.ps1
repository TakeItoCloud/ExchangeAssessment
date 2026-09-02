<#
TR.CO-01 - Send and receive connector posture.

The open-relay check is deliberately not "anonymous plus a wide remote range". Microsoft's own
`Default Frontend <ServerName>` connector, created by setup on every Mailbox server, is exactly
that shape: PermissionGroups includes AnonymousUsers and RemoteIPRanges covers the whole IPv4
and IPv6 space. Treating that as an open relay makes the control fire on every correctly built
organisation, which is worse than not having the control.

The Anonymous users permission group maps to NT AUTHORITY\ANONYMOUS LOGON and grants
accept-any-sender, accept-authoritative-domain-sender, accept-headers-routing and submit. It
does NOT grant ms-Exch-SMTP-Accept-Any-Recipient, which is the right that actually lets a client
relay to an external recipient. Relay is therefore granted by one of two configurations only:

  a. the Anonymous users permission group AND ms-Exch-SMTP-Accept-Any-Recipient granted
     explicitly to an anonymous principal on that connector; or
  b. the ExchangeServers permission group combined with the ExternalAuthoritative ("externally
     secured") authentication mechanism, which hands that right to the externally secured
     servers principal.

So each receive connector's permissions are read with Get-ADPermission and the answer is
three-state - Granted, NotGranted or Unknown. A connector whose permissions could not be read is
reported as not assessable, never as clean: the point of the control is to be able to say open
relay was ruled out, and a failed read cannot say that.

TLS level, authentication mechanism and message size limits are evaluated rather than merely
recorded.

Every property this control judges on is presence-checked before it is judged. A connector that
did not return one of them is reported as not assessable, naming the property, rather than
having a default stand in for it - a missing PermissionGroups defaulting to empty would turn a
real open relay into a pass, and a missing RequireTLS defaulting to false would invent a finding
nothing measured.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_TR_CO_01_TransportConnectors {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'TR.CO-01'

    $sendErr = ''
    $recvErr = ''
    $send = @()
    $receive = @()

    try { $send = @(Get-SendConnector -ErrorAction Stop) }
    catch {
        $sendErr = [string]$_.Exception.Message
        $null = Write-ExchError -Run $Run -Context 'Get-SendConnector' -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
    }

    try { $receive = @(Get-ReceiveConnector -ErrorAction Stop) }
    catch {
        $recvErr = [string]$_.Exception.Message
        $null = Write-ExchError -Run $Run -Context 'Get-ReceiveConnector' -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
    }

    if ($sendErr -and $recvErr) {
        $reason = "Neither send nor receive connectors could be read. Send: $sendErr. Receive: $recvErr."
        Write-ExchEvent -Run $Run -Level ERROR -Message 'Connector queries failed' -Data @{ sendError = $sendErr; receiveError = $recvErr }
        # Both queries already recorded their own detail below; this line names the combined failure.
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason `
                -Remediation 'Run from an Exchange Management Shell with rights to read transport connectors.'
        )
    }

    $anonymousGroups   = @(Get-ExchThreshold -Run $Run -Name 'Transport.AnonymousPermissionGroups' -Default @('AnonymousUsers'))
    $unrestricted      = @(Get-ExchThreshold -Run $Run -Name 'Transport.UnrestrictedRemoteRanges'  -Default @())
    $requiredTlsLevels = @(Get-ExchThreshold -Run $Run -Name 'Transport.RequiredSendTlsAuthLevels' -Default @())
    $discouragedAuth   = @(Get-ExchThreshold -Run $Run -Name 'Transport.DiscouragedAuthMechanisms' -Default @())
    $anonymousPrincipals = @(Get-ExchThreshold -Run $Run -Name 'Transport.AnonymousSecurityPrincipals' -Default @('NT AUTHORITY\ANONYMOUS LOGON', 'ANONYMOUS LOGON'))
    $relayPermission   = [string](Get-ExchThreshold -Run $Run -Name 'Transport.RelayPermission' -Default 'ms-Exch-SMTP-Accept-Any-Recipient')
    $securedMechanism  = [string](Get-ExchThreshold -Run $Run -Name 'Transport.ExternallySecuredAuthMechanism'   -Default 'ExternalAuthoritative')
    $securedGroup      = [string](Get-ExchThreshold -Run $Run -Name 'Transport.ExternallySecuredPermissionGroup' -Default 'ExchangeServers')

    # The properties each verdict depends on. Anything not on these lists is inventory: an
    # unreadable inventory field is a blank cell, an unreadable judged field is an Unknown.
    $judgedSendProperties    = @('Enabled', 'AddressSpaces', 'TlsAuthLevel')
    $judgedReceiveProperties = @('Enabled', 'PermissionGroups', 'AuthMechanism', 'RemoteIPRanges', 'RequireTLS')

    $sendRows = New-Object System.Collections.Generic.List[object]
    foreach ($c in $send) {
        $addressSpaces = ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $c -Name 'AddressSpaces')
        $tlsLevel = [string](Get-ExchObjectValue -InputObject $c -Name 'TlsAuthLevel' -Default '')
        $toInternet = ($addressSpaces -match '(^|;)(SMTP:)?\*(;|:|$)')

        $sendUnreadable = Get-ExchMissingProperty -InputObject $c -Name $judgedSendProperties

        $sendRows.Add([pscustomobject]@{
            Name           = [string](Get-ExchObjectValue -InputObject $c -Name 'Name' -Default '')
            Enabled        = [bool](Get-ExchObjectValue -InputObject $c -Name 'Enabled' -Default $false)
            AddressSpaces  = $addressSpaces
            ToInternet     = $toInternet
            DNSRoutingEnabled = [bool](Get-ExchObjectValue -InputObject $c -Name 'DNSRoutingEnabled' -Default $false)
            SmartHosts     = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $c -Name 'SmartHosts'))
            TlsAuthLevel   = $tlsLevel
            RequireTLS     = [bool](Get-ExchObjectValue -InputObject $c -Name 'RequireTLS' -Default $false)
            TlsDomain      = [string](Get-ExchObjectValue -InputObject $c -Name 'TlsDomain' -Default '')
            SourceTransportServers = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $c -Name 'SourceTransportServers'))
            MaxMessageSize = [string](Get-ExchObjectValue -InputObject $c -Name 'MaxMessageSize' -Default '')
            Fqdn           = [string](Get-ExchObjectValue -InputObject $c -Name 'Fqdn' -Default '')
            UnreadableProperties = $sendUnreadable
            Assessable     = [bool](-not $sendUnreadable)
        }) | Out-Null
    }

    $permissionErrors = New-Object System.Collections.Generic.List[string]
    $receiveRows = New-Object System.Collections.Generic.List[object]
    foreach ($c in $receive) {
        $relayRight = Test-ExchAnonymousRelayGranted -Connector $c -Run $Run -Errors $permissionErrors `
            -ControlId $control.controlId -AnonymousPrincipals $anonymousPrincipals -RelayPermission $relayPermission

        $receiveRows.Add((New-ExchReceiveConnectorRow -Connector $c -AnonymousGroups $anonymousGroups `
            -KnownUnrestricted $unrestricted -AnonymousRelayRight $relayRight `
            -ExternallySecuredGroup $securedGroup -ExternallySecuredMechanism $securedMechanism `
            -JudgedProperties $judgedReceiveProperties)) | Out-Null
    }

    $sendArr = @($sendRows.ToArray())
    $recvArr = @($receiveRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'transport/connectors.json' -ContentObject ([ordered]@{
        send             = $sendArr
        receive          = $recvArr
        sendError        = $sendErr
        receiveError     = $recvErr
        permissionErrors = @($permissionErrors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'transport.send-connectors' -Title 'Send Connectors' -Area 'Transport' `
            -Columns @('Name', 'Enabled', 'AddressSpaces', 'ToInternet', 'DNSRoutingEnabled', 'SmartHosts', 'TlsAuthLevel', 'RequireTLS', 'TlsDomain', 'SourceTransportServers', 'MaxMessageSize', 'Fqdn', 'Assessable', 'UnreadableProperties') `
            -Rows $sendArr

        New-ExchInventorySection -Run $Run -Key 'transport.receive-connectors' -Title 'Receive Connectors' -Area 'Transport' `
            -Columns @('Name', 'Server', 'Enabled', 'Bindings', 'RemoteIPRanges', 'PermissionGroups', 'AuthMechanism', 'Fqdn', 'RequireTLS', 'MaxMessageSize', 'RequireEHLODomain', 'AllowsAnonymous', 'UnrestrictedRange', 'AnonymousRelayRight', 'ExternallySecured', 'RelayAssessable', 'UnreadableProperties', 'OpenRelay') `
            -Rows $recvArr
    )

    $relay = Get-ExchRelayAssessment -Rows $recvArr

    # Only connectors that returned every property the test needs are judged. The rest are
    # counted as Unknown below, naming what was missing.
    $sendUnassessable = @($sendArr | Where-Object { -not $_.Assessable })
    $noTls = @($sendArr | Where-Object { $_.Assessable -and $_.Enabled -and $_.ToInternet -and $requiredTlsLevels.Count -gt 0 -and ($requiredTlsLevels -notcontains $_.TlsAuthLevel) })
    $basicAuth = @($recvArr | Where-Object {
        $row = $_
        -not $row.UnreadableProperties -and $row.Enabled -and
        @($discouragedAuth | Where-Object { $row.AuthMechanism -match [regex]::Escape($_) }).Count -gt 0 -and -not $row.RequireTLS
    })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    foreach ($problem in @($relay.Problems)) { $problems.Add($problem) | Out-Null }
    foreach ($verdict in @($relay.Outcomes)) { $outcomes.Add($verdict) | Out-Null }

    if ($basicAuth.Count -gt 0) {
        $problems.Add(("{0} receive connectors offer a discouraged authentication mechanism without requiring TLS, so credentials cross the wire unprotected: {1}" -f $basicAuth.Count, `
            (($basicAuth | ForEach-Object { "$($_.Server)\$($_.Name)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($noTls.Count -gt 0) {
        $problems.Add(("{0} internet send connectors do not require TLS (TlsAuthLevel is {1}): {2}" -f $noTls.Count, `
            (($noTls | ForEach-Object { if ($_.TlsAuthLevel) { $_.TlsAuthLevel } else { 'unset' } } | Sort-Object -Unique) -join '/'), `
            (($noTls | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($sendUnassessable.Count -gt 0) {
        $problems.Add(("{0} send connectors did not return every property this control judges on, so they were not assessed: {1}" -f `
            $sendUnassessable.Count, (($sendUnassessable | ForEach-Object { "$($_.Name) (missing $($_.UnreadableProperties))" }) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($sendErr) { $problems.Add("Send connectors could not be read: $sendErr") | Out-Null; $outcomes.Add('Unknown') | Out-Null }
    if ($recvErr) { $problems.Add("Receive connectors could not be read: $recvErr") | Out-Null; $outcomes.Add('Unknown') | Out-Null }
    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Medium' }
        'Unknown'            { 'Medium' }
        default              { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else {
                     ("{0} send and {1} receive connectors were checked: no receive connector grants {2} to an anonymous or externally secured principal, and internet send connectors require TLS." -f `
                         $sendArr.Count, $recvArr.Count, $relayPermission)
                 }

    $degraded = ($sendErr -or $recvErr -or $relay.Sufficiency -eq 'SoftFail' -or $sendUnassessable.Count -gt 0)
    $stateReason = @(@($sendErr, $recvErr) + @($permissionErrors.ToArray()) | Where-Object { $_ }) -join '; '

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($degraded) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation ("Grant {0} only to the specific application IP addresses that need to relay, on a dedicated connector rather than the default frontend one. Require TLS on internet send connectors, and require TLS wherever Basic authentication is still offered. Where the relay permission could not be read, re-run with an account that can run Get-ADPermission against receive connectors." -f $relayPermission) `
        -Metrics @{
            sendConnectors    = $sendArr.Count
            receiveConnectors = $recvArr.Count
            openRelays        = @($relay.OpenRelays).Count
            unassessableRelay = @($relay.Unassessable).Count
            unassessableSend  = $sendUnassessable.Count
            sendWithoutTls    = $noTls.Count
            basicWithoutTls   = $basicAuth.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($degraded) { 'Partial' } else { 'Success' }); reason = $stateReason } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function New-ExchReceiveConnectorRow {
    <#
    Projects one receive connector onto the inventory row, including the open-relay verdict.

    AllowsAnonymous and UnrestrictedRange stay as columns because they are useful facts about a
    connector. They are simply not a verdict: Microsoft's default frontend connector has both.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Connector,
        [Parameter()][string[]]$AnonymousGroups = @(),
        [Parameter()][string[]]$KnownUnrestricted = @(),
        [Parameter(Mandatory)][ValidateSet('Granted', 'NotGranted', 'Unknown')][string]$AnonymousRelayRight,
        [Parameter()][string]$ExternallySecuredGroup = 'ExchangeServers',
        [Parameter()][string]$ExternallySecuredMechanism = 'ExternalAuthoritative',
        # The properties the relay and TLS verdicts read. A connector missing any of them is
        # not assessable, because the default that stands in for the missing value would decide
        # the verdict on its own.
        [Parameter()][string[]]$JudgedProperties = @('Enabled', 'PermissionGroups', 'AuthMechanism', 'RemoteIPRanges', 'RequireTLS')
    )

    $unreadable = Get-ExchMissingProperty -InputObject $Connector -Name $JudgedProperties

    $permissionGroups = ConvertTo-ExchEnumName -Value (Get-ExchObjectValue -InputObject $Connector -Name 'PermissionGroups') `
        -EnumType 'Microsoft.Exchange.Data.Directory.SystemConfiguration.PermissionGroups'
    $authMechanism = ConvertTo-ExchEnumName -Value (Get-ExchObjectValue -InputObject $Connector -Name 'AuthMechanism') `
        -EnumType 'Microsoft.Exchange.Data.Directory.SystemConfiguration.AuthMechanisms'

    $rangeProperty = $Connector.PSObject.Properties.Match('RemoteIPRanges') | Select-Object -First 1
    $ranges = if ($rangeProperty) { @($rangeProperty.Value | ForEach-Object { [string]$_ }) } else { @() }

    $allowsAnonymous = $false
    foreach ($group in @($AnonymousGroups)) {
        if (Test-ExchFlagPresent -Value $permissionGroups -Flag $group) { $allowsAnonymous = $true; break }
    }

    $enabled = [bool](Get-ExchObjectValue -InputObject $Connector -Name 'Enabled' -Default $false)
    $unrestrictedRange = Test-ExchUnrestrictedRange -Ranges $ranges -KnownUnrestricted $KnownUnrestricted
    $externallySecured = (Test-ExchFlagPresent -Value $permissionGroups -Flag $ExternallySecuredGroup) -and
                         (Test-ExchFlagPresent -Value $authMechanism    -Flag $ExternallySecuredMechanism)

    $relays = ($allowsAnonymous -and $AnonymousRelayRight -eq 'Granted') -or $externallySecured

    [pscustomobject]@{
        Name             = [string](Get-ExchObjectValue -InputObject $Connector -Name 'Name' -Default '')
        Server           = [string](Get-ExchObjectValue -InputObject $Connector -Name 'Server' -Default '')
        Enabled          = $enabled
        Bindings         = (ConvertTo-ExchFlatValue -Value (Get-ExchObjectValue -InputObject $Connector -Name 'Bindings'))
        RemoteIPRanges   = (ConvertTo-ExchFlatValue -Value $ranges)
        PermissionGroups = $permissionGroups
        AuthMechanism    = $authMechanism
        Fqdn             = [string](Get-ExchObjectValue -InputObject $Connector -Name 'Fqdn' -Default '')
        RequireTLS       = [bool](Get-ExchObjectValue -InputObject $Connector -Name 'RequireTLS' -Default $false)
        MaxMessageSize   = [string](Get-ExchObjectValue -InputObject $Connector -Name 'MaxMessageSize' -Default '')
        RequireEHLODomain= [bool](Get-ExchObjectValue -InputObject $Connector -Name 'RequireEHLODomain' -Default $false)
        AllowsAnonymous  = $allowsAnonymous
        UnrestrictedRange= $unrestrictedRange
        AnonymousRelayRight = $AnonymousRelayRight
        ExternallySecured= $externallySecured
        UnreadableProperties = $unreadable
        RelayAssessable  = (($AnonymousRelayRight -ne 'Unknown') -and -not $unreadable)
        OpenRelay        = ($enabled -and $unrestrictedRange -and $relays)
    }
}

function Get-ExchRelayAssessment {
    <#
    Turns receive-connector rows into the open-relay part of the finding.

    A connector that is anonymous and unrestricted but does not carry the relay permission is
    Microsoft's default build and is deliberately not reported as a problem. A connector whose
    permissions could not be read, or which did not return one of the properties the test reads,
    is reported as not assessable - an Unknown outcome and a SoftFail naming the connector and
    what was missing. Partial coverage must never read as a clean pass.
    #>
    [CmdletBinding()]
    param([Parameter()][object[]]$Rows = @())

    $openRelays   = @($Rows | Where-Object { $_.OpenRelay })
    $unassessable = @($Rows | Where-Object { -not $_.RelayAssessable })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($openRelays.Count -gt 0) {
        $detail = ($openRelays | ForEach-Object {
            $path = if ($_.ExternallySecured -and $_.AnonymousRelayRight -eq 'Granted') {
                'the externally secured ExchangeServers permission group, and the relay permission granted to an anonymous principal'
            }
            elseif ($_.ExternallySecured) {
                'the ExchangeServers permission group combined with externally secured authentication'
            }
            else {
                'the relay permission granted to an anonymous principal'
            }
            "{0}\{1} ({2})" -f $_.Server, $_.Name, $path
        }) -join ', '

        $problems.Add(("{0} enabled receive connectors relay from any address: {1}" -f $openRelays.Count, $detail)) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    $permissionUnread = @($unassessable | Where-Object { $_.AnonymousRelayRight -eq 'Unknown' })
    if ($permissionUnread.Count -gt 0) {
        $problems.Add(("The relay permission could not be read on {0} receive connectors, so open relay could not be ruled out on them: {1}" -f `
            $permissionUnread.Count, (($permissionUnread | ForEach-Object { "$($_.Server)\$($_.Name)" }) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    $propertyUnread = @($unassessable | Where-Object { $_.UnreadableProperties })
    if ($propertyUnread.Count -gt 0) {
        $problems.Add(("{0} receive connectors did not return every property this control judges on, so open relay could not be ruled out on them: {1}" -f `
            $propertyUnread.Count, (($propertyUnread | ForEach-Object { "$($_.Server)\$($_.Name) (missing $($_.UnreadableProperties))" }) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    return [pscustomobject]@{
        OpenRelays   = $openRelays
        Unassessable = $unassessable
        Problems     = @($problems.ToArray())
        Outcomes     = @($outcomes.ToArray())
        Sufficiency  = $(if ($unassessable.Count -gt 0) { 'SoftFail' } else { 'Pass' })
    }
}

function Test-ExchAnonymousRelayGranted {
    <#
    Answers, for one receive connector, whether an anonymous principal actually holds the relay
    permission - ms-Exch-SMTP-Accept-Any-Recipient.

    Three-state on purpose. Get-ADPermission needs rights the assessment account may not have,
    and it is not available against an Edge Transport server's AD LDS instance, so "the query
    failed" has to stay distinguishable from "the right is not there".

    The Deny/IsInherited filter is the one Microsoft documents for reading connector
    permissions: an inherited or denied entry does not grant the connector anything. An entry
    that does not carry Deny, IsInherited or User cannot be filtered on, so the whole answer
    becomes Unknown rather than a verdict resting on a default - treating an absent Deny as
    "allow" would invent a grant, and an absent User as "not anonymous" would hide one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Connector,
        [Parameter()]$Run,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors,
        [Parameter()][string]$ControlId = 'TR.CO-01',
        [Parameter()][string[]]$AnonymousPrincipals = @(),
        [Parameter()][string]$RelayPermission = 'ms-Exch-SMTP-Accept-Any-Recipient'
    )

    $identity = [string](Get-ExchObjectValue -InputObject $Connector -Name 'Identity' -Default '')
    if (-not $identity) { $identity = [string](Get-ExchObjectValue -InputObject $Connector -Name 'Name' -Default '') }
    if (-not $identity) {
        $Errors.Add('A receive connector carried neither an Identity nor a Name, so its relay permission could not be read.') | Out-Null
        return 'Unknown'
    }

    $before = $Errors.Count
    $permissions = @(Invoke-ExchQuery -Label ("Get-ADPermission on receive connector {0}" -f $identity) `
        -Errors $Errors -Run $Run -ControlId $ControlId `
        -Script { Get-ADPermission -Identity $identity -ErrorAction Stop })

    # Invoke-ExchQuery returns an empty collection on failure, which is also what a connector
    # with no explicit permissions returns. The error list is what tells the two apart.
    if ($Errors.Count -gt $before) { return 'Unknown' }

    foreach ($entry in $permissions) {
        $missing = Get-ExchMissingProperty -InputObject $entry -Name @('Deny', 'IsInherited', 'User')
        if ($missing) {
            $Errors.Add(("Get-ADPermission on receive connector {0}: an access control entry did not carry {1}, so the relay permission could not be judged." -f $identity, $missing)) | Out-Null
            return 'Unknown'
        }

        if ([bool](Get-ExchObjectValue -InputObject $entry -Name 'Deny' -Default $false)) { continue }
        if ([bool](Get-ExchObjectValue -InputObject $entry -Name 'IsInherited' -Default $false)) { continue }

        $user = [string](Get-ExchObjectValue -InputObject $entry -Name 'User' -Default '')
        if (-not (Test-ExchPrincipalMatch -User $user -Principals $AnonymousPrincipals)) { continue }

        $rightsProperty = $entry.PSObject.Properties.Match('ExtendedRights') | Select-Object -First 1
        if (-not $rightsProperty) { continue }
        foreach ($right in @($rightsProperty.Value)) {
            if ([string]$right -ieq $RelayPermission) { return 'Granted' }
        }
    }

    return 'NotGranted'
}

function Test-ExchPrincipalMatch {
    <#
    True when a permission entry's User names one of the configured principals. Matches the
    whole value and the part after the last backslash, so both 'NT AUTHORITY\ANONYMOUS LOGON'
    and a bare 'ANONYMOUS LOGON' resolve the same way.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$User = '',
        [Parameter()][string[]]$Principals = @()
    )

    if (-not $User) { return $false }
    $trimmed = $User.Trim()
    $leaf = ($trimmed -split '\\')[-1]

    foreach ($principal in @($Principals)) {
        if (-not $principal) { continue }
        $candidate = $principal.Trim()
        if ($trimmed -ieq $candidate) { return $true }
        if ($leaf -ieq (($candidate -split '\\')[-1])) { return $true }
    }

    return $false
}

function Test-ExchFlagPresent {
    <#
    True when a flattened enum-flag or permission-group string names the given flag.

    Compares whole tokens rather than substrings, so ExchangeLegacyServers is never mistaken for
    ExchangeServers.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$Value = '',
        [Parameter()][string]$Flag = ''
    )

    if (-not $Value -or -not $Flag) { return $false }

    foreach ($token in ($Value -split '[;,]')) {
        if ($token.Trim() -ieq $Flag.Trim()) { return $true }
    }

    return $false
}

function Test-ExchUnrestrictedRange {
    <#
    True when any remote IP range covers the whole address space.

    Matches the configured literal forms and, independently, the shape of a full range, so a
    connector written as 0.0.0.0/0 is caught the same as 0.0.0.0-255.255.255.255. On its own
    this is not a finding - Microsoft's default frontend connector listens on exactly this
    range - it is one of the two conditions an open relay needs.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string[]]$Ranges = @(),
        [Parameter()][string[]]$KnownUnrestricted = @()
    )

    foreach ($range in @($Ranges)) {
        if (-not $range) { continue }
        $value = $range.Trim()

        if ($KnownUnrestricted -contains $value) { return $true }
        # Any /0 prefix, IPv4 or IPv6.
        if ($value -match '/0\s*$') { return $true }
        # A dash range spanning the entire IPv4 space.
        if ($value -replace '\s', '' -eq '0.0.0.0-255.255.255.255') { return $true }
        # A dash range spanning the entire IPv6 space.
        if (($value -replace '\s', '') -match '^::-(ffff:){7}ffff$') { return $true }
    }

    return $false
}

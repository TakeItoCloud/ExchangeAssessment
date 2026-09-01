<#
TR.CO-01 - Send and receive connector posture.

The open-relay test matches on the shape of the range rather than one literal string, so
0.0.0.0/0 and ::/0 are caught alongside 0.0.0.0-255.255.255.255. TLS level, authentication
mechanism and message size limits are evaluated rather than merely recorded.
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

    $sendRows = New-Object System.Collections.Generic.List[object]
    foreach ($c in $send) {
        $addressSpaces = ConvertTo-ExchFlatValue -Value $c.AddressSpaces
        $tlsLevel = [string]$c.TlsAuthLevel
        $toInternet = ($addressSpaces -match '(^|;)(SMTP:)?\*(;|:|$)')

        $sendRows.Add([pscustomobject]@{
            Name           = [string]$c.Name
            Enabled        = [bool]$c.Enabled
            AddressSpaces  = $addressSpaces
            ToInternet     = $toInternet
            DNSRoutingEnabled = [bool]$c.DNSRoutingEnabled
            SmartHosts     = (ConvertTo-ExchFlatValue -Value $c.SmartHosts)
            TlsAuthLevel   = $tlsLevel
            RequireTLS     = [bool]$c.RequireTLS
            TlsDomain      = [string]$c.TlsDomain
            SourceTransportServers = (ConvertTo-ExchFlatValue -Value $c.SourceTransportServers)
            MaxMessageSize = [string]$c.MaxMessageSize
            Fqdn           = [string]$c.Fqdn
        }) | Out-Null
    }

    $receiveRows = New-Object System.Collections.Generic.List[object]
    foreach ($c in $receive) {
        $permissionGroups = ConvertTo-ExchEnumName -Value $c.PermissionGroups -EnumType 'Microsoft.Exchange.Data.Directory.SystemConfiguration.PermissionGroups'
        $authMechanism    = ConvertTo-ExchEnumName -Value $c.AuthMechanism    -EnumType 'Microsoft.Exchange.Data.Directory.SystemConfiguration.AuthMechanisms'
        $ranges           = @($c.RemoteIPRanges | ForEach-Object { [string]$_ })

        $allowsAnonymous = $false
        foreach ($group in $anonymousGroups) {
            if ($permissionGroups -match [regex]::Escape($group)) { $allowsAnonymous = $true; break }
        }
        $unrestrictedRange = Test-ExchUnrestrictedRange -Ranges $ranges -KnownUnrestricted $unrestricted

        $receiveRows.Add([pscustomobject]@{
            Name             = [string]$c.Name
            Server           = [string]$c.Server
            Enabled          = [bool]$c.Enabled
            Bindings         = (ConvertTo-ExchFlatValue -Value $c.Bindings)
            RemoteIPRanges   = (ConvertTo-ExchFlatValue -Value $ranges)
            PermissionGroups = $permissionGroups
            AuthMechanism    = $authMechanism
            Fqdn             = [string]$c.Fqdn
            RequireTLS       = [bool]$c.RequireTLS
            MaxMessageSize   = [string]$c.MaxMessageSize
            RequireEHLODomain= [bool]$c.RequireEHLODomain
            AllowsAnonymous  = $allowsAnonymous
            UnrestrictedRange= $unrestrictedRange
            OpenRelay        = ($allowsAnonymous -and $unrestrictedRange)
        }) | Out-Null
    }

    $sendArr = @($sendRows.ToArray())
    $recvArr = @($receiveRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'transport/connectors.json' -ContentObject ([ordered]@{
        send         = $sendArr
        receive      = $recvArr
        sendError    = $sendErr
        receiveError = $recvErr
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'transport.send-connectors' -Title 'Send Connectors' -Area 'Transport' `
            -Columns @('Name', 'Enabled', 'AddressSpaces', 'ToInternet', 'DNSRoutingEnabled', 'SmartHosts', 'TlsAuthLevel', 'RequireTLS', 'TlsDomain', 'SourceTransportServers', 'MaxMessageSize', 'Fqdn') `
            -Rows $sendArr

        New-ExchInventorySection -Run $Run -Key 'transport.receive-connectors' -Title 'Receive Connectors' -Area 'Transport' `
            -Columns @('Name', 'Server', 'Enabled', 'Bindings', 'RemoteIPRanges', 'PermissionGroups', 'AuthMechanism', 'Fqdn', 'RequireTLS', 'MaxMessageSize', 'RequireEHLODomain', 'AllowsAnonymous', 'UnrestrictedRange', 'OpenRelay') `
            -Rows $recvArr
    )

    $openRelays = @($recvArr | Where-Object { $_.OpenRelay -and $_.Enabled })
    $noTls      = @($sendArr | Where-Object { $_.Enabled -and $_.ToInternet -and $requiredTlsLevels.Count -gt 0 -and ($requiredTlsLevels -notcontains $_.TlsAuthLevel) })
    $basicAuth  = @($recvArr | Where-Object {
        $row = $_
        $row.Enabled -and @($discouragedAuth | Where-Object { $row.AuthMechanism -match [regex]::Escape($_) }).Count -gt 0 -and -not $row.RequireTLS
    })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($openRelays.Count -gt 0) {
        $problems.Add(("{0} receive connectors accept anonymous submission from any address, which is an open relay: {1}" -f $openRelays.Count, `
            (($openRelays | ForEach-Object { "$($_.Server)\$($_.Name)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
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
                 else { ("{0} send and {1} receive connectors were checked: none relay anonymously from unrestricted ranges, and internet send connectors require TLS." -f $sendArr.Count, $recvArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($sendErr -or $recvErr) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Scope anonymous relay connectors to the specific application IP addresses that need them, require TLS on internet send connectors, and require TLS wherever Basic authentication is still offered.' `
        -Metrics @{
            sendConnectors    = $sendArr.Count
            receiveConnectors = $recvArr.Count
            openRelays        = $openRelays.Count
            sendWithoutTls    = $noTls.Count
            basicWithoutTls   = $basicAuth.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($sendErr -or $recvErr) { 'Partial' } else { 'Success' }); reason = (@($sendErr, $recvErr) | Where-Object { $_ }) -join '; ' } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Test-ExchUnrestrictedRange {
    <#
    True when any remote IP range covers the whole address space.

    Matches the configured literal forms and, independently, the shape of a full range, so a
    connector written as 0.0.0.0/0 is caught the same as 0.0.0.0-255.255.255.255.
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

<#
EX.VDIR-01 - Client access virtual directories.

Covers all nine directory types plus Outlook Anywhere and the Autodiscover service connection
point, and evaluates what was previously only collected: a missing external URL, a URL that
differs between servers, plain HTTP, and Basic authentication exposed to clients.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_EX_VDIR_01_VirtualDirectories {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'EX.VDIR-01'

    $errors = New-Object System.Collections.Generic.List[string]

    # Each directory type is read per server. Without -Server a Get-*VirtualDirectory cmdlet
    # reads IIS on every server in the organisation and fails as a whole when one server does not
    # answer - on the first live run one unreachable member failed all nine reads, and with them
    # the servers that did answer, including the one the assessment ran on. Read per server, an
    # unreachable server costs only its own rows, and the reads table says which were not read.
    $sources = @(
        @{ Type = 'owa';          Cmdlet = 'Get-OwaVirtualDirectory' }
        @{ Type = 'ecp';          Cmdlet = 'Get-EcpVirtualDirectory' }
        @{ Type = 'ews';          Cmdlet = 'Get-WebServicesVirtualDirectory' }
        @{ Type = 'oab';          Cmdlet = 'Get-OabVirtualDirectory' }
        @{ Type = 'autodiscover'; Cmdlet = 'Get-AutodiscoverVirtualDirectory' }
        @{ Type = 'mapi';         Cmdlet = 'Get-MapiVirtualDirectory' }
        @{ Type = 'activesync';   Cmdlet = 'Get-ActiveSyncVirtualDirectory' }
        @{ Type = 'powershell';   Cmdlet = 'Get-PowerShellVirtualDirectory' }
    )

    # Client access runs on Mailbox servers (and ClientAccess servers on 2013). Edge Transport
    # servers have none. A server whose role was not returned is read rather than skipped.
    $serverErrors = New-Object System.Collections.Generic.List[string]
    $vdirServers = @(Invoke-ExchQuery -Label 'Get-ExchangeServer' -Errors $serverErrors -Run $Run -ControlId $control.controlId `
        -Script { Get-ExchangeServer -ErrorAction Stop } | ForEach-Object {
            $role = [string](Get-ExchObjectValue -InputObject $_ -Name 'ServerRole' -Default '')
            if (-not $role -or $role -match 'Mailbox|ClientAccess') { [string](Get-ExchObjectValue -InputObject $_ -Name 'Name' -Default '') }
        } | Where-Object { $_ })
    foreach ($e in $serverErrors) { $errors.Add($e) | Out-Null }

    # When the servers cannot be listed the reads fall back to one organisation-wide query per
    # type, as before - the report then carries whatever that returns, and the failure to list.
    $scopes = if ($vdirServers.Count -gt 0) { $vdirServers } else { @('') }

    $rows = New-Object System.Collections.Generic.List[object]
    $readRows = New-Object System.Collections.Generic.List[object]
    $outlookAnywhere = New-Object System.Collections.Generic.List[object]

    foreach ($scope in $scopes) {
        $scopeLabel = $(if ($scope) { " on $scope" } else { '' })

        foreach ($source in $sources) {
            $before = $errors.Count
            $cmdlet = $source.Cmdlet
            $found = @(Invoke-ExchQuery -Label ("virtual directory '{0}'{1}" -f $source.Type, $scopeLabel) -Errors $errors -Run $Run -ControlId $control.controlId -Script {
                if ($scope) { & $cmdlet -Server $scope -ErrorAction Stop } else { & $cmdlet -ErrorAction Stop }
            })
            $readRows.Add([pscustomobject]@{
                Server = $(if ($scope) { $scope } else { '(organisation)' }); Type = $source.Type
                Read   = ($errors.Count -eq $before); Returned = $found.Count
                Error  = $(if ($errors.Count -gt $before) { $errors[$errors.Count - 1] } else { '' })
            }) | Out-Null

            foreach ($vdir in $found) {
                $internal = [string](Get-ExchObjectValue -InputObject $vdir -Name 'InternalUrl' -Default '')
                $external = [string](Get-ExchObjectValue -InputObject $vdir -Name 'ExternalUrl' -Default '')
                $auth = Get-ExchVirtualDirectoryAuth -VirtualDirectory $vdir

                $rows.Add([pscustomobject]@{
                    Type            = $source.Type
                    Name            = [string](Get-ExchObjectValue -InputObject $vdir -Name 'Name' -Default '')
                    Server          = [string](Get-ExchObjectValue -InputObject $vdir -Name 'Server' -Default $scope)
                    InternalUrl     = $internal
                    ExternalUrl     = $external
                    InternalHttps   = ($internal -like 'https://*')
                    ExternalHttps   = ($external -like 'https://*')
                    Authentication  = $auth
                    BasicAuthentication = ($auth -match 'Basic')
                    WindowsAuthentication = ($auth -match 'Windows|Ntlm|Negotiate')
                }) | Out-Null
            }
        }

        $before = $errors.Count
        $oaFound = @(Invoke-ExchQuery -Label ("Get-OutlookAnywhere{0}" -f $scopeLabel) -Errors $errors -Run $Run -ControlId $control.controlId -Script {
            if ($scope) { Get-OutlookAnywhere -Server $scope -ErrorAction Stop } else { Get-OutlookAnywhere -ErrorAction Stop }
        })
        $readRows.Add([pscustomobject]@{
            Server = $(if ($scope) { $scope } else { '(organisation)' }); Type = 'outlookanywhere'
            Read   = ($errors.Count -eq $before); Returned = $oaFound.Count
            Error  = $(if ($errors.Count -gt $before) { $errors[$errors.Count - 1] } else { '' })
        }) | Out-Null
        foreach ($oa in $oaFound) {
            $outlookAnywhere.Add([pscustomobject]@{
                Server                = [string](Get-ExchObjectValue -InputObject $oa -Name 'ServerName' -Default $scope)
                ExternalHostname      = [string](Get-ExchObjectValue -InputObject $oa -Name 'ExternalHostname' -Default '')
                InternalHostname      = [string](Get-ExchObjectValue -InputObject $oa -Name 'InternalHostname' -Default '')
                ExternalClientsRequireSsl = (Get-ExchObjectBool -InputObject $oa -Name 'ExternalClientsRequireSsl')
                InternalClientsRequireSsl = (Get-ExchObjectBool -InputObject $oa -Name 'InternalClientsRequireSsl')
                ExternalClientAuthenticationMethod = [string](Get-ExchObjectValue -InputObject $oa -Name 'ExternalClientAuthenticationMethod' -Default '')
                InternalClientAuthenticationMethod = [string](Get-ExchObjectValue -InputObject $oa -Name 'InternalClientAuthenticationMethod' -Default '')
                IISAuthenticationMethods = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $oa -Name 'IISAuthenticationMethods'))
            }) | Out-Null
        }
    }

    $scpRows = New-Object System.Collections.Generic.List[object]
    foreach ($cas in @(Invoke-ExchQuery -Label 'Get-ClientAccessService' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-ClientAccessService -ErrorAction Stop })) {
        $scpRows.Add([pscustomobject]@{
            Server = [string](Get-ExchObjectValue -InputObject $cas -Name 'Name' -Default '')
            AutoDiscoverServiceInternalUri = [string](Get-ExchObjectValue -InputObject $cas -Name 'AutoDiscoverServiceInternalUri' -Default '')
            AutoDiscoverSiteScope          = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $cas -Name 'AutoDiscoverSiteScope'))
        }) | Out-Null
    }

    $vdirArr = @($rows.ToArray())
    $oaArr   = @($outlookAnywhere.ToArray())
    $scpArr  = @($scpRows.ToArray())
    $readArr = @($readRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'exchange/virtual-directories.json' -ContentObject ([ordered]@{
        virtualDirectories = $vdirArr
        outlookAnywhere    = $oaArr
        autodiscoverScp    = $scpArr
        reads              = $readArr
        errors             = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'exchange.virtual-directories' -Title 'Client Access Virtual Directories' -Area 'Exchange' `
            -Columns @('Type', 'Name', 'Server', 'InternalUrl', 'ExternalUrl', 'InternalHttps', 'ExternalHttps', 'Authentication', 'BasicAuthentication', 'WindowsAuthentication') `
            -Rows $vdirArr

        New-ExchInventorySection -Run $Run -Key 'exchange.outlook-anywhere' -Title 'Outlook Anywhere' -Area 'Exchange' `
            -Columns @('Server', 'InternalHostname', 'ExternalHostname', 'InternalClientsRequireSsl', 'ExternalClientsRequireSsl', 'InternalClientAuthenticationMethod', 'ExternalClientAuthenticationMethod', 'IISAuthenticationMethods') `
            -Rows $oaArr

        New-ExchInventorySection -Run $Run -Key 'exchange.autodiscover-scp' -Title 'Autodiscover Service Connection Points' -Area 'Exchange' `
            -Columns @('Server', 'AutoDiscoverServiceInternalUri', 'AutoDiscoverSiteScope') `
            -Rows $scpArr

        New-ExchInventorySection -Run $Run -Key 'exchange.virtual-directory-reads' -Title 'Virtual Directory Reads per Server' -Area 'Exchange' `
            -Columns @('Server', 'Type', 'Read', 'Returned', 'Error') `
            -Rows $readArr
    )

    if ($vdirArr.Count -eq 0) {
        return New-ExchCollectorResult -Sections $sections -Findings @(
            New-ExchUnavailableFinding -Control $control `
                -Reason ("No virtual directories could be read, so client access configuration was not assessed: {0}" -f ($errors -join '; ')) `
                -Remediation 'Run from an Exchange Management Shell with rights to read client access virtual directories.'
        )
    }

    $requireExternal = @(Get-ExchThreshold -Run $Run -Name 'VirtualDirectory.RequireExternalUrl' -Default @())
    $requireHttps    = [bool](Get-ExchThreshold -Run $Run -Name 'VirtualDirectory.RequireHttps' -Default $true)
    $flagBasic       = [bool](Get-ExchThreshold -Run $Run -Name 'VirtualDirectory.FlagBasicAuthentication' -Default $true)
    $requireConsistent = [bool](Get-ExchThreshold -Run $Run -Name 'VirtualDirectory.RequireConsistentUrls' -Default $true)

    $missingExternal = @($vdirArr | Where-Object { ($requireExternal -contains $_.Type) -and -not $_.ExternalUrl })
    # A type listed in HttpInternalUrlAllowedTypes has an HTTP internal URL by design (the
    # PowerShell directory, which the Exchange Management Shell reaches over HTTP with Kerberos);
    # its external URL is still judged.
    $httpInternalAllowed = @(Get-ExchThreshold -Run $Run -Name 'VirtualDirectory.HttpInternalUrlAllowedTypes' -Default @('powershell'))
    $plainHttp = @($vdirArr | Where-Object {
        $requireHttps -and (
            ($_.InternalUrl -and -not $_.InternalHttps -and ($httpInternalAllowed -notcontains $_.Type)) -or
            ($_.ExternalUrl -and -not $_.ExternalHttps))
    })
    $basicExposed = @($vdirArr | Where-Object { $flagBasic -and $_.BasicAuthentication -and $_.ExternalUrl })

    $inconsistent = @()
    if ($requireConsistent) {
        $inconsistent = @(
            $vdirArr | Where-Object { $_.ExternalUrl } | Group-Object -Property Type |
                Where-Object { @($_.Group | ForEach-Object { $_.ExternalUrl } | Sort-Object -Unique).Count -gt 1 } |
                ForEach-Object {
                    [pscustomobject]@{
                        Type = $_.Name
                        Urls = (($_.Group | ForEach-Object { $_.ExternalUrl } | Sort-Object -Unique) -join ', ')
                    }
                }
        )
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($missingExternal.Count -gt 0) {
        $problems.Add(("{0} virtual directories have no external URL set, so external clients cannot be directed to them: {1}" -f $missingExternal.Count, `
            (($missingExternal | ForEach-Object { "$($_.Server) $($_.Type)" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($plainHttp.Count -gt 0) {
        $problems.Add(("{0} virtual directories publish a plain HTTP URL: {1}" -f $plainHttp.Count, `
            (($plainHttp | ForEach-Object { "$($_.Server) $($_.Type)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($basicExposed.Count -gt 0) {
        $problems.Add(("{0} externally published virtual directories accept Basic authentication, which sends credentials in a reversible form: {1}" -f $basicExposed.Count, `
            (($basicExposed | ForEach-Object { "$($_.Server) $($_.Type)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($inconsistent.Count -gt 0) {
        $problems.Add(("{0} directory types present different external URLs across servers, which breaks namespace consistency: {1}" -f $inconsistent.Count, `
            (($inconsistent | ForEach-Object { "$($_.Type) -> $($_.Urls)" }) -join '; '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $noScp = @($scpArr | Where-Object { -not $_.AutoDiscoverServiceInternalUri })
    if ($noScp.Count -gt 0) {
        $problems.Add(("{0} servers have no Autodiscover service internal URI set, so domain-joined clients cannot discover their configuration: {1}" -f $noScp.Count, `
            (($noScp | ForEach-Object { $_.Server }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $unreadServers = @($readArr | Where-Object { -not $_.Read } | ForEach-Object { $_.Server } | Sort-Object -Unique)
    if ($unreadServers.Count -gt 0) {
        $problems.Add(("Virtual directories could not be read on {0} servers, so the judgements above cover only the servers that answered: {1}" -f `
            $unreadServers.Count, ($unreadServers -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
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
                 else { ("All {0} virtual directories across {1} servers publish HTTPS URLs, present a consistent external namespace, and do not expose Basic authentication externally." -f `
                        $vdirArr.Count, @($vdirArr | ForEach-Object { $_.Server } | Sort-Object -Unique).Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Set a consistent HTTPS external URL on every published virtual directory across all servers, set the Autodiscover service internal URI on each server, and replace Basic authentication with modern or Windows authentication on externally published directories.' `
        -Metrics @{
            virtualDirectories = $vdirArr.Count
            missingExternalUrl = $missingExternal.Count
            plainHttp          = $plainHttp.Count
            basicExposed       = $basicExposed.Count
            inconsistentTypes  = $inconsistent.Count
            serversWithoutScp  = $noScp.Count
            serversRead        = @($readArr | Where-Object { $_.Read } | ForEach-Object { $_.Server } | Sort-Object -Unique).Count
            serversUnread      = $unreadServers.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchVirtualDirectoryAuth {
    <#
    Collapses whichever authentication properties a virtual directory type exposes into one
    readable list. The property set differs per directory type, so each is probed rather than
    assumed.
    #>
    [CmdletBinding()]
    param([Parameter()]$VirtualDirectory)

    if ($null -eq $VirtualDirectory) { return '' }

    $parts = New-Object System.Collections.Generic.List[string]

    foreach ($flag in @('BasicAuthentication', 'WindowsAuthentication', 'DigestAuthentication', 'FormsAuthentication', 'OAuthAuthentication', 'AdfsAuthentication')) {
        $prop = $VirtualDirectory.PSObject.Properties.Match($flag) | Select-Object -First 1
        if ($prop -and $prop.Value -eq $true) { $parts.Add(($flag -replace 'Authentication$', '')) | Out-Null }
    }

    foreach ($list in @('IISAuthenticationMethods', 'InternalAuthenticationMethods', 'ExternalAuthenticationMethods')) {
        $prop = $VirtualDirectory.PSObject.Properties.Match($list) | Select-Object -First 1
        if (-not $prop -or $null -eq $prop.Value) { continue }
        $value = ConvertTo-ExchFlatValue -Value $prop.Value
        if ($value) { $parts.Add($value) | Out-Null }
    }

    return ((@($parts.ToArray()) | Sort-Object -Unique) -join ';')
}

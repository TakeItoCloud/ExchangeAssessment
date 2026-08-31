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

    $sources = @(
        @{ Type = 'owa';          Script = { Get-OwaVirtualDirectory -ErrorAction Stop } }
        @{ Type = 'ecp';          Script = { Get-EcpVirtualDirectory -ErrorAction Stop } }
        @{ Type = 'ews';          Script = { Get-WebServicesVirtualDirectory -ErrorAction Stop } }
        @{ Type = 'oab';          Script = { Get-OabVirtualDirectory -ErrorAction Stop } }
        @{ Type = 'autodiscover'; Script = { Get-AutodiscoverVirtualDirectory -ErrorAction Stop } }
        @{ Type = 'mapi';         Script = { Get-MapiVirtualDirectory -ErrorAction Stop } }
        @{ Type = 'activesync';   Script = { Get-ActiveSyncVirtualDirectory -ErrorAction Stop } }
        @{ Type = 'powershell';   Script = { Get-PowerShellVirtualDirectory -ErrorAction Stop } }
    )

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($source in $sources) {
        foreach ($vdir in @(Invoke-ExchQuery -Label ("virtual directory '{0}'" -f $source.Type) -Errors $errors -Script $source.Script)) {
            $internal = [string]$vdir.InternalUrl
            $external = [string]$vdir.ExternalUrl
            $auth = Get-ExchVirtualDirectoryAuth -VirtualDirectory $vdir

            $rows.Add([pscustomobject]@{
                Type            = $source.Type
                Name            = [string]$vdir.Name
                Server          = [string]$vdir.Server
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

    $outlookAnywhere = New-Object System.Collections.Generic.List[object]
    foreach ($oa in @(Invoke-ExchQuery -Label 'Get-OutlookAnywhere' -Errors $errors -Script { Get-OutlookAnywhere -ErrorAction Stop })) {
        $outlookAnywhere.Add([pscustomobject]@{
            Server                = [string]$oa.ServerName
            ExternalHostname      = [string]$oa.ExternalHostname
            InternalHostname      = [string]$oa.InternalHostname
            ExternalClientsRequireSsl = [bool]$oa.ExternalClientsRequireSsl
            InternalClientsRequireSsl = [bool]$oa.InternalClientsRequireSsl
            ExternalClientAuthenticationMethod = [string]$oa.ExternalClientAuthenticationMethod
            InternalClientAuthenticationMethod = [string]$oa.InternalClientAuthenticationMethod
            IISAuthenticationMethods = (ConvertTo-ExchFlatValue -Value $oa.IISAuthenticationMethods)
        }) | Out-Null
    }

    $scpRows = New-Object System.Collections.Generic.List[object]
    foreach ($cas in @(Invoke-ExchQuery -Label 'Get-ClientAccessService' -Errors $errors -Script { Get-ClientAccessService -ErrorAction Stop })) {
        $scpRows.Add([pscustomobject]@{
            Server = [string]$cas.Name
            AutoDiscoverServiceInternalUri = [string]$cas.AutoDiscoverServiceInternalUri
            AutoDiscoverSiteScope          = (ConvertTo-ExchFlatValue -Value $cas.AutoDiscoverSiteScope)
        }) | Out-Null
    }

    $vdirArr = @($rows.ToArray())
    $oaArr   = @($outlookAnywhere.ToArray())
    $scpArr  = @($scpRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'exchange/virtual-directories.json' -ContentObject ([ordered]@{
        virtualDirectories = $vdirArr
        outlookAnywhere    = $oaArr
        autodiscoverScp    = $scpArr
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
    $plainHttp = @($vdirArr | Where-Object {
        $requireHttps -and (($_.InternalUrl -and -not $_.InternalHttps) -or ($_.ExternalUrl -and -not $_.ExternalHttps))
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

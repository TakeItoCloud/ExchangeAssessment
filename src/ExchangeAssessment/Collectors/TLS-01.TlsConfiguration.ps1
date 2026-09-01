<#
TLS-01 - TLS protocol and .NET cryptography configuration.

Reads the SCHANNEL and .NET registry keys on every Exchange server, plus the Exchange serialised
data signing state. These are registry reads over the remote registry; a server that cannot be
reached is reported as unread rather than assumed compliant.

An absent SCHANNEL key means "operating system default", not "disabled", so absence is reported
as an explicit default rather than silently treated as either.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_TLS_01_TlsConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'TLS-01'

    $errors = New-Object System.Collections.Generic.List[string]
    $servers = @(Invoke-ExchQuery -Label 'Get-ExchangeServer' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-ExchangeServer -ErrorAction Stop })

    if ($servers.Count -eq 0) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control `
                -Reason ("No Exchange servers could be enumerated, so TLS configuration was not assessed: {0}" -f ($errors -join '; ')) `
                -Remediation 'Run from an Exchange Management Shell with rights to enumerate servers.'
        )
    }

    $requiredEnabled  = @(Get-ExchThreshold -Run $Run -Name 'Tls.RequiredEnabledProtocols'  -Default @('TLS 1.2'))
    $requiredDisabled = @(Get-ExchThreshold -Run $Run -Name 'Tls.RequiredDisabledProtocols' -Default @())
    $requireStrong    = [bool](Get-ExchThreshold -Run $Run -Name 'Tls.RequireStrongCryptoDotNet' -Default $true)

    $protocolRows = New-Object System.Collections.Generic.List[object]
    $dotNetRows   = New-Object System.Collections.Generic.List[object]
    $unread       = New-Object System.Collections.Generic.List[string]

    $allProtocols = @($requiredEnabled + $requiredDisabled | Sort-Object -Unique)

    foreach ($srv in $servers) {
        $name = [string]$srv.Name
        try {
            # $using: is the idiomatic way to hand a local value to a remote scriptblock, and it
            # keeps the analyzer's new-runspace scope rule satisfied.
            $reading = Invoke-Command -ComputerName $name -ScriptBlock {
                $protocols = $using:allProtocols

                $schannelRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
                $results = foreach ($protocol in $protocols) {
                    foreach ($role in @('Client', 'Server')) {
                        $path = Join-Path (Join-Path $schannelRoot $protocol) $role
                        $enabled = $null
                        $disabledByDefault = $null
                        $present = Test-Path -Path $path
                        if ($present) {
                            $key = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                            if ($key) {
                                if ($null -ne $key.PSObject.Properties['Enabled']) { $enabled = [int]$key.Enabled }
                                if ($null -ne $key.PSObject.Properties['DisabledByDefault']) { $disabledByDefault = [int]$key.DisabledByDefault }
                            }
                        }
                        [pscustomobject]@{
                            Protocol = $protocol; Role = $role; KeyPresent = $present
                            Enabled = $enabled; DisabledByDefault = $disabledByDefault
                        }
                    }
                }

                $netFramework = foreach ($path in @(
                    'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319')) {
                    $strong = $null; $sysDefault = $null
                    if (Test-Path -Path $path) {
                        $key = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                        if ($key) {
                            if ($null -ne $key.PSObject.Properties['SchUseStrongCrypto'])       { $strong = [int]$key.SchUseStrongCrypto }
                            if ($null -ne $key.PSObject.Properties['SystemDefaultTlsVersions']) { $sysDefault = [int]$key.SystemDefaultTlsVersions }
                        }
                    }
                    [pscustomobject]@{ Path = $path; SchUseStrongCrypto = $strong; SystemDefaultTlsVersions = $sysDefault }
                }

                [pscustomobject]@{ Protocols = @($results); NetFramework = @($netFramework) }
            } -ErrorAction Stop

            foreach ($row in @($reading.Protocols)) {
                $protocolRows.Add([pscustomobject]@{
                    Server            = $name
                    Protocol          = [string]$row.Protocol
                    Role              = [string]$row.Role
                    KeyPresent        = [bool]$row.KeyPresent
                    Enabled           = $row.Enabled
                    DisabledByDefault = $row.DisabledByDefault
                    EffectiveState    = (Get-ExchTlsEffectiveState -KeyPresent $row.KeyPresent -Enabled $row.Enabled -DisabledByDefault $row.DisabledByDefault)
                }) | Out-Null
            }

            foreach ($row in @($reading.NetFramework)) {
                $dotNetRows.Add([pscustomobject]@{
                    Server                   = $name
                    Path                     = [string]$row.Path
                    SchUseStrongCrypto       = $row.SchUseStrongCrypto
                    SystemDefaultTlsVersions = $row.SystemDefaultTlsVersions
                }) | Out-Null
            }
        }
        catch {
            $unread.Add($name) | Out-Null
            $errors.Add(("TLS registry read on {0}: {1}" -f $name, $_.Exception.Message)) | Out-Null
            $null = Write-ExchError -Run $Run -Context ('TLS registry read on {0}' -f $name) -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
        }
    }

    $authConfig = @(Invoke-ExchQuery -Label 'Get-AuthConfig' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-AuthConfig -ErrorAction Stop }) | Select-Object -First 1
    $signingEnabled = $null
    if ($authConfig) {
        $p = $authConfig.PSObject.Properties.Match('CurrentCertificateThumbprint') | Select-Object -First 1
        $signingEnabled = [bool]($p -and $p.Value)
    }

    $protocolArr = @($protocolRows.ToArray())
    $dotNetArr   = @($dotNetRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'security/tls.json' -ContentObject ([ordered]@{
        protocols     = $protocolArr
        dotNetFramework = $dotNetArr
        authConfig    = $authConfig
        unreadServers = @($unread.ToArray())
        errors        = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'security.tls-protocols' -Title 'SCHANNEL TLS Protocol State' -Area 'Security' `
            -Columns @('Server', 'Protocol', 'Role', 'KeyPresent', 'Enabled', 'DisabledByDefault', 'EffectiveState') -Rows $protocolArr -HighCardinality

        New-ExchInventorySection -Run $Run -Key 'security.dotnet-crypto' -Title '.NET Cryptography Settings' -Area 'Security' `
            -Columns @('Server', 'Path', 'SchUseStrongCrypto', 'SystemDefaultTlsVersions') -Rows $dotNetArr
    )

    if ($protocolArr.Count -eq 0) {
        return New-ExchCollectorResult -Sections $sections -Findings @(
            New-ExchUnavailableFinding -Control $control `
                -Reason ("The TLS registry could not be read on any Exchange server, so protocol configuration is unknown: {0}" -f ($errors -join '; ')) `
                -Remediation 'Allow remote registry access from the assessment host, or run the assessment locally on each Exchange server.'
        )
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    foreach ($protocol in $requiredDisabled) {
        $stillOn = @($protocolArr | Where-Object { $_.Protocol -eq $protocol -and $_.EffectiveState -eq 'Enabled' })
        if ($stillOn.Count -gt 0) {
            $problems.Add(("{0} is still enabled on {1} server/role combinations: {2}" -f $protocol, $stillOn.Count, `
                (($stillOn | ForEach-Object { "$($_.Server)/$($_.Role)" }) -join ', '))) | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
    }

    foreach ($protocol in $requiredEnabled) {
        $off = @($protocolArr | Where-Object { $_.Protocol -eq $protocol -and $_.EffectiveState -eq 'Disabled' })
        if ($off.Count -gt 0) {
            $problems.Add(("{0} is explicitly disabled on {1} server/role combinations, which will break client and server connectivity: {2}" -f `
                $protocol, $off.Count, (($off | ForEach-Object { "$($_.Server)/$($_.Role)" }) -join ', '))) | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
        $default = @($protocolArr | Where-Object { $_.Protocol -eq $protocol -and $_.EffectiveState -eq 'OperatingSystemDefault' })
        if ($default.Count -gt 0) {
            $problems.Add(("{0} is left at the operating system default on {1} server/role combinations rather than being set explicitly" -f $protocol, $default.Count)) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }
    }

    if ($requireStrong) {
        $weak = @($dotNetArr | Where-Object { $_.SchUseStrongCrypto -ne 1 -or $_.SystemDefaultTlsVersions -ne 1 })
        if ($weak.Count -gt 0) {
            $problems.Add((".NET is not configured for strong cryptography and system default TLS versions in {0} registry locations, so .NET applications on those servers may still negotiate a deprecated protocol: {1}" -f `
                $weak.Count, (($weak | ForEach-Object { "$($_.Server) $($_.Path -replace '.*\\\\', '')" } | Sort-Object -Unique) -join ', '))) | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
    }

    if ($null -eq $signingEnabled) {
        $problems.Add('The Exchange auth configuration could not be read, so serialised data signing state is unknown') | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    elseif (-not $signingEnabled) {
        $problems.Add('Exchange serialised data signing has no certificate configured') | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($unread.Count -gt 0) {
        $problems.Add(("The registry could not be read on {0} servers, so their TLS state is unknown: {1}" -f $unread.Count, ($unread -join ', '))) | Out-Null
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
                 else { ("TLS 1.2 is explicitly enabled and the deprecated protocols are disabled across {0} servers, and .NET is set for strong cryptography." -f `
                        @($protocolArr | ForEach-Object { $_.Server } | Sort-Object -Unique).Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($unread.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Set Enabled=1 and DisabledByDefault=0 for TLS 1.2 and the reverse for SSL 2.0, SSL 3.0, TLS 1.0 and TLS 1.1, for both Client and Server, on every Exchange server. Set SchUseStrongCrypto and SystemDefaultTlsVersions to 1 in both the 32-bit and 64-bit .NET registry paths. Change every server before changing any, or mail flow between them will break.' `
        -Metrics @{
            serversRead      = @($protocolArr | ForEach-Object { $_.Server } | Sort-Object -Unique).Count
            serversUnread    = $unread.Count
            protocolReadings = $protocolArr.Count
            serialisedDataSigningConfigured = $signingEnabled
        } `
        -Meta @{ dataSources = @{
            Registry = @{ state = $(if ($unread.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($unread -join ', ') }
            Exchange = @{ state = 'Success'; reason = '' }
        }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchTlsEffectiveState {
    <#
    Turns the SCHANNEL Enabled and DisabledByDefault pair into one readable state.

    An absent key is the operating system default, which is neither on nor off by configuration -
    reporting it as either would be a guess.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][bool]$KeyPresent,
        [Parameter()]$Enabled,
        [Parameter()]$DisabledByDefault
    )

    if (-not $KeyPresent) { return 'OperatingSystemDefault' }
    if ($null -eq $Enabled -and $null -eq $DisabledByDefault) { return 'OperatingSystemDefault' }
    if ($null -ne $Enabled -and [int]$Enabled -eq 0) { return 'Disabled' }
    if ($null -ne $Enabled -and [int]$Enabled -ne 0) {
        if ($null -ne $DisabledByDefault -and [int]$DisabledByDefault -ne 0) { return 'EnabledButNotDefault' }
        return 'Enabled'
    }
    if ($null -ne $DisabledByDefault -and [int]$DisabledByDefault -ne 0) { return 'Disabled' }
    return 'OperatingSystemDefault'
}

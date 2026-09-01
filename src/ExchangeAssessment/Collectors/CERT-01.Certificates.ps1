<#
CERT-01 - Exchange certificate bindings, expiry and strength.

Enumerates certificates per server rather than only for the local host, and checks the things
that actually break clients: an expiring certificate, a service with nothing bound to it, a
self-signed certificate serving external clients, and a weak key or signature.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_CERT_01_Certificates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'CERT-01'

    $servers = @()
    try { $servers = @(Get-ExchangeServer -ErrorAction Stop | ForEach-Object { [string]$_.Name }) }
    catch { $servers = @() }

    $criticalDays = [int](Get-ExchThreshold -Run $Run -Name 'Certificate.ExpiryCriticalDays' -Default 30)
    $warningDays  = [int](Get-ExchThreshold -Run $Run -Name 'Certificate.ExpiryWarningDays'  -Default 90)
    $minKeySize   = [int](Get-ExchThreshold -Run $Run -Name 'Certificate.MinKeySize'         -Default 2048)
    $requiredServices = @(Get-ExchThreshold -Run $Run -Name 'Certificate.RequiredBoundServices' -Default @('IIS', 'SMTP'))
    $flagSelfSigned   = [bool](Get-ExchThreshold -Run $Run -Name 'Certificate.FlagSelfSigned' -Default $true)
    $weakAlgorithms   = @(Get-ExchThreshold -Run $Run -Name 'Certificate.WeakSignatureAlgorithms' -Default @('md5RSA', 'sha1RSA'))

    $rows = New-Object System.Collections.Generic.List[object]
    $readErrors = New-Object System.Collections.Generic.List[string]
    $now = Get-Date

    # Fall back to a session-scoped query when the server list is unavailable, so a
    # single-server deployment still reports something.
    $targets = if ($servers.Count -gt 0) { $servers } else { @('') }

    foreach ($server in $targets) {
        try {
            $certs = if ($server) {
                @(Get-ExchangeCertificate -Server $server -ErrorAction Stop)
            }
            else {
                @(Get-ExchangeCertificate -ErrorAction Stop)
            }

            foreach ($cert in $certs) {
                $daysToExpiry = $null
                try { if ($cert.NotAfter) { $daysToExpiry = [math]::Round(([datetime]$cert.NotAfter - $now).TotalDays, 1) } } catch { $daysToExpiry = $null }

                $keySize = $null
                try { $keySize = [int]$cert.PublicKeySize } catch { $keySize = $null }

                $subject = [string]$cert.Subject
                $issuer  = [string]$cert.Issuer
                $selfSigned = ($subject -and $issuer -and $subject -eq $issuer)

                $rows.Add([pscustomobject]@{
                    Server        = $(if ($server) { $server } else { 'current session' })
                    Thumbprint    = [string]$cert.Thumbprint
                    Subject       = $subject
                    Issuer        = $issuer
                    FriendlyName  = [string]$cert.FriendlyName
                    Services      = (ConvertTo-ExchFlatValue -Value $cert.Services)
                    Domains       = (ConvertTo-ExchFlatValue -Value $cert.CertificateDomains)
                    NotBefore     = $cert.NotBefore
                    NotAfter      = $cert.NotAfter
                    DaysToExpiry  = $daysToExpiry
                    Status        = [string]$cert.Status
                    PublicKeySize = $keySize
                    SignatureAlgorithm = (Get-ExchCertificateSignatureAlgorithm -Certificate $cert)
                    SelfSigned    = $selfSigned
                }) | Out-Null
            }
        }
        catch {
            $readErrors.Add(("{0}: {1}" -f $(if ($server) { $server } else { 'current session' }), $_.Exception.Message)) | Out-Null
            $null = Write-ExchError -Run $Run -Context ('Get-ExchangeCertificate on {0}' -f $(if ($server) { $server } else { 'current session' })) -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
        }
    }

    $certArr = @($rows.ToArray())
    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'certificates/state.json' -ContentObject ([ordered]@{
        certificates = $certArr
        readErrors   = @($readErrors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'certificate.certificates' -Title 'Exchange Certificates' -Area 'Certificate' `
            -Columns @('Server', 'Thumbprint', 'Subject', 'Issuer', 'FriendlyName', 'Services', 'Domains', 'NotBefore', 'NotAfter', 'DaysToExpiry', 'Status', 'PublicKeySize', 'SignatureAlgorithm', 'SelfSigned') `
            -Rows $certArr
    )

    if ($certArr.Count -eq 0) {
        $reason = if ($readErrors.Count -gt 0) {
            "No certificates could be read: $($readErrors -join '; ')"
        }
        else {
            'Get-ExchangeCertificate returned no certificates, so certificate posture could not be assessed.'
        }
        return New-ExchCollectorResult -Sections $sections -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason `
                -Remediation 'Run from an Exchange Management Shell with rights to read Exchange certificates on every server.'
        )
    }

    $expiring    = @($certArr | Where-Object { $null -ne $_.DaysToExpiry -and $_.DaysToExpiry -le $criticalDays })
    $expiringSoon= @($certArr | Where-Object { $null -ne $_.DaysToExpiry -and $_.DaysToExpiry -gt $criticalDays -and $_.DaysToExpiry -le $warningDays })
    $weakKey     = @($certArr | Where-Object { $null -ne $_.PublicKeySize -and $_.PublicKeySize -lt $minKeySize })
    $weakAlgo    = @($certArr | Where-Object { $_.SignatureAlgorithm -and ($weakAlgorithms -contains $_.SignatureAlgorithm) })
    $selfSignedBound = @($certArr | Where-Object { $flagSelfSigned -and $_.SelfSigned -and $_.Services -and $_.Services -match 'IIS' })

    $unbound = @()
    foreach ($service in $requiredServices) {
        $bound = @($certArr | Where-Object { $_.Services -and $_.Services -match [regex]::Escape($service) -and $null -ne $_.DaysToExpiry -and $_.DaysToExpiry -gt 0 })
        if ($bound.Count -eq 0) { $unbound += $service }
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($expiring.Count -gt 0) {
        $problems.Add(("{0} certificates expire within {1} days: {2}" -f $expiring.Count, $criticalDays, `
            (($expiring | ForEach-Object { "$($_.Subject) on $($_.Server) in $($_.DaysToExpiry)d" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($unbound.Count -gt 0) {
        $problems.Add(("No valid certificate is bound to these services: {0}" -f ($unbound -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($weakKey.Count -gt 0) {
        $problems.Add(("{0} certificates have a public key smaller than {1} bits: {2}" -f $weakKey.Count, $minKeySize, `
            (($weakKey | ForEach-Object { "$($_.Subject) ($($_.PublicKeySize) bits)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($weakAlgo.Count -gt 0) {
        $problems.Add(("{0} certificates use a deprecated signature algorithm: {1}" -f $weakAlgo.Count, `
            (($weakAlgo | ForEach-Object { "$($_.Subject) ($($_.SignatureAlgorithm))" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($selfSignedBound.Count -gt 0) {
        $problems.Add(("{0} self-signed certificates are bound to IIS, which external clients will not trust: {1}" -f $selfSignedBound.Count, `
            (($selfSignedBound | ForEach-Object { "$($_.Subject) on $($_.Server)" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($expiringSoon.Count -gt 0) {
        $problems.Add(("{0} certificates expire within {1} days and should be scheduled for renewal" -f $expiringSoon.Count, $warningDays)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($readErrors.Count -gt 0) {
        $problems.Add(("Certificates could not be read from some servers: {0}" -f ($readErrors -join '; '))) | Out-Null
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
                 else { ("All {0} certificates are valid for more than {1} days, meet the {2}-bit key minimum, and every required service has a certificate bound." -f $certArr.Count, $warningDays, $minKeySize) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($readErrors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Renew expiring certificates from a trusted CA, bind a valid certificate to every required service, and replace certificates below the key size or using a deprecated signature algorithm.' `
        -Metrics @{
            certificateCount = $certArr.Count
            expiringCritical = $expiring.Count
            expiringWarning  = $expiringSoon.Count
            weakKey          = $weakKey.Count
            weakAlgorithm    = $weakAlgo.Count
            selfSignedOnIis  = $selfSignedBound.Count
            servicesWithoutCertificate = $unbound
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($readErrors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($readErrors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Get-ExchCertificateSignatureAlgorithm {
    <#
    The signature algorithm friendly name, where the certificate object exposes one.
    #>
    [CmdletBinding()]
    param([Parameter()]$Certificate)

    if ($null -eq $Certificate) { return '' }
    $prop = $Certificate.PSObject.Properties.Match('SignatureAlgorithm') | Select-Object -First 1
    if (-not $prop -or $null -eq $prop.Value) { return '' }

    $inner = $prop.Value.PSObject.Properties.Match('FriendlyName') | Select-Object -First 1
    if ($inner -and $inner.Value) { return [string]$inner.Value }
    return [string]$prop.Value
}

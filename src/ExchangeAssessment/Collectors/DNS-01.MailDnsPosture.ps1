<#
DNS-01 - External mail DNS posture.

For every authoritative accepted domain: does it publish MX, an SPF record that does not end in a
permissive all, and a DMARC policy. These are the records that decide whether someone else can
send mail as the organisation.

This is the only collector that leaves the network, so it can be skipped with -SkipDnsQueries.
Public DNS is resolved, which is the same view the internet has - an internal resolver with
split-horizon DNS may answer differently, and the finding says so.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_DNS_01_MailDnsPosture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'DNS-01'

    $errors = New-Object System.Collections.Generic.List[string]
    $accepted = @(Invoke-ExchQuery -Label 'Get-AcceptedDomain' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-AcceptedDomain -ErrorAction Stop })

    $domains = @($accepted |
        Where-Object { [string]$_.DomainType -eq 'Authoritative' -and [string]$_.DomainName -and [string]$_.DomainName -ne '*' } |
        ForEach-Object { ([string]$_.DomainName).ToLowerInvariant() } |
        Sort-Object -Unique)

    if ($domains.Count -eq 0) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Severity 'Medium' `
                -Reason ("No authoritative accepted domain was found to check, so external mail DNS posture was not assessed. {0}" -f ($errors -join '; ')) `
                -DataSource 'Dns' `
                -Remediation 'Confirm the organisation has at least one authoritative accepted domain, and that the assessment can read accepted domains.'
        )
    }

    $requireSpf   = [bool](Get-ExchThreshold -Run $Run -Name 'Dns.RequireSpf' -Default $true)
    $requireDmarc = [bool](Get-ExchThreshold -Run $Run -Name 'Dns.RequireDmarc' -Default $true)
    $requireMx    = [bool](Get-ExchThreshold -Run $Run -Name 'Dns.RequireMx' -Default $true)
    $badAll       = @(Get-ExchThreshold -Run $Run -Name 'Dns.DiscouragedSpfAll' -Default @('+all', '?all'))

    $rows = New-Object System.Collections.Generic.List[object]
    $mxRows = New-Object System.Collections.Generic.List[object]

    foreach ($domain in $domains) {
        $mx = @(Resolve-ExchDnsRecord -Name $domain -Type 'MX' -Errors $errors -Run $Run -ControlId $control.controlId)
        foreach ($record in $mx) {
            $mxRows.Add([pscustomobject]@{
                Domain     = $domain
                Exchange   = [string]$record.NameExchange
                Preference = [string]$record.Preference
            }) | Out-Null
        }

        $txt = @(Resolve-ExchDnsRecord -Name $domain -Type 'TXT' -Errors $errors -Run $Run -ControlId $control.controlId)
        $spf = ''
        foreach ($record in $txt) {
            $text = (@($record.Strings) -join '')
            if ($text -match '^v=spf1') { $spf = $text; break }
        }

        $dmarcTxt = @(Resolve-ExchDnsRecord -Name ("_dmarc.{0}" -f $domain) -Type 'TXT' -Errors $errors -Run $Run -ControlId $control.controlId)
        $dmarc = ''
        foreach ($record in $dmarcTxt) {
            $text = (@($record.Strings) -join '')
            if ($text -match '^v=DMARC1') { $dmarc = $text; break }
        }

        $dmarcPolicy = ''
        if ($dmarc -match '\bp\s*=\s*(none|quarantine|reject)\b') { $dmarcPolicy = $matches[1] }

        $spfAll = ''
        if ($spf -match '([~\-\+\?])all\b') { $spfAll = ($matches[1] + 'all') }

        $rows.Add([pscustomobject]@{
            Domain          = $domain
            MxCount         = $mx.Count
            MxHosts         = ((@($mx | ForEach-Object { [string]$_.NameExchange }) | Sort-Object) -join ';')
            SpfRecord       = $spf
            SpfAllQualifier = $spfAll
            SpfPermissive   = ($spfAll -and ($badAll -contains $spfAll))
            DmarcRecord     = $dmarc
            DmarcPolicy     = $dmarcPolicy
        }) | Out-Null
    }

    $rowArr = @($rows.ToArray())
    $mxArr  = @($mxRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'network/mail-dns.json' -ContentObject ([ordered]@{
        domains = $rowArr
        mx      = $mxArr
        errors  = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'network.mail-dns' -Title 'Mail DNS by Domain' -Area 'Network' `
            -Columns @('Domain', 'MxCount', 'MxHosts', 'SpfRecord', 'SpfAllQualifier', 'SpfPermissive', 'DmarcRecord', 'DmarcPolicy') -Rows $rowArr

        New-ExchInventorySection -Run $Run -Key 'network.mx-records' -Title 'MX Records' -Area 'Network' `
            -Columns @('Domain', 'Exchange', 'Preference') -Rows $mxArr
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    $noMx    = @($rowArr | Where-Object { $requireMx -and $_.MxCount -eq 0 })
    $noSpf   = @($rowArr | Where-Object { $requireSpf -and -not $_.SpfRecord })
    $weakSpf = @($rowArr | Where-Object { $_.SpfPermissive })
    $noDmarc = @($rowArr | Where-Object { $requireDmarc -and -not $_.DmarcRecord })
    $noneDmarc = @($rowArr | Where-Object { $_.DmarcPolicy -eq 'none' })

    if ($noMx.Count -gt 0) {
        $problems.Add(("{0} authoritative domains publish no MX record, so they cannot receive internet mail: {1}" -f $noMx.Count, `
            (($noMx | ForEach-Object { $_.Domain }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($noSpf.Count -gt 0) {
        $problems.Add(("{0} authoritative domains publish no SPF record, so anyone can send mail claiming to be them: {1}" -f $noSpf.Count, `
            (($noSpf | ForEach-Object { $_.Domain }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($weakSpf.Count -gt 0) {
        $problems.Add(("{0} domains publish an SPF record ending in a permissive qualifier, which tells receivers to accept mail from anywhere: {1}" -f $weakSpf.Count, `
            (($weakSpf | ForEach-Object { "$($_.Domain) ($($_.SpfAllQualifier))" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($noDmarc.Count -gt 0) {
        $problems.Add(("{0} authoritative domains publish no DMARC record: {1}" -f $noDmarc.Count, `
            (($noDmarc | ForEach-Object { $_.Domain }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($noneDmarc.Count -gt 0) {
        $problems.Add(("{0} domains publish DMARC with policy none, which reports abuse but does not stop it: {1}" -f $noneDmarc.Count, `
            (($noneDmarc | ForEach-Object { $_.Domain }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($errors.Count -gt 0) {
        $problems.Add(("Some DNS lookups failed: {0}" -f ($errors -join '; '))) | Out-Null
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
                 else { ("All {0} authoritative domains publish MX, a restrictive SPF record and an enforcing DMARC policy." -f $rowArr.Count) }
    $rationale += ' Records were resolved from this host, so a split-horizon resolver may return a different answer than the internet sees.'

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Publish an SPF record ending in -all for every authoritative domain once the legitimate senders are known, then move DMARC from none to quarantine and on to reject as the reports come back clean. A domain with no SPF or DMARC can be spoofed by anyone.' `
        -Metrics @{
            domainsChecked = $rowArr.Count
            withoutMx      = $noMx.Count
            withoutSpf     = $noSpf.Count
            permissiveSpf  = $weakSpf.Count
            withoutDmarc   = $noDmarc.Count
            dmarcPolicyNone= $noneDmarc.Count
        } `
        -Meta @{ dataSources = @{ Dns = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Resolve-ExchDnsRecord {
    <#
    One DNS lookup. NXDOMAIN and an empty answer are normal results for a record that is simply
    not published, so they return nothing rather than being recorded as failures - only a real
    resolver problem is an error worth reporting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('MX', 'TXT', 'A')][string]$Type,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors,
        [Parameter()]$Run,
        [Parameter()][string]$ControlId = ''
    )

    try {
        return @(Resolve-DnsName -Name $Name -Type $Type -ErrorAction Stop |
            Where-Object { [string]$_.Type -eq $Type })
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -match 'DNS name does not exist|No such host|NXDOMAIN|not exist') { return @() }

        $Errors.Add(("{0} {1}: {2}" -f $Type, $Name, $message)) | Out-Null
        if ($Run) {
            try { $null = Write-ExchError -Run $Run -Context ("Resolve-DnsName {0} {1}" -f $Type, $Name) -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning' }
            catch { Write-Verbose ("Could not record the DNS failure for {0}: {1}" -f $Name, $_.Exception.Message) }
        }
        return @()
    }
}

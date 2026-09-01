<#
MB.INV-01 - Mailbox, quota and archive inventory.

The only collector whose cost scales with the size of the organisation, so it is capped by
Mailbox.MaxMailboxes and can be skipped entirely with -SkipMailboxInventory. When the cap bites,
the finding says so rather than reporting on a partial estate as though it were the whole one.

Statistics are read per mailbox, which is the expensive part. A mailbox whose statistics cannot
be read is reported with an unknown size rather than a zero.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_MB_INV_01_MailboxInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'MB.INV-01'

    $errors = New-Object System.Collections.Generic.List[string]
    $maxMailboxes = [int](Get-ExchThreshold -Run $Run -Name 'Mailbox.MaxMailboxes' -Default 5000)

    $mailboxes = @(Invoke-ExchQuery -Label 'Get-Mailbox' -Errors $errors -Run $Run -ControlId $control.controlId -Script {
        if ($maxMailboxes -gt 0) { Get-Mailbox -ResultSize $maxMailboxes -ErrorAction Stop }
        else { Get-Mailbox -ResultSize Unlimited -ErrorAction Stop }
    })

    if ($mailboxes.Count -eq 0) {
        $reason = if ($errors.Count -gt 0) {
            "Mailboxes could not be enumerated: $($errors -join '; ')"
        }
        else {
            'Get-Mailbox returned no mailboxes, so there was nothing to inventory.'
        }
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason -Severity 'Medium' `
                -Remediation 'Run from an Exchange Management Shell with rights to enumerate mailboxes.'
        )
    }

    $quotaWarnPercent = [int](Get-ExchThreshold -Run $Run -Name 'Mailbox.QuotaWarningPercent' -Default 90)
    $largeGb          = [int](Get-ExchThreshold -Run $Run -Name 'Mailbox.LargeMailboxGB' -Default 50)
    $flagForwarding   = [bool](Get-ExchThreshold -Run $Run -Name 'Mailbox.FlagExternalForwarding' -Default $true)

    $acceptedDomains = @()
    foreach ($d in @(Invoke-ExchQuery -Label 'Get-AcceptedDomain' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-AcceptedDomain -ErrorAction Stop })) {
        $acceptedDomains += ([string]$d.DomainName).ToLowerInvariant()
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $statisticsFailures = 0

    foreach ($mailbox in $mailboxes) {
        $sizeGb = $null
        $items = $null
        try {
            $statistics = Get-MailboxStatistics -Identity $mailbox.Identity -ErrorAction Stop
            if ($statistics.TotalItemSize) { $sizeGb = [math]::Round($statistics.TotalItemSize.Value.ToBytes() / 1GB, 3) }
            $items = [int]$statistics.ItemCount
        }
        catch {
            $statisticsFailures++
            if ($statisticsFailures -le 5) {
                $null = Write-ExchError -Run $Run -Context ('Get-MailboxStatistics on {0}' -f $mailbox.Name) -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
            }
        }

        $quotaGb = Convert-ExchQuotaToGb -Quota $mailbox.ProhibitSendQuota
        $percentUsed = $null
        if ($null -ne $sizeGb -and $null -ne $quotaGb -and $quotaGb -gt 0) {
            $percentUsed = [math]::Round(($sizeGb / $quotaGb) * 100, 1)
        }

        $forwarding = ''
        foreach ($property in @('ForwardingAddress', 'ForwardingSmtpAddress')) {
            $p = $mailbox.PSObject.Properties.Match($property) | Select-Object -First 1
            if ($p -and $p.Value) { $forwarding = [string]$p.Value; break }
        }
        $forwardsExternally = ($forwarding -and -not (Test-ExchAddressIsInternal -Address $forwarding -AcceptedDomains $acceptedDomains))

        $rows.Add([pscustomobject]@{
            Name                 = [string]$mailbox.Name
            PrimarySmtpAddress   = [string]$mailbox.PrimarySmtpAddress
            RecipientTypeDetails = [string]$mailbox.RecipientTypeDetails
            Database             = [string]$mailbox.Database
            SizeGB               = $sizeGb
            ItemCount            = $items
            ProhibitSendQuota    = [string]$mailbox.ProhibitSendQuota
            QuotaGB              = $quotaGb
            PercentOfQuota       = $percentUsed
            UseDatabaseQuotaDefaults = (ConvertTo-ExchFlatValue -Value $mailbox.UseDatabaseQuotaDefaults)
            ArchiveState         = [string]$mailbox.ArchiveState
            ArchiveDatabase      = [string]$mailbox.ArchiveDatabase
            LitigationHoldEnabled= (ConvertTo-ExchFlatValue -Value $mailbox.LitigationHoldEnabled)
            RetentionPolicy      = [string]$mailbox.RetentionPolicy
            HiddenFromAddressLists = (ConvertTo-ExchFlatValue -Value $mailbox.HiddenFromAddressListsEnabled)
            ForwardingTo         = $forwarding
            ForwardsExternally   = $forwardsExternally
        }) | Out-Null
    }

    $mailboxArr = @($rows.ToArray())
    $capped = ($maxMailboxes -gt 0 -and $mailboxArr.Count -ge $maxMailboxes)

    $byDatabase = $mailboxArr | Group-Object Database | ForEach-Object {
        $sizes = @($_.Group | ForEach-Object { $_.SizeGB } | Where-Object { $null -ne $_ })
        [pscustomobject]@{
            Database     = $_.Name
            MailboxCount = $_.Count
            TotalSizeGB  = $(if ($sizes.Count -gt 0) { [math]::Round(($sizes | Measure-Object -Sum).Sum, 2) } else { $null })
            LargestGB    = $(if ($sizes.Count -gt 0) { [math]::Round(($sizes | Measure-Object -Maximum).Maximum, 2) } else { $null })
        }
    }
    $byDatabaseArr = @($byDatabase)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'mailbox/inventory.json' -ContentObject ([ordered]@{
        mailboxes          = $mailboxArr
        byDatabase         = $byDatabaseArr
        capped             = $capped
        cap                = $maxMailboxes
        statisticsFailures = $statisticsFailures
        errors             = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'mailbox.inventory' -Title 'Mailboxes' -Area 'Mailbox' `
            -Columns @('Name', 'PrimarySmtpAddress', 'RecipientTypeDetails', 'Database', 'SizeGB', 'ItemCount', 'ProhibitSendQuota', 'QuotaGB', 'PercentOfQuota', 'UseDatabaseQuotaDefaults', 'ArchiveState', 'ArchiveDatabase', 'LitigationHoldEnabled', 'RetentionPolicy', 'HiddenFromAddressLists', 'ForwardingTo', 'ForwardsExternally') `
            -Rows $mailboxArr -HighCardinality

        New-ExchInventorySection -Run $Run -Key 'mailbox.by-database' -Title 'Mailboxes by Database' -Area 'Mailbox' `
            -Columns @('Database', 'MailboxCount', 'TotalSizeGB', 'LargestGB') -Rows $byDatabaseArr
    )

    $nearQuota  = @($mailboxArr | Where-Object { $null -ne $_.PercentOfQuota -and $_.PercentOfQuota -ge $quotaWarnPercent })
    $large      = @($mailboxArr | Where-Object { $null -ne $_.SizeGB -and $_.SizeGB -gt $largeGb })
    $forwarders = @($mailboxArr | Where-Object { $flagForwarding -and $_.ForwardsExternally })
    $unsized    = @($mailboxArr | Where-Object { $null -eq $_.SizeGB })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($forwarders.Count -gt 0) {
        $problems.Add(("{0} mailboxes forward to an address outside the organisation, which is a data egress path: {1}" -f $forwarders.Count, `
            (($forwarders | Select-Object -First 10 | ForEach-Object { "$($_.PrimarySmtpAddress) -> $($_.ForwardingTo)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($nearQuota.Count -gt 0) {
        $problems.Add(("{0} mailboxes are at or above {1}% of their send quota: {2}" -f $nearQuota.Count, $quotaWarnPercent, `
            (($nearQuota | Select-Object -First 10 | ForEach-Object { "$($_.PrimarySmtpAddress) $($_.PercentOfQuota)%" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($large.Count -gt 0) {
        $problems.Add(("{0} mailboxes exceed {1} GB and are worth reviewing for archiving" -f $large.Count, $largeGb)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($unsized.Count -gt 0) {
        $problems.Add(("Statistics could not be read for {0} mailboxes, so their size is unknown" -f $unsized.Count)) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($capped) {
        $problems.Add(("The enumeration stopped at the configured cap of {0} mailboxes, so this is a sample rather than the whole organisation" -f $maxMailboxes)) | Out-Null
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

    $totalGb = @($mailboxArr | ForEach-Object { $_.SizeGB } | Where-Object { $null -ne $_ })
    $totalGbSum = if ($totalGb.Count -gt 0) { [math]::Round(($totalGb | Measure-Object -Sum).Sum, 1) } else { 0 }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else { ("{0} mailboxes across {1} databases hold {2} GB in total; none is near its quota or forwarding externally." -f `
                        $mailboxArr.Count, $byDatabaseArr.Count, $totalGbSum) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($capped -or $unsized.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Confirm every external forward is authorised and remove the rest. Raise quotas or enable archiving for mailboxes near their limit. Raise Mailbox.MaxMailboxes or pass -FullInventory if a complete estate listing is needed.' `
        -Metrics @{
            mailboxCount     = $mailboxArr.Count
            databases        = $byDatabaseArr.Count
            totalSizeGB      = $totalGbSum
            nearQuota        = $nearQuota.Count
            largeMailboxes   = $large.Count
            externalForwarders = $forwarders.Count
            statisticsFailures = $statisticsFailures
            capped           = $capped
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0 -or $capped) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Convert-ExchQuotaToGb {
    <#
    Exchange quota values print as '50 GB (53,687,091,200 bytes)' or as 'Unlimited'. Returns the
    size in GB, or $null when there is no numeric limit to compare against.
    #>
    [CmdletBinding()]
    param([Parameter()]$Quota)

    if ($null -eq $Quota) { return $null }
    $text = [string]$Quota
    if (-not $text -or $text -match 'Unlimited') { return $null }

    if ($text -match '\(([\d,]+)\s*bytes\)') {
        $bytes = [double](($matches[1]) -replace ',', '')
        return [math]::Round($bytes / 1GB, 3)
    }
    if ($text -match '^\s*([\d\.]+)\s*(KB|MB|GB|TB)\s*$') {
        $value = [double]$matches[1]
        switch ($matches[2]) {
            'KB' { return [math]::Round($value / 1MB * 1KB / 1GB * 1GB / 1GB, 6) }
            'MB' { return [math]::Round($value / 1024, 4) }
            'GB' { return [math]::Round($value, 3) }
            'TB' { return [math]::Round($value * 1024, 3) }
        }
    }
    return $null
}

function Test-ExchAddressIsInternal {
    <#
    True when the address's domain is one the organisation accepts.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$Address,
        [Parameter()][string[]]$AcceptedDomains = @()
    )

    if (-not $Address) { return $true }
    if (@($AcceptedDomains).Count -eq 0) { return $true }

    $domain = ''
    if ($Address -match '@([^@>\s]+)') { $domain = $matches[1].ToLowerInvariant().TrimEnd('>') }
    if (-not $domain) { return $true }

    foreach ($accepted in $AcceptedDomains) {
        if (-not $accepted) { continue }
        if ($domain -eq $accepted) { return $true }
        if ($accepted -eq '*') { return $true }
        if ($domain.EndsWith('.' + $accepted)) { return $true }
    }
    return $false
}

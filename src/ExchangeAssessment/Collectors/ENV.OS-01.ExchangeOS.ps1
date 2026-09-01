<#
ENV.OS-01 - Exchange server operating system supportability.

Reads the OS, uptime and free disk of every Exchange server. A server whose OS cannot be read
is reported as unread, not as healthy.

The supported operating system list is per Exchange version rather than global, so the Exchange
product family is resolved per server and the operating system is judged against that product's
row in OperatingSystem.SupportMatrix. Exchange Server SE and 2019 want Windows Server 2019 or
later; Exchange Server 2016 wants Windows Server 2016 or earlier. A single global floor reported
every correctly built Exchange 2016 server as unsupported, which is the wrong answer for the
estates most likely to be assessed for an SE migration.

The family is resolved here from Get-ExchangeServer rather than taken from EX.CH-01, so this
collector stays independent of collection order and of whether EX.CH-01 ran at all.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_ENV_OS_01_ExchangeOS {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'ENV.OS-01'

    try { $servers = @(Get-ExchangeServer -ErrorAction Stop) }
    catch {
        $reason = "Get-ExchangeServer failed, so no server operating systems could be assessed: $($_.Exception.Message)"
        $null = Write-ExchError -Run $Run -Context 'Get-ExchangeServer' -ErrorRecord $_ -ControlId $control.controlId
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason `
                -Remediation 'Run the assessment from an Exchange Management Shell using an account with at least View-Only Organization Management.'
        )
    }

    if ($servers.Count -eq 0) {
        $reason = 'Get-ExchangeServer returned no servers, so there is nothing to assess. This is not an empty organisation - it means the query returned nothing.'
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason `
                -Remediation 'Confirm the session is connected to the intended Exchange organisation and the account can enumerate servers.'
        )
    }

    $maxUptimeDays     = [int](Get-ExchThreshold -Run $Run -Name 'OperatingSystem.MaxUptimeDays'      -Default 90)
    $minFreePercent    = [int](Get-ExchThreshold -Run $Run -Name 'OperatingSystem.MinFreeDiskPercent' -Default 15)
    $minFreeGb         = [int](Get-ExchThreshold -Run $Run -Name 'OperatingSystem.MinFreeDiskGB'      -Default 20)

    $records = New-Object System.Collections.Generic.List[object]
    $volumes = New-Object System.Collections.Generic.List[object]

    foreach ($srv in $servers) {
        $name = [string]$srv.Name
        $family = Resolve-ExchServerProductFamily -Run $Run -Server $srv
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $name -ErrorAction Stop
            $support = Resolve-ExchOsSupport -Run $Run -Version ([string]$os.Version) -Product $family.Name

            $lastBoot = Get-ExchObjectValue -InputObject $os -Name 'LastBootUpTime'
            $uptimeDays = $null
            if ($lastBoot) { $uptimeDays = [math]::Round(((Get-Date) - $lastBoot).TotalDays, 1) }

            $records.Add([pscustomobject]@{
                Server      = $name
                ExchangeProduct = $family.Name
                OperatingSystem = $support.Name
                Caption     = [string](Get-ExchObjectValue -InputObject $os -Name 'Caption' -Default '')
                Version     = [string]$os.Version
                BuildNumber = [string](Get-ExchObjectValue -InputObject $os -Name 'BuildNumber' -Default '')
                Supported   = $support.Supported
                Recommended = $support.Recommended
                Assessable  = $support.Matched
                SupportedForProduct = $support.SupportedNames
                LastBoot    = $lastBoot
                UptimeDays  = $uptimeDays
                Error       = ''
            }) | Out-Null

            try {
                foreach ($disk in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ComputerName $name -ErrorAction Stop)) {
                    $sizeGb = if ($disk.Size) { [math]::Round($disk.Size / 1GB, 1) } else { 0 }
                    $freeGb = if ($disk.FreeSpace) { [math]::Round($disk.FreeSpace / 1GB, 1) } else { 0 }
                    $freePct = if ($disk.Size -and $disk.Size -gt 0) { [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1) } else { 0 }
                    $volumes.Add([pscustomobject]@{
                        Server        = $name
                        Drive         = [string]$disk.DeviceID
                        SizeGB        = $sizeGb
                        FreeGB        = $freeGb
                        FreePercent   = $freePct
                        BelowThreshold = ($freePct -lt $minFreePercent -and $freeGb -lt $minFreeGb)
                    }) | Out-Null
                }
            }
            catch {
                $null = Write-ExchError -Run $Run -Context ('Get-CimInstance Win32_LogicalDisk on {0}' -f $name) -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
            }
        }
        catch {
            $null = Write-ExchError -Run $Run -Context ('Get-CimInstance Win32_OperatingSystem on {0}' -f $name) -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
            $records.Add([pscustomobject]@{
                Server = $name; ExchangeProduct = $family.Name; OperatingSystem = 'Unread'
                Caption = ''; Version = ''; BuildNumber = ''
                Supported = $false; Recommended = $false; Assessable = $false; SupportedForProduct = ''
                LastBoot = $null; UptimeDays = $null
                Error = [string]$_.Exception.Message
            }) | Out-Null
        }
    }

    $recArr = @($records.ToArray())
    $volArr = @($volumes.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'environment/exchange-os.json' -ContentObject ([ordered]@{
        servers = $recArr
        volumes = $volArr
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'environment.server-os' -Title 'Exchange Server Operating Systems' -Area 'Environment' `
            -Columns @('Server', 'ExchangeProduct', 'OperatingSystem', 'Caption', 'Version', 'BuildNumber', 'Supported', 'Recommended', 'Assessable', 'SupportedForProduct', 'LastBoot', 'UptimeDays', 'Error') `
            -Rows $recArr

        New-ExchInventorySection -Run $Run -Key 'environment.server-volumes' -Title 'Exchange Server Volumes' -Area 'Environment' `
            -Columns @('Server', 'Drive', 'SizeGB', 'FreeGB', 'FreePercent', 'BelowThreshold') `
            -Rows $volArr
    )

    $unread      = @($recArr | Where-Object { $_.Error })
    $unjudged    = @($recArr | Where-Object { -not $_.Error -and -not $_.Assessable })
    $unsupported = @($recArr | Where-Object { -not $_.Error -and $_.Assessable -and -not $_.Supported })
    $notPreferred = @($recArr | Where-Object { -not $_.Error -and $_.Assessable -and $_.Supported -and -not $_.Recommended })
    $longUptime  = @($recArr | Where-Object { $null -ne $_.UptimeDays -and $_.UptimeDays -gt $maxUptimeDays })
    $lowDisk     = @($volArr | Where-Object { $_.BelowThreshold })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($unsupported.Count -gt 0) {
        $problems.Add(("{0} of {1} servers run an operating system Microsoft does not list as supported for the Exchange version installed on them: {2}" -f `
            $unsupported.Count, $recArr.Count, `
            (($unsupported | ForEach-Object { "$($_.Server) runs $($_.OperatingSystem) under $($_.ExchangeProduct), which supports $($_.SupportedForProduct)" }) -join '; '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($notPreferred.Count -gt 0) {
        $problems.Add(("{0} servers are on a supported but not recommended operating system for their Exchange version: {1}" -f `
            $notPreferred.Count, (($notPreferred | ForEach-Object { "$($_.Server) runs $($_.OperatingSystem) under $($_.ExchangeProduct)" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($lowDisk.Count -gt 0) {
        $problems.Add(("{0} volumes are below the free space threshold of {1}% / {2} GB: {3}" -f `
            $lowDisk.Count, $minFreePercent, $minFreeGb, (($lowDisk | ForEach-Object { "$($_.Server) $($_.Drive) $($_.FreePercent)%" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($longUptime.Count -gt 0) {
        $problems.Add(("{0} servers have not rebooted in more than {1} days, so pending updates may not be in effect: {2}" -f `
            $longUptime.Count, $maxUptimeDays, (($longUptime | ForEach-Object { "$($_.Server) ($($_.UptimeDays)d)" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($unjudged.Count -gt 0) {
        $problems.Add(("{0} servers run an Exchange version with no operating system support row, so their operating system was not judged: {1}" -f `
            $unjudged.Count, (($unjudged | ForEach-Object { "$($_.Server) runs $($_.ExchangeProduct) on $($_.OperatingSystem)" }) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($unread.Count -gt 0) {
        $problems.Add(("{0} servers could not be queried and were not assessed: {1}" -f `
            $unread.Count, (($unread | ForEach-Object { "$($_.Server) - $($_.Error)" }) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Medium' }
        'Unknown'            { 'High' }
        default              { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else {
                     ("All {0} Exchange servers run an operating system Microsoft recommends for the Exchange version installed on them ({1}), with adequate free disk." -f `
                         $recArr.Count, ((@($recArr | ForEach-Object { "$($_.OperatingSystem) under $($_.ExchangeProduct)" }) | Sort-Object -Unique) -join ', '))
                 }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($unread.Count -gt 0 -or $unjudged.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation ('Move Exchange servers onto a Windows Server build supported for their Exchange version - the matrix is at ' + `
            'https://learn.microsoft.com/exchange/plan-and-deploy/supportability-matrix#supported-operating-systems - reclaim disk on volumes below threshold, and reboot servers carrying pending updates.') `
        -Metrics @{
            serverCount      = $recArr.Count
            unsupportedCount = $unsupported.Count
            notPreferredCount= $notPreferred.Count
            unjudgedCount    = $unjudged.Count
            lowDiskCount     = $lowDisk.Count
            longUptimeCount  = $longUptime.Count
            unreadCount      = $unread.Count
        } `
        -Meta @{ dataSources = @{
            Exchange = @{ state = 'Success'; reason = '' }
            WinRM    = @{ state = $(if ($unread.Count -gt 0) { 'Partial' } else { 'Success' }); reason = $(if ($unread.Count -gt 0) { 'Some servers could not be queried' } else { '' }) }
        }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Resolve-ExchServerProductFamily {
    <#
    Resolves one Exchange server's product family from its AdminDisplayVersion.

    Guarded throughout: AdminDisplayVersion is an Exchange type whose parts a strict-mode read
    will throw on if the server object came back partially populated, and a version this
    collector cannot parse must become "not assessable" rather than take the whole run down.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNull()]$Server
    )

    $adv = Get-ExchObjectValue -InputObject $Server -Name 'AdminDisplayVersion'
    $major = 0; $minor = 0; $build = 0
    try {
        $major = [int](Get-ExchObjectValue -InputObject $adv -Name 'Major' -Default 0)
        $minor = [int](Get-ExchObjectValue -InputObject $adv -Name 'Minor' -Default 0)
        $build = [int](Get-ExchObjectValue -InputObject $adv -Name 'Build' -Default 0)
    }
    catch { $major = 0; $minor = 0; $build = 0 }

    return Resolve-ExchProductFamily -Run $Run -Major $major -Minor $minor -Build $build
}

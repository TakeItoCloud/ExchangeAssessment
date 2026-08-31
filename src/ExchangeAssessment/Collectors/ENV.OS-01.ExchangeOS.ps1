<#
ENV.OS-01 - Exchange server operating system supportability.

Reads the OS, uptime and free disk of every Exchange server. A server whose OS cannot be read
is reported as unread, not as healthy.
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
        Write-ExchEvent -Run $Run -Level ERROR -Message 'Get-ExchangeServer failed' -Data @{ error = $_.Exception.Message }
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
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $name -ErrorAction Stop
            $support = Resolve-ExchOsSupport -Run $Run -Version ([string]$os.Version)

            $uptimeDays = $null
            if ($os.LastBootUpTime) { $uptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1) }

            $records.Add([pscustomobject]@{
                Server      = $name
                OperatingSystem = $support.Name
                Caption     = [string]$os.Caption
                Version     = [string]$os.Version
                BuildNumber = [string]$os.BuildNumber
                Supported   = $support.Supported
                Recommended = $support.Recommended
                LastBoot    = $os.LastBootUpTime
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
                Write-ExchEvent -Run $Run -Level WARN -Message 'Disk query failed' -Data @{ server = $name; error = $_.Exception.Message }
            }
        }
        catch {
            $records.Add([pscustomobject]@{
                Server = $name; OperatingSystem = 'Unread'; Caption = ''; Version = ''; BuildNumber = ''
                Supported = $false; Recommended = $false; LastBoot = $null; UptimeDays = $null
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
            -Columns @('Server', 'OperatingSystem', 'Caption', 'Version', 'BuildNumber', 'Supported', 'Recommended', 'LastBoot', 'UptimeDays', 'Error') `
            -Rows $recArr

        New-ExchInventorySection -Run $Run -Key 'environment.server-volumes' -Title 'Exchange Server Volumes' -Area 'Environment' `
            -Columns @('Server', 'Drive', 'SizeGB', 'FreeGB', 'FreePercent', 'BelowThreshold') `
            -Rows $volArr
    )

    $unread      = @($recArr | Where-Object { $_.Error })
    $unsupported = @($recArr | Where-Object { -not $_.Error -and -not $_.Supported })
    $notPreferred = @($recArr | Where-Object { -not $_.Error -and $_.Supported -and -not $_.Recommended })
    $longUptime  = @($recArr | Where-Object { $null -ne $_.UptimeDays -and $_.UptimeDays -gt $maxUptimeDays })
    $lowDisk     = @($volArr | Where-Object { $_.BelowThreshold })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($unsupported.Count -gt 0) {
        $problems.Add(("{0} of {1} servers run an operating system below the supported minimum: {2}" -f `
            $unsupported.Count, $recArr.Count, (($unsupported | ForEach-Object { "$($_.Server) ($($_.OperatingSystem))" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($notPreferred.Count -gt 0) {
        $problems.Add(("{0} servers are on a supported but not recommended operating system: {1}" -f `
            $notPreferred.Count, (($notPreferred | ForEach-Object { "$($_.Server) ($($_.OperatingSystem))" }) -join ', '))) | Out-Null
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
                 else { ("All {0} Exchange servers run a recommended operating system with adequate free disk." -f $recArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($unread.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Move Exchange servers onto a supported Windows Server build, reclaim disk on volumes below threshold, and reboot servers carrying pending updates.' `
        -Metrics @{
            serverCount      = $recArr.Count
            unsupportedCount = $unsupported.Count
            notPreferredCount= $notPreferred.Count
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

<#
MB.AV-01 - Exchange anti-malware exclusions.

Reports what is missing, not just what is set. The Microsoft-recommended folder and process
exclusions live in Config/Thresholds.psd1 and every Exchange server's configured exclusions are
compared against them.

Only Microsoft Defender is readable this way. A server running third-party anti-malware is
reported as not assessed rather than as compliant.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_MB_AV_01_AVExclusions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'MB.AV-01'

    try { $servers = @(Get-ExchangeServer -ErrorAction Stop) }
    catch {
        $reason = "Get-ExchangeServer failed, so anti-malware exclusions could not be assessed: $($_.Exception.Message)"
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason `
                -Remediation 'Run from an Exchange Management Shell with rights to enumerate servers.'
        )
    }

    $requiredPaths     = @(Get-ExchThreshold -Run $Run -Name 'AntiVirus.RequiredPathTokens'    -Default @())
    $requiredProcesses = @(Get-ExchThreshold -Run $Run -Name 'AntiVirus.RequiredProcessTokens' -Default @())

    $serverRows = New-Object System.Collections.Generic.List[object]
    $gapRows    = New-Object System.Collections.Generic.List[object]

    foreach ($srv in $servers) {
        $name = [string]$srv.Name
        try {
            # Defender's running mode is read alongside the preferences: a server whose
            # Defender is not the primary anti-malware product (passive or EDR block mode) has
            # its real exclusions elsewhere. A failed status read leaves the mode $null and
            # does not block the exclusion read.
            $reading = Invoke-Command -ComputerName $name -ErrorAction Stop -ScriptBlock {
                $preference = Get-MpPreference -ErrorAction Stop
                $mode = $null
                try { $mode = [string](Get-MpComputerStatus -ErrorAction Stop).AMRunningMode } catch { $mode = $null }
                [pscustomobject]@{ ExclusionPath = @($preference.ExclusionPath); ExclusionProcess = @($preference.ExclusionProcess); RunningMode = $mode }
            }
            $view      = Get-ExchExclusionView -Paths $reading.ExclusionPath -Processes $reading.ExclusionProcess
            $paths     = @($view.Paths)
            $processes = @($view.Processes)
            $runningMode = [string]$reading.RunningMode

            # Three readings cannot be compared against the recommended list, and each is
            # reported as not assessed rather than as a full set of gaps:
            # - Defender is not the primary product, so its list is not the one that applies;
            # - Defender answered with its "N/A: Must be an administrator" placeholder, so the list is hidden;
            # - Defender answered with no exclusions at all, which is either none configured or
            #   exclusions hidden by HideExclusionsFromLocalAdmins
            #   (https://learn.microsoft.com/defender-endpoint/microsoft-defender-antivirus-exclusions-configure,
            #   read 2026-09-26) - one reading cannot tell those apart. On the first live run
            #   every server answered this way and was reported with the full 19 gaps.
            $notReadReason = ''
            if ($runningMode -and $runningMode -notmatch '^Normal') {
                $notReadReason = "Microsoft Defender is running in '$runningMode' mode, so it is not the primary anti-malware product and its exclusion list is not the one that applies"
            }
            elseif ($view.Hidden) {
                $notReadReason = 'Defender returned a placeholder instead of its exclusion list, so the list is hidden from this account'
            }
            elseif ($paths.Count -eq 0 -and $processes.Count -eq 0) {
                $notReadReason = 'Defender returned no exclusions at all: either none are configured, or they are hidden by the HideExclusionsFromLocalAdmins policy - one reading cannot tell these apart'
            }

            if ($notReadReason) {
                $serverRows.Add([pscustomobject]@{
                    Server = $name; Status = 'Not assessed'; ExclusionPaths = ''; ExclusionProcesses = ''
                    PathCount = $paths.Count; ProcessCount = $processes.Count; MissingPathCount = 0; MissingProcessCount = 0
                    Reason = $notReadReason
                }) | Out-Null
                continue
            }

            $missingPaths     = @($requiredPaths     | Where-Object { -not (Test-ExchExclusionCovered -Token $_ -Configured $paths) })
            $missingProcesses = @($requiredProcesses | Where-Object { -not (Test-ExchExclusionCovered -Token $_ -Configured $processes) })

            $serverRows.Add([pscustomobject]@{
                Server           = $name
                Status           = 'Assessed'
                ExclusionPaths   = (ConvertTo-ExchFlatValue -Value $paths)
                ExclusionProcesses = (ConvertTo-ExchFlatValue -Value $processes)
                PathCount        = $paths.Count
                ProcessCount     = $processes.Count
                MissingPathCount = $missingPaths.Count
                MissingProcessCount = $missingProcesses.Count
                Reason           = ''
            }) | Out-Null

            foreach ($missing in $missingPaths) {
                $gapRows.Add([pscustomobject]@{ Server = $name; Kind = 'Path'; Missing = $missing }) | Out-Null
            }
            foreach ($missing in $missingProcesses) {
                $gapRows.Add([pscustomobject]@{ Server = $name; Kind = 'Process'; Missing = $missing }) | Out-Null
            }
        }
        catch {
            $null = Write-ExchError -Run $Run -Context ('Get-MpPreference on {0}' -f $name) -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
            $serverRows.Add([pscustomobject]@{
                Server = $name; Status = 'Not assessed'; ExclusionPaths = ''; ExclusionProcesses = ''
                PathCount = 0; ProcessCount = 0; MissingPathCount = 0; MissingProcessCount = 0
                Reason = [string]$_.Exception.Message
            }) | Out-Null
        }
    }

    $serverArr = @($serverRows.ToArray())
    $gapArr    = @($gapRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'security/av-exclusions.json' -ContentObject ([ordered]@{
        servers           = $serverArr
        gaps              = $gapArr
        requiredPaths     = $requiredPaths
        requiredProcesses = $requiredProcesses
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'security.av-exclusions' -Title 'Anti-Malware Exclusions by Server' -Area 'Mailbox' `
            -Columns @('Server', 'Status', 'PathCount', 'ProcessCount', 'MissingPathCount', 'MissingProcessCount', 'ExclusionPaths', 'ExclusionProcesses', 'Reason') `
            -Rows $serverArr

        New-ExchInventorySection -Run $Run -Key 'security.av-exclusion-gaps' -Title 'Missing Anti-Malware Exclusions' -Area 'Mailbox' `
            -Columns @('Server', 'Kind', 'Missing') `
            -Rows $gapArr
    )

    $assessed    = @($serverArr | Where-Object { $_.Status -eq 'Assessed' })
    $notAssessed = @($serverArr | Where-Object { $_.Status -ne 'Assessed' })
    $withGaps    = @($assessed | Where-Object { $_.MissingPathCount -gt 0 -or $_.MissingProcessCount -gt 0 })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($withGaps.Count -gt 0) {
        $problems.Add(("{0} of {1} assessed servers are missing recommended exclusions ({2} gaps in total): {3}" -f `
            $withGaps.Count, $assessed.Count, $gapArr.Count, `
            (($withGaps | ForEach-Object { "$($_.Server) missing $($_.MissingPathCount) paths and $($_.MissingProcessCount) processes" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($notAssessed.Count -gt 0) {
        $problems.Add(("{0} servers could not be assessed, so their exclusions are unknown: {1}" -f $notAssessed.Count, `
            (($notAssessed | ForEach-Object { "$($_.Server) - $($_.Reason)" }) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($assessed.Count -gt 0 -and $withGaps.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant' { 'High' }
        'Unknown'      { 'Medium' }
        default        { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else { ("All {0} servers have every recommended folder and process exclusion configured." -f $assessed.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($notAssessed.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Apply the Microsoft-recommended Exchange folder and process exclusions on every Exchange server. Where a third-party anti-malware product is in use, apply the equivalent exclusions in that product and confirm them manually.' `
        -Metrics @{
            serverCount    = $serverArr.Count
            assessedCount  = $assessed.Count
            serversWithGaps= $withGaps.Count
            totalGaps      = $gapArr.Count
            notAssessed    = $notAssessed.Count
        } `
        -Meta @{ dataSources = @{ Defender = @{ state = $(if ($notAssessed.Count -gt 0) { 'Partial' } else { 'Success' }); reason = $(if ($notAssessed.Count -gt 0) { 'Some servers unreachable or not running Microsoft Defender' } else { '' }) } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Test-ExchExclusionCovered {
    <#
    True when a configured exclusion covers the required token. Exclusions are compared
    case-insensitively as substrings, because installation paths differ per server.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter()][string[]]$Configured = @()
    )

    foreach ($entry in @($Configured)) {
        if (-not $entry) { continue }
        if ($entry -like ("*{0}*" -f $Token)) { return $true }
    }
    return $false
}

function Get-ExchExclusionView {
    <#
    The exclusion entries Defender actually returned, with nothing counted that is not one.

    @($null) has a Count of 1, and Defender returns $null for an empty list - on the first live
    run every server showed one path and one process exclusion, both empty. Entries that are
    $null or blank are dropped. An entry beginning 'N/A' is Defender's placeholder for a list the
    caller may not see ("N/A: Must be an administrator to view exclusions"); it is not an
    exclusion, and it marks the view as hidden.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object[]]$Paths = @(),
        [Parameter()][object[]]$Processes = @()
    )

    $hidden = $false
    $cleanPaths = New-Object System.Collections.Generic.List[string]
    $cleanProcesses = New-Object System.Collections.Generic.List[string]

    foreach ($pair in @(@{ Source = $Paths; Target = $cleanPaths }, @{ Source = $Processes; Target = $cleanProcesses })) {
        foreach ($entry in @($pair.Source)) {
            if ($null -eq $entry) { continue }
            $text = ([string]$entry).Trim()
            if (-not $text) { continue }
            if ($text -like 'N/A*') { $hidden = $true; continue }
            $pair.Target.Add($text) | Out-Null
        }
    }

    [pscustomobject]@{ Paths = @($cleanPaths.ToArray()); Processes = @($cleanProcesses.ToArray()); Hidden = $hidden }
}

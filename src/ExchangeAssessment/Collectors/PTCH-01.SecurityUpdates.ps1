<#
PTCH-01 - Security update state and emergency mitigations.

Two questions. Is the Exchange build current enough to have the published security fixes, which
comes from EX.CH-01's build assessment rather than being re-derived here? And is the Exchange
Emergency Mitigation Service present and applying mitigations, which is what protects a server
between a vulnerability becoming known and the update being installed?

Windows hotfix state is collected per server as supporting evidence for the patch cycle.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_PTCH_01_SecurityUpdates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][hashtable]$Upstream = @{}
    )

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'PTCH-01'

    $errors = New-Object System.Collections.Generic.List[string]
    $servers = @(Invoke-ExchQuery -Label 'Get-ExchangeServer' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-ExchangeServer -ErrorAction Stop })

    if ($servers.Count -eq 0) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control `
                -Reason ("No Exchange servers could be enumerated, so update state was not assessed: {0}" -f ($errors -join '; ')) `
                -Remediation 'Run from an Exchange Management Shell with rights to enumerate servers.'
        )
    }

    $maxHotfixAge = [int](Get-ExchThreshold -Run $Run -Name 'Patch.MaxHotfixAgeDays' -Default 60)
    $requireEems  = [bool](Get-ExchThreshold -Run $Run -Name 'Patch.RequireMitigationService' -Default $true)
    $now = Get-Date

    $hotfixRows = New-Object System.Collections.Generic.List[object]
    $serverRows = New-Object System.Collections.Generic.List[object]
    $unread     = New-Object System.Collections.Generic.List[string]

    foreach ($srv in $servers) {
        $name = [string]$srv.Name
        $latest = $null
        try {
            $hotfixes = @(Get-HotFix -ComputerName $name -ErrorAction Stop)
            foreach ($hf in $hotfixes) {
                $installed = $null
                try { if ($hf.InstalledOn) { $installed = [datetime]$hf.InstalledOn } } catch { $installed = $null }
                if ($installed -and ($null -eq $latest -or $installed -gt $latest)) { $latest = $installed }

                $hotfixRows.Add([pscustomobject]@{
                    Server      = $name
                    HotFixID    = [string]$hf.HotFixID
                    Description = [string]$hf.Description
                    InstalledOn = $installed
                    InstalledBy = [string]$hf.InstalledBy
                }) | Out-Null
            }
        }
        catch {
            $unread.Add($name) | Out-Null
            $errors.Add(("Get-HotFix on {0}: {1}" -f $name, $_.Exception.Message)) | Out-Null
            $null = Write-ExchError -Run $Run -Context ('Get-HotFix on {0}' -f $name) -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
        }

        $ageDays = $null
        if ($latest) { $ageDays = [math]::Round(($now - $latest).TotalDays, 1) }

        $serverRows.Add([pscustomobject]@{
            Server            = $name
            LatestHotfixDate  = $latest
            HotfixAgeDays     = $ageDays
            HotfixesRead      = @($hotfixRows | Where-Object { $_.Server -eq $name }).Count
            Reachable         = ($unread -notcontains $name)
        }) | Out-Null
    }

    $mitigations = @(Invoke-ExchQuery -Label 'Get-Mitigations' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-Mitigations -ErrorAction Stop })
    $mitigationRows = foreach ($m in $mitigations) {
        [pscustomobject]@{
            Server     = [string]$m.Server
            Identifier = [string]$m.Identifier
            Applied    = (ConvertTo-ExchFlatValue -Value $m.Applied)
            State      = [string]$m.State
        }
    }

    # EEMS on/off is a per-server Exchange setting.
    $eemsRows = foreach ($srv in $servers) {
        $enabled = $null
        $p = $srv.PSObject.Properties.Match('MitigationsEnabled') | Select-Object -First 1
        if ($p -and $null -ne $p.Value) { $enabled = [bool]$p.Value }
        [pscustomobject]@{
            Server             = [string]$srv.Name
            MitigationsEnabled = $enabled
            MitigationsApplied = (ConvertTo-ExchFlatValue -Value $(
                $a = $srv.PSObject.Properties.Match('MitigationsApplied') | Select-Object -First 1
                if ($a) { $a.Value } else { $null }))
        }
    }

    $serverArr     = @($serverRows.ToArray())
    $hotfixArr     = @($hotfixRows.ToArray())
    $mitigationArr = @($mitigationRows)
    $eemsArr       = @($eemsRows)

    # Build currency is EX.CH-01's answer; repeating the logic here would let the two drift.
    $buildFinding = $null
    if ($Upstream -and $Upstream.ContainsKey('EX.CH-01') -and $Upstream['EX.CH-01']) {
        $buildFinding = @($Upstream['EX.CH-01'].findings | Where-Object { $_.controlId -eq 'EX.CH-01' }) | Select-Object -First 1
    }

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'security/updates.json' -ContentObject ([ordered]@{
        servers            = $serverArr
        hotfixes           = $hotfixArr
        mitigations        = $mitigationArr
        mitigationSettings = $eemsArr
        buildOutcome       = $(if ($buildFinding) { $buildFinding.result.outcome } else { '' })
        errors             = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'security.update-state' -Title 'Server Update State' -Area 'Security' `
            -Columns @('Server', 'LatestHotfixDate', 'HotfixAgeDays', 'HotfixesRead', 'Reachable') -Rows $serverArr

        New-ExchInventorySection -Run $Run -Key 'security.hotfixes' -Title 'Installed Windows Updates' -Area 'Security' `
            -Columns @('Server', 'HotFixID', 'Description', 'InstalledOn', 'InstalledBy') -Rows $hotfixArr -HighCardinality

        New-ExchInventorySection -Run $Run -Key 'security.mitigations' -Title 'Emergency Mitigations' -Area 'Security' `
            -Columns @('Server', 'Identifier', 'Applied', 'State') -Rows $mitigationArr

        New-ExchInventorySection -Run $Run -Key 'security.mitigation-settings' -Title 'Emergency Mitigation Service Settings' -Area 'Security' `
            -Columns @('Server', 'MitigationsEnabled', 'MitigationsApplied') -Rows $eemsArr
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($buildFinding) {
        $buildOutcome = [string]$buildFinding.result.outcome
        # The upstream rationale is a finished sentence; strip its full stop before embedding so
        # the combined text does not end up with two.
        $buildReason = ([string]$buildFinding.result.rationale).TrimEnd('.', ' ')

        if ($buildOutcome -eq 'NonCompliant') {
            $problems.Add(("The Exchange build is not current or not supported, so published security fixes are missing. EX.CH-01 reported: {0}" -f $buildReason)) | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
        elseif ($buildOutcome -in @('PartiallyCompliant', 'Unknown')) {
            $problems.Add(("Exchange build currency is not confirmed. EX.CH-01 reported: {0}" -f $buildReason)) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }
        else {
            $outcomes.Add('Compliant') | Out-Null
        }
    }
    else {
        $problems.Add('The Exchange build assessment did not report, so security update currency could not be established') | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    if ($requireEems) {
        $eemsOff = @($eemsArr | Where-Object { $_.MitigationsEnabled -eq $false })
        $eemsUnknown = @($eemsArr | Where-Object { $null -eq $_.MitigationsEnabled })
        if ($eemsOff.Count -gt 0) {
            $problems.Add(("The Emergency Mitigation Service is disabled on {0} servers, so Microsoft cannot apply an interim mitigation before the next update: {1}" -f `
                $eemsOff.Count, (($eemsOff | ForEach-Object { $_.Server }) -join ', '))) | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
        elseif ($eemsUnknown.Count -eq $eemsArr.Count -and $eemsArr.Count -gt 0) {
            $problems.Add('The Emergency Mitigation Service state is not exposed by this Exchange version, so it could not be confirmed') | Out-Null
            $outcomes.Add('Unknown') | Out-Null
        }
    }

    $stalePatching = @($serverArr | Where-Object { $null -ne $_.HotfixAgeDays -and $_.HotfixAgeDays -gt $maxHotfixAge })
    if ($stalePatching.Count -gt 0) {
        $problems.Add(("{0} servers have installed no Windows update in more than {1} days, which suggests the patch cycle has stalled: {2}" -f `
            $stalePatching.Count, $maxHotfixAge, (($stalePatching | ForEach-Object { "$($_.Server) ($($_.HotfixAgeDays)d)" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($unread.Count -gt 0) {
        $problems.Add(("Update history could not be read on {0} servers: {1}" -f $unread.Count, ($unread -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'Critical' }
        'PartiallyCompliant' { 'High' }
        'Unknown'            { 'High' }
        default              { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else { ("The Exchange build carries current security updates, the Emergency Mitigation Service is enabled on all {0} servers, and Windows updates are being applied." -f $eemsArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($unread.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Apply the current Exchange cumulative update and security update to every server, and leave the Emergency Mitigation Service enabled so Microsoft can apply an interim mitigation when the next vulnerability is published. Exchange security updates are the most commonly exploited gap in an on-premises estate.' `
        -Metrics @{
            serverCount        = $serverArr.Count
            hotfixesRead       = $hotfixArr.Count
            mitigationsApplied = @($mitigationArr | Where-Object { $_.Applied -eq $true }).Count
            serversWithEemsOff = @($eemsArr | Where-Object { $_.MitigationsEnabled -eq $false }).Count
            stalePatchServers  = $stalePatching.Count
            buildOutcome       = $(if ($buildFinding) { [string]$buildFinding.result.outcome } else { 'Unknown' })
        } `
        -Meta @{ dataSources = @{
            Exchange = @{ state = 'Success'; reason = '' }
            WinRM    = @{ state = $(if ($unread.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($unread -join ', ') }
        }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

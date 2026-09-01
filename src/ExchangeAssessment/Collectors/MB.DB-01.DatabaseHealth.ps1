<#
MB.DB-01 - Mailbox database configuration, health and copy status.

Collects the database configuration an operator actually needs (paths, size, circular logging,
quotas, retention, last backup) and evaluates the three numbers that say whether a copy is
healthy right now: copy queue, replay queue and content index state.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_MB_DB_01_DatabaseHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'MB.DB-01'

    try { $databases = @(Get-MailboxDatabase -Status -ErrorAction Stop) }
    catch {
        $reason = "Get-MailboxDatabase failed, so no database was assessed: $($_.Exception.Message)"
        $null = Write-ExchError -Run $Run -Context 'Get-MailboxDatabase' -ErrorRecord $_ -ControlId $control.controlId
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason `
                -Remediation 'Run from an Exchange Management Shell with rights to query mailbox databases.'
        )
    }

    if ($databases.Count -eq 0) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control `
                -Reason 'Get-MailboxDatabase returned no databases, so database health could not be assessed.' `
                -Remediation 'Confirm the session is connected to the intended Exchange organisation.'
        )
    }

    $healthyStatuses  = @(Get-ExchThreshold -Run $Run -Name 'Database.HealthyCopyStatuses'  -Default @('Healthy', 'Mounted'))
    $healthyIndex     = @(Get-ExchThreshold -Run $Run -Name 'Database.HealthyContentIndex'  -Default @('Healthy'))
    $copyWarn         = [int](Get-ExchThreshold -Run $Run -Name 'Database.CopyQueueLengthWarning'    -Default 10)
    $copyCrit         = [int](Get-ExchThreshold -Run $Run -Name 'Database.CopyQueueLengthCritical'   -Default 100)
    $replayWarn       = [int](Get-ExchThreshold -Run $Run -Name 'Database.ReplayQueueLengthWarning'  -Default 10)
    $replayCrit       = [int](Get-ExchThreshold -Run $Run -Name 'Database.ReplayQueueLengthCritical' -Default 100)
    $maxBackupAgeDays = [int](Get-ExchThreshold -Run $Run -Name 'Database.MaxBackupAgeDays' -Default 7)
    $flagCircular     = [bool](Get-ExchThreshold -Run $Run -Name 'Database.FlagCircularLogging' -Default $true)
    $largeDbGb        = [int](Get-ExchThreshold -Run $Run -Name 'Database.LargeDatabaseGB' -Default 200)

    $dbRows   = New-Object System.Collections.Generic.List[object]
    $copyRows = New-Object System.Collections.Generic.List[object]
    $copyReadErrors = New-Object System.Collections.Generic.List[string]
    $now = Get-Date

    foreach ($db in $databases) {
        $sizeGb = $null
        try { if ($db.DatabaseSize) { $sizeGb = [math]::Round($db.DatabaseSize.ToBytes() / 1GB, 2) } } catch { $sizeGb = $null }

        $backupAgeDays = $null
        try { if ($db.LastFullBackup) { $backupAgeDays = [math]::Round(($now - [datetime]$db.LastFullBackup).TotalDays, 1) } } catch { $backupAgeDays = $null }

        $dbRows.Add([pscustomobject]@{
            Name                    = [string]$db.Name
            Server                  = [string]$db.Server
            Mounted                 = [bool]$db.Mounted
            SizeGB                  = $sizeGb
            EdbFilePath             = [string]$db.EdbFilePath
            LogFolderPath           = [string]$db.LogFolderPath
            CircularLoggingEnabled  = [bool]$db.CircularLoggingEnabled
            LastFullBackup          = $db.LastFullBackup
            BackupAgeDays           = $backupAgeDays
            ProhibitSendQuota       = [string]$db.ProhibitSendQuota
            ProhibitSendReceiveQuota= [string]$db.ProhibitSendReceiveQuota
            IssueWarningQuota       = [string]$db.IssueWarningQuota
            MailboxRetention        = [string]$db.MailboxRetention
            DeletedItemRetention    = [string]$db.DeletedItemRetention
            ActivationPreference    = (ConvertTo-ExchFlatValue -Value $db.ActivationPreference)
            MasterServerOrAvailabilityGroup = [string]$db.MasterServerOrAvailabilityGroup
        }) | Out-Null

        try {
            foreach ($copy in @(Get-MailboxDatabaseCopyStatus -Identity $db.Identity -ErrorAction Stop)) {
                $copyQueue = 0; $replayQueue = 0
                try { $copyQueue = [int]$copy.CopyQueueLength } catch { $copyQueue = 0 }
                try { $replayQueue = [int]$copy.ReplayQueueLength } catch { $replayQueue = 0 }

                $copyRows.Add([pscustomobject]@{
                    Database          = [string]$db.Name
                    Copy              = [string]$copy.Name
                    Status            = [string]$copy.Status
                    ActiveCopy        = [bool]$copy.ActiveCopy
                    CopyQueueLength   = $copyQueue
                    ReplayQueueLength = $replayQueue
                    ContentIndexState = [string]$copy.ContentIndexState
                    StatusHealthy     = ($healthyStatuses -contains [string]$copy.Status)
                    IndexHealthy      = ($healthyIndex -contains [string]$copy.ContentIndexState)
                }) | Out-Null
            }
        }
        catch {
            $copyReadErrors.Add(("{0}: {1}" -f $db.Name, $_.Exception.Message)) | Out-Null
            $null = Write-ExchError -Run $Run -Context ('Get-MailboxDatabaseCopyStatus on {0}' -f $db.Name) -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
        }
    }

    $dbArr   = @($dbRows.ToArray())
    $copyArr = @($copyRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'mailbox/databases.json' -ContentObject ([ordered]@{
        databases = $dbArr
        copies    = $copyArr
        copyReadErrors = @($copyReadErrors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'mailbox.databases' -Title 'Mailbox Databases' -Area 'Mailbox' `
            -Columns @('Name', 'Server', 'Mounted', 'SizeGB', 'EdbFilePath', 'LogFolderPath', 'CircularLoggingEnabled', 'LastFullBackup', 'BackupAgeDays', 'ProhibitSendQuota', 'ProhibitSendReceiveQuota', 'IssueWarningQuota', 'MailboxRetention', 'DeletedItemRetention', 'ActivationPreference', 'MasterServerOrAvailabilityGroup') `
            -Rows $dbArr

        New-ExchInventorySection -Run $Run -Key 'mailbox.database-copies' -Title 'Mailbox Database Copies' -Area 'Mailbox' `
            -Columns @('Database', 'Copy', 'Status', 'ActiveCopy', 'CopyQueueLength', 'ReplayQueueLength', 'ContentIndexState', 'StatusHealthy', 'IndexHealthy') `
            -Rows $copyArr
    )

    $unmounted    = @($dbArr | Where-Object { -not $_.Mounted })
    $noBackup     = @($dbArr | Where-Object { $null -eq $_.BackupAgeDays })
    $staleBackup  = @($dbArr | Where-Object { $null -ne $_.BackupAgeDays -and $_.BackupAgeDays -gt $maxBackupAgeDays })
    $circular     = @($dbArr | Where-Object { $_.CircularLoggingEnabled })
    $large        = @($dbArr | Where-Object { $null -ne $_.SizeGB -and $_.SizeGB -gt $largeDbGb })
    $badStatus    = @($copyArr | Where-Object { -not $_.StatusHealthy })
    $badIndex     = @($copyArr | Where-Object { -not $_.IndexHealthy })
    $copyCritical = @($copyArr | Where-Object { $_.CopyQueueLength -gt $copyCrit -or $_.ReplayQueueLength -gt $replayCrit })
    $copyWarning  = @($copyArr | Where-Object { ($_.CopyQueueLength -gt $copyWarn -or $_.ReplayQueueLength -gt $replayWarn) -and $_ -notin $copyCritical })

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($unmounted.Count -gt 0) {
        $problems.Add(("{0} databases are not mounted: {1}" -f $unmounted.Count, (($unmounted | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($badStatus.Count -gt 0) {
        $problems.Add(("{0} database copies are not in a healthy status: {1}" -f $badStatus.Count, (($badStatus | ForEach-Object { "$($_.Copy)=$($_.Status)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($copyCritical.Count -gt 0) {
        $problems.Add(("{0} copies exceed the critical queue thresholds (copy {1}, replay {2}): {3}" -f `
            $copyCritical.Count, $copyCrit, $replayCrit, (($copyCritical | ForEach-Object { "$($_.Copy) copy=$($_.CopyQueueLength) replay=$($_.ReplayQueueLength)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($staleBackup.Count -gt 0 -or $noBackup.Count -gt 0) {
        $detail = @()
        if ($staleBackup.Count -gt 0) { $detail += ("{0} databases have no full backup within {1} days: {2}" -f $staleBackup.Count, $maxBackupAgeDays, (($staleBackup | ForEach-Object { "$($_.Name) ($($_.BackupAgeDays)d)" }) -join ', ')) }
        if ($noBackup.Count -gt 0)    { $detail += ("{0} databases report no full backup at all: {1}" -f $noBackup.Count, (($noBackup | ForEach-Object { $_.Name }) -join ', ')) }
        $problems.Add(($detail -join '. ')) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($badIndex.Count -gt 0) {
        $problems.Add(("{0} copies have an unhealthy content index: {1}" -f $badIndex.Count, (($badIndex | ForEach-Object { "$($_.Copy)=$($_.ContentIndexState)" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($copyWarning.Count -gt 0) {
        $problems.Add(("{0} copies exceed the warning queue thresholds (copy {1}, replay {2})" -f $copyWarning.Count, $copyWarn, $replayWarn)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($flagCircular -and $circular.Count -gt 0) {
        $problems.Add(("{0} databases have circular logging enabled, which prevents point-in-time recovery from logs: {1}" -f $circular.Count, (($circular | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($large.Count -gt 0) {
        $problems.Add(("{0} databases exceed {1} GB and are worth reviewing against the recovery time objective: {2}" -f $large.Count, $largeDbGb, (($large | ForEach-Object { "$($_.Name) $($_.SizeGB)GB" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }
    if ($copyReadErrors.Count -gt 0) {
        $problems.Add(("Copy status could not be read for some databases: {0}" -f ($copyReadErrors -join '; '))) | Out-Null
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
                 else { ("All {0} databases are mounted with {1} healthy copies, healthy content indexes and a recent full backup." -f $dbArr.Count, $copyArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($copyReadErrors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Mount failed databases, resolve unhealthy copies and content indexes, clear replication backlogs, and confirm a working backup covers every database.' `
        -Metrics @{
            databaseCount   = $dbArr.Count
            copyCount       = $copyArr.Count
            unmounted       = $unmounted.Count
            unhealthyCopies = $badStatus.Count
            unhealthyIndex  = $badIndex.Count
            queueCritical   = $copyCritical.Count
            backupStale     = $staleBackup.Count
            backupMissing   = $noBackup.Count
            circularLogging = $circular.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($copyReadErrors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($copyReadErrors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

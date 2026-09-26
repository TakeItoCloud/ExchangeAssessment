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

    # -Status reads Mounted, DatabaseSize and LastFullBackup from each database's Information
    # Store. A store Exchange cannot reach is reported as a warning, not an error, and the
    # database still comes back with those fields empty. The warnings are captured so they reach
    # the report, and an empty Mounted is treated as not measured below.
    $statusWarnings = New-Object System.Collections.Generic.List[string]
    try {
        $databases = @(Invoke-ExchWithWarningCapture -Label 'Get-MailboxDatabase -Status' -Run $Run -ControlId $control.controlId `
            -Warnings $statusWarnings -Script { Get-MailboxDatabase -Status -ErrorAction Stop })
    }
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
        $dbName = [string](Get-ExchObjectValue -InputObject $db -Name 'Name' -Default '')

        # Mounted is three-state. $null means the Information Store did not answer, and every
        # other -Status field on that database is unmeasured with it; [bool]$null would report
        # the database as dismounted.
        $mounted = Get-ExchObjectBool -InputObject $db -Name 'Mounted'

        $sizeBytes = ConvertTo-ExchByteCount -Value (Get-ExchObjectValue -InputObject $db -Name 'DatabaseSize')
        $sizeGb = $(if ($null -ne $sizeBytes) { [math]::Round($sizeBytes / 1GB, 2) } else { $null })

        $lastFullBackup = Get-ExchObjectValue -InputObject $db -Name 'LastFullBackup'
        $backupAgeDays = $null
        try { if ($lastFullBackup) { $backupAgeDays = [math]::Round(($now - [datetime]$lastFullBackup).TotalDays, 1) } } catch { $backupAgeDays = $null }

        $dbRows.Add([pscustomobject]@{
            Name                    = $dbName
            Server                  = [string](Get-ExchObjectValue -InputObject $db -Name 'Server' -Default '')
            Mounted                 = $mounted
            StatusRead              = ($null -ne $mounted)
            SizeGB                  = $sizeGb
            EdbFilePath             = [string](Get-ExchObjectValue -InputObject $db -Name 'EdbFilePath' -Default '')
            LogFolderPath           = [string](Get-ExchObjectValue -InputObject $db -Name 'LogFolderPath' -Default '')
            CircularLoggingEnabled  = (Get-ExchObjectBool -InputObject $db -Name 'CircularLoggingEnabled')
            LastFullBackup          = $lastFullBackup
            BackupAgeDays           = $backupAgeDays
            ProhibitSendQuota       = [string](Get-ExchObjectValue -InputObject $db -Name 'ProhibitSendQuota' -Default '')
            ProhibitSendReceiveQuota= [string](Get-ExchObjectValue -InputObject $db -Name 'ProhibitSendReceiveQuota' -Default '')
            IssueWarningQuota       = [string](Get-ExchObjectValue -InputObject $db -Name 'IssueWarningQuota' -Default '')
            MailboxRetention        = [string](Get-ExchObjectValue -InputObject $db -Name 'MailboxRetention' -Default '')
            DeletedItemRetention    = [string](Get-ExchObjectValue -InputObject $db -Name 'DeletedItemRetention' -Default '')
            ActivationPreference    = (ConvertTo-ExchFlatValue -Value @(Get-ExchObjectValue -InputObject $db -Name 'ActivationPreference'))
            MasterServerOrAvailabilityGroup = [string](Get-ExchObjectValue -InputObject $db -Name 'MasterServerOrAvailabilityGroup' -Default '')
        }) | Out-Null

        if (-not $dbName) {
            $copyReadErrors.Add('A database was returned without a Name, so its copy status could not be requested.') | Out-Null
            continue
        }

        # The database is passed by name, a string. Over the remote session the Exchange
        # Management Shell uses, $db.Identity arrives as a deserialized ADObjectId that the
        # cmdlet's DatabaseCopyIdParameter cannot bind - measured on the first live run, which
        # logged 30 database failures of exactly that form. A database name returns all of its copies:
        # https://learn.microsoft.com/powershell/module/exchangepowershell/get-mailboxdatabasecopystatus?view=exchange-ps (read 2026-09-26).
        try {
            foreach ($copy in @(Get-MailboxDatabaseCopyStatus -Identity $dbName -ErrorAction Stop)) {
                # A queue length that cannot be read is $null, not 0: 0 is a healthy measurement.
                $copyQueue = $null; $replayQueue = $null
                try { $v = Get-ExchObjectValue -InputObject $copy -Name 'CopyQueueLength';   if ($null -ne $v) { $copyQueue = [int64]$v } } catch { $copyQueue = $null }
                try { $v = Get-ExchObjectValue -InputObject $copy -Name 'ReplayQueueLength'; if ($null -ne $v) { $replayQueue = [int64]$v } } catch { $replayQueue = $null }
                $status = [string](Get-ExchObjectValue -InputObject $copy -Name 'Status' -Default '')
                $indexState = [string](Get-ExchObjectValue -InputObject $copy -Name 'ContentIndexState' -Default '')

                $copyRows.Add([pscustomobject]@{
                    Database          = $dbName
                    Copy              = [string](Get-ExchObjectValue -InputObject $copy -Name 'Name' -Default '')
                    Status            = $status
                    ActiveCopy        = (Get-ExchObjectBool -InputObject $copy -Name 'ActiveCopy')
                    CopyQueueLength   = $copyQueue
                    ReplayQueueLength = $replayQueue
                    ContentIndexState = $indexState
                    StatusHealthy     = $(if ($status) { $healthyStatuses -contains $status } else { $null })
                    IndexHealthy      = $(if ($indexState) { $healthyIndex -contains $indexState } else { $null })
                }) | Out-Null
            }
        }
        catch {
            $copyReadErrors.Add(("{0}: {1}" -f $dbName, $_.Exception.Message)) | Out-Null
            $null = Write-ExchError -Run $Run -Context ('Get-MailboxDatabaseCopyStatus on {0}' -f $dbName) -ErrorRecord $_ -ControlId $control.controlId -Severity 'Warning'
        }
    }

    $dbArr   = @($dbRows.ToArray())
    $copyArr = @($copyRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'mailbox/databases.json' -ContentObject ([ordered]@{
        databases = $dbArr
        copies    = $copyArr
        copyReadErrors = @($copyReadErrors.ToArray())
        statusWarnings = @($statusWarnings.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'mailbox.databases' -Title 'Mailbox Databases' -Area 'Mailbox' `
            -Columns @('Name', 'Server', 'Mounted', 'StatusRead', 'SizeGB', 'EdbFilePath', 'LogFolderPath', 'CircularLoggingEnabled', 'LastFullBackup', 'BackupAgeDays', 'ProhibitSendQuota', 'ProhibitSendReceiveQuota', 'IssueWarningQuota', 'MailboxRetention', 'DeletedItemRetention', 'ActivationPreference', 'MasterServerOrAvailabilityGroup') `
            -Rows $dbArr

        New-ExchInventorySection -Run $Run -Key 'mailbox.database-copies' -Title 'Mailbox Database Copies' -Area 'Mailbox' `
            -Columns @('Database', 'Copy', 'Status', 'ActiveCopy', 'CopyQueueLength', 'ReplayQueueLength', 'ContentIndexState', 'StatusHealthy', 'IndexHealthy') `
            -Rows $copyArr
    )

    # Databases whose Information Store did not answer are judged on nothing that -Status
    # reads: not mounted state, not backup age, not size. They are reported as Unknown instead.
    $statusUnread = @($dbArr | Where-Object { -not $_.StatusRead })
    $statusDbs    = @($dbArr | Where-Object { $_.StatusRead })

    $unmounted    = @($statusDbs | Where-Object { $_.Mounted -eq $false })
    $noBackup     = @($statusDbs | Where-Object { $null -eq $_.BackupAgeDays })
    $staleBackup  = @($statusDbs | Where-Object { $null -ne $_.BackupAgeDays -and $_.BackupAgeDays -gt $maxBackupAgeDays })
    $circular     = @($dbArr | Where-Object { $_.CircularLoggingEnabled -eq $true })
    $large        = @($statusDbs | Where-Object { $null -ne $_.SizeGB -and $_.SizeGB -gt $largeDbGb })
    $badStatus    = @($copyArr | Where-Object { $_.StatusHealthy -eq $false })
    $badIndex     = @($copyArr | Where-Object { $_.IndexHealthy -eq $false })
    $copyUnread   = @($copyArr | Where-Object { $null -eq $_.StatusHealthy -or $null -eq $_.CopyQueueLength -or $null -eq $_.ReplayQueueLength })
    $copyCritical = @($copyArr | Where-Object { ($null -ne $_.CopyQueueLength -and $_.CopyQueueLength -gt $copyCrit) -or ($null -ne $_.ReplayQueueLength -and $_.ReplayQueueLength -gt $replayCrit) })
    $copyWarning  = @($copyArr | Where-Object { (($null -ne $_.CopyQueueLength -and $_.CopyQueueLength -gt $copyWarn) -or ($null -ne $_.ReplayQueueLength -and $_.ReplayQueueLength -gt $replayWarn)) -and $_ -notin $copyCritical })

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
    if ($statusUnread.Count -gt 0) {
        $problems.Add(("{0} databases returned no status from their Information Store, so whether they are mounted, their size and their last full backup were not measured: {1}" -f `
            $statusUnread.Count, (($statusUnread | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($copyUnread.Count -gt 0) {
        $problems.Add(("{0} database copies were returned without a status or queue length, so their health was not measured: {1}" -f `
            $copyUnread.Count, (($copyUnread | ForEach-Object { $_.Copy }) -join ', '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($statusWarnings.Count -gt 0) {
        $problems.Add(("Exchange warned while reading database status: {0}" -f ((@($statusWarnings) | Select-Object -Unique) -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $incomplete = ($copyReadErrors.Count -gt 0) -or ($statusUnread.Count -gt 0) -or ($copyUnread.Count -gt 0) -or ($statusWarnings.Count -gt 0)

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
        -Sufficiency $(if ($incomplete) { 'SoftFail' } else { 'Pass' }) `
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
            statusUnread    = $statusUnread.Count
            copiesUnread    = $copyUnread.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($incomplete) { 'Partial' } else { 'Success' }); reason = ((@($copyReadErrors) + @($statusWarnings)) -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

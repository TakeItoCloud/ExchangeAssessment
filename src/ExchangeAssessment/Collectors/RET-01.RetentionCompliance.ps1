<#
RET-01 - Retention, holds and audit configuration.

Whether the organisation can answer "what happened to this message" and "produce everything this
person sent". Retention policies and tags govern what is kept; administrator and mailbox audit
logging govern what is recorded about who did what.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_RET_01_RetentionCompliance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'RET-01'

    $errors = New-Object System.Collections.Generic.List[string]

    $policies  = @(Invoke-ExchQuery -Label 'Get-RetentionPolicy'      -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-RetentionPolicy -ErrorAction Stop })
    $tags      = @(Invoke-ExchQuery -Label 'Get-RetentionPolicyTag'   -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-RetentionPolicyTag -ErrorAction Stop })
    $auditCfg  = @(Invoke-ExchQuery -Label 'Get-AdminAuditLogConfig'  -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-AdminAuditLogConfig -ErrorAction Stop }) | Select-Object -First 1
    $journal   = @(Invoke-ExchQuery -Label 'Get-JournalRule'          -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-JournalRule -ErrorAction Stop })
    $bypass    = @(Invoke-ExchQuery -Label 'Get-MailboxAuditBypassAssociation' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-MailboxAuditBypassAssociation -ErrorAction Stop })

    $policyRows = foreach ($p in $policies) {
        [pscustomobject]@{
            Name              = [string]$p.Name
            IsDefault         = (ConvertTo-ExchFlatValue -Value $p.IsDefault)
            IsDefaultArbitrationMailbox = (ConvertTo-ExchFlatValue -Value $p.IsDefaultArbitrationMailbox)
            RetentionPolicyTagLinks = (ConvertTo-ExchFlatValue -Value $p.RetentionPolicyTagLinks)
            TagCount          = @($p.RetentionPolicyTagLinks).Count
        }
    }

    $tagRows = foreach ($t in $tags) {
        [pscustomobject]@{
            Name             = [string]$t.Name
            Type             = [string]$t.Type
            RetentionAction  = [string]$t.RetentionAction
            AgeLimitForRetention = [string]$t.AgeLimitForRetention
            RetentionEnabled = (ConvertTo-ExchFlatValue -Value $t.RetentionEnabled)
            MessageClass     = [string]$t.MessageClass
        }
    }

    $auditRow = $null
    if ($auditCfg) {
        $auditRow = [pscustomobject]@{
            AdminAuditLogEnabled   = (ConvertTo-ExchFlatValue -Value $auditCfg.AdminAuditLogEnabled)
            AdminAuditLogAgeLimit  = [string]$auditCfg.AdminAuditLogAgeLimit
            AdminAuditLogCmdlets   = (ConvertTo-ExchFlatValue -Value $auditCfg.AdminAuditLogCmdlets)
            LogLevel               = [string]$auditCfg.LogLevel
            TestCmdletLoggingEnabled = (ConvertTo-ExchFlatValue -Value $auditCfg.TestCmdletLoggingEnabled)
            UnifiedAuditLogIngestionEnabled = (ConvertTo-ExchFlatValue -Value $auditCfg.UnifiedAuditLogIngestionEnabled)
        }
    }

    $bypassRows = foreach ($b in $bypass) {
        [pscustomobject]@{
            Identity          = [string]$b.Identity
            AuditBypassEnabled= (ConvertTo-ExchFlatValue -Value $b.AuditBypassEnabled)
        }
    }
    $bypassEnabled = @($bypassRows | Where-Object { $_.AuditBypassEnabled -eq $true })

    $journalRows = foreach ($j in $journal) {
        [pscustomobject]@{
            Name                = [string]$j.Name
            Enabled             = (ConvertTo-ExchFlatValue -Value $j.Enabled)
            Scope               = [string]$j.Scope
            Recipient           = [string]$j.Recipient
            JournalEmailAddress = [string]$j.JournalEmailAddress
        }
    }

    $policyArr  = @($policyRows)
    $tagArr     = @($tagRows)
    $bypassArr  = @($bypassRows)
    $journalArr = @($journalRows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'compliance/retention.json' -ContentObject ([ordered]@{
        retentionPolicies = $policyArr
        retentionTags     = $tagArr
        adminAuditConfig  = $auditRow
        auditBypass       = $bypassArr
        journalRules      = $journalArr
        errors            = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'compliance.retention-policies' -Title 'Retention Policies' -Area 'Compliance' `
            -Columns @('Name', 'IsDefault', 'IsDefaultArbitrationMailbox', 'TagCount', 'RetentionPolicyTagLinks') -Rows $policyArr

        New-ExchInventorySection -Run $Run -Key 'compliance.retention-tags' -Title 'Retention Policy Tags' -Area 'Compliance' `
            -Columns @('Name', 'Type', 'RetentionAction', 'AgeLimitForRetention', 'RetentionEnabled', 'MessageClass') -Rows $tagArr -HighCardinality

        New-ExchInventorySection -Run $Run -Key 'compliance.audit-configuration' -Title 'Administrator Audit Configuration' -Area 'Compliance' `
            -Columns @('AdminAuditLogEnabled', 'AdminAuditLogAgeLimit', 'LogLevel', 'TestCmdletLoggingEnabled', 'UnifiedAuditLogIngestionEnabled', 'AdminAuditLogCmdlets') `
            -Rows @($auditRow | Where-Object { $null -ne $_ })

        New-ExchInventorySection -Run $Run -Key 'compliance.audit-bypass' -Title 'Mailbox Audit Bypass' -Area 'Compliance' `
            -Columns @('Identity', 'AuditBypassEnabled') -Rows $bypassArr -HighCardinality

        New-ExchInventorySection -Run $Run -Key 'compliance.journal-rules' -Title 'Journal Rules' -Area 'Compliance' `
            -Columns @('Name', 'Enabled', 'Scope', 'Recipient', 'JournalEmailAddress') -Rows $journalArr
    )

    $requirePolicy = [bool](Get-ExchThreshold -Run $Run -Name 'Compliance.RequireRetentionPolicy' -Default $true)
    $requireAudit  = [bool](Get-ExchThreshold -Run $Run -Name 'Compliance.RequireAdminAuditLogging' -Default $true)
    $minAuditDays  = [int](Get-ExchThreshold -Run $Run -Name 'Compliance.MinAdminAuditLogAgeDays' -Default 90)

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($requirePolicy -and $policyArr.Count -eq 0) {
        $problems.Add('No retention policy is defined, so nothing governs how long mail is kept') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    elseif ($requirePolicy -and @($policyArr | Where-Object { $_.IsDefault -eq $true }).Count -eq 0) {
        $problems.Add(("{0} retention policies exist but none is marked default, so new mailboxes get no retention" -f $policyArr.Count)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $emptyPolicies = @($policyArr | Where-Object { $_.TagCount -eq 0 })
    if ($emptyPolicies.Count -gt 0) {
        $problems.Add(("{0} retention policies have no tags linked and therefore do nothing: {1}" -f $emptyPolicies.Count, `
            (($emptyPolicies | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($requireAudit) {
        if ($null -eq $auditRow) {
            $problems.Add('The administrator audit log configuration could not be read, so it is not known whether administrative changes are recorded') | Out-Null
            $outcomes.Add('Unknown') | Out-Null
        }
        elseif ($auditRow.AdminAuditLogEnabled -ne $true) {
            $problems.Add('Administrator audit logging is disabled, so changes made by administrators are not recorded') | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
        else {
            $ageDays = Convert-ExchDurationToDays -Duration $auditRow.AdminAuditLogAgeLimit
            if ($null -ne $ageDays -and $ageDays -lt $minAuditDays) {
                $problems.Add(("The administrator audit log is kept for {0} days, below the {1} day minimum" -f $ageDays, $minAuditDays)) | Out-Null
                $outcomes.Add('PartiallyCompliant') | Out-Null
            }
        }
    }

    if ($bypassEnabled.Count -gt 0) {
        $problems.Add(("{0} accounts have mailbox audit bypass enabled, so their mailbox access is not logged: {1}" -f $bypassEnabled.Count, `
            (($bypassEnabled | ForEach-Object { $_.Identity }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($errors.Count -gt 0) {
        $problems.Add(("Some compliance configuration could not be read: {0}" -f ($errors -join '; '))) | Out-Null
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
                 else { ("{0} retention policies and {1} tags are defined, administrator audit logging is enabled, and no account bypasses mailbox auditing." -f `
                        $policyArr.Count, $tagArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Define a default retention policy with tags linked to it, enable administrator audit logging with a retention period that matches the organisation record-keeping requirement, and remove mailbox audit bypass from any account that does not genuinely need it.' `
        -Metrics @{
            retentionPolicies = $policyArr.Count
            retentionTags     = $tagArr.Count
            adminAuditEnabled = $(if ($auditRow) { $auditRow.AdminAuditLogEnabled } else { $null })
            auditBypassCount  = $bypassEnabled.Count
            journalRules      = $journalArr.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

function Convert-ExchDurationToDays {
    <#
    Exchange duration values print as '90.00:00:00' or 'Unlimited'. Returns whole days, or $null
    when there is no finite limit.
    #>
    [CmdletBinding()]
    param([Parameter()]$Duration)

    if ($null -eq $Duration) { return $null }
    $text = ([string]$Duration).Trim()
    if (-not $text -or $text -match 'Unlimited') { return $null }

    try { return [math]::Round(([timespan]::Parse($text)).TotalDays, 1) }
    catch { return $null }
}

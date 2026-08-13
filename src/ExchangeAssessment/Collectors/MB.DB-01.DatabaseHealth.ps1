<#
MB.DB-01 - Mailbox database health and copy status.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_MB_DB_01_DatabaseHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'MB.DB-01'

    $dbs = @()
    try { $dbs = Get-MailboxDatabase -Status -ErrorAction Stop }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'Get-MailboxDatabase failed' -Data @{ error=$_.Exception.Message }
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'High' -Title $control.title -Description $control.target -Evidence @() -Remediation 'Run from Exchange Management Shell with rights to query Get-MailboxDatabase.' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale 'Unable to enumerate mailbox databases.' -Metrics @{ error=$_.Exception.Message } -Meta @{ dataSources = @{ Exchange = @{ state='Error'; reason=$_.Exception.Message } }; evaluationStatus = 'Partial' }
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($db in @($dbs)) {
        $copyInfo = @()
        try { $copyInfo = Get-MailboxDatabaseCopyStatus -Identity $db.Identity -ErrorAction Stop }
        catch {
            $copyInfo = @()
        }

        $records.Add([pscustomobject]@{
            name       = $db.Name
            server     = $db.Server
            mounted    = [bool]$db.Mounted
            copies     = @($copyInfo | Select-Object Name, Status, CopyQueueLength, ReplayQueueLength, ContentIndexState, ActiveCopy)
            activation = $db.ActivationPreference
        }) | Out-Null
    }

    $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'mailbox/databases.json' -ContentObject $records

    $unmounted = @($records | Where-Object { $_.mounted -ne $true })
    $copyIssues = @($records | ForEach-Object { $_.copies } | Where-Object { $_ -and $_.Status -notmatch 'Healthy|Mounted' })

    $outcome = 'Compliant'
    $sev = 'Medium'
    $suff = 'Pass'
    $rat = 'All mailbox databases report mounted and healthy copies.'

    if ($records.Count -eq 0) {
        $outcome = 'Unknown'
        $sev = 'High'
        $suff = 'HardFail'
        $rat = 'No mailbox databases returned.'
    }
    elseif ($unmounted.Count -gt 0 -or $copyIssues.Count -gt 0) {
        $outcome = 'NonCompliant'
        $sev = 'High'
        $rat = 'One or more databases are dismounted or have unhealthy copies.'
    }

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence @($evidencePath) `
        -Remediation 'Ensure mailbox databases are mounted and copies healthy; investigate copy/CI/queue issues.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{ total=$records.Count; unmounted=$unmounted.Count; copyIssues=$copyIssues.Count } `
        -Meta @{ dataSources = @{ Exchange = @{ state='Success'; reason='' } }; evaluationStatus = 'Complete' }
}

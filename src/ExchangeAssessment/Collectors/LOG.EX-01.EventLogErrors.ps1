<#
LOG.EX-01 - Recent Exchange-related event log errors.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_LOG_EX_01_EventLogErrors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][int]$HoursBack = 24,
        [Parameter()][int]$MaxEvents = 200
    )

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'LOG.EX-01'

    $since = (Get-Date).AddHours(-1 * $HoursBack)
    $providers = @(
        'MSExchange*','MSExchangeIS','MSExchangeTransport','MSExchangeCommon',
        'MSExchange ADAccess','FIPFS','MSFilteringEngine','IIS-W3SVC-WP'
    )

    $filter = @{
        LogName   = @('Application','System')
        Level     = 1,2  # Critical, Error
        StartTime = $since
    }

    $events = @()
    try {
        $events = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop |
            Where-Object { $p = $_.ProviderName; foreach ($pat in $providers) { if ($p -like $pat) { return $true } }; return $false } |
            Select-Object -First $MaxEvents |
            ForEach-Object {
                $msg = $_.Message
                if ($msg.Length -gt 1024) { $msg = $msg.Substring(0,1024) + '...' }
                [pscustomobject]@{
                    timeCreated = $_.TimeCreated
                    level       = $_.LevelDisplayName
                    id          = $_.Id
                    provider    = $_.ProviderName
                    log         = $_.LogName
                    machine     = $_.MachineName
                    message     = $msg
                }
            }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'LOG.EX-01 event query failed' -Data @{ error=$_.Exception.Message }
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'High' -Title $control.title -Description $control.target -Evidence @() -Remediation 'Ensure local event logs are accessible and queryable; rerun the assessment.' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale 'Unable to query event logs.' -Metrics @{ error=$_.Exception.Message } -Meta @{ dataSources = @{ Events = @{ state='Error'; reason=$_.Exception.Message } }; evaluationStatus = 'Partial' }
    }

    $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'logs/exchange-event-errors.json' -ContentObject $events

    $total = @($events).Count
    $byProvider = @{}
    foreach ($e in @($events)) {
        $key = $e.provider
        if (-not $byProvider.ContainsKey($key)) { $byProvider[$key] = 0 }
        $byProvider[$key] += 1
    }

    $outcome = 'Compliant'
    $sev = 'Low'
    $suff = 'Pass'
    $rat = 'No critical/error events found in the review window.'
    if ($total -gt 0) {
        $outcome = 'NonCompliant'
        $sev = 'High'
        $rat = ("{0} recent error/critical events detected in the last {1} hours." -f $total, $HoursBack)
    }

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence @($evidencePath) `
        -Remediation 'Investigate and resolve recurring Exchange-related error/critical events in Application/System logs; confirm services are healthy.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{ total=$total; windowHours=$HoursBack; byProvider=$byProvider } `
        -Meta @{ dataSources = @{ Events = @{ state='Success'; reason='' } }; evaluationStatus = 'Complete' }
}

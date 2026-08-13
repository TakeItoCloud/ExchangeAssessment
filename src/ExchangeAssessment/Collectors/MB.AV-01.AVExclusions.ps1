<#
MB.AV-01 - Exchange AV exclusions.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_MB_AV_01_AVExclusions {
    # $recommendedTokens records the Microsoft-recommended exclusion paths, but nothing
    # compares the collected exclusions against them yet - the collector reports what is
    # configured, not what is missing. Kept as the specification for that check. PORT-PLAN P4.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'recommendedTokens')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'MB.AV-01'

    $servers = @()
    try { $servers = Get-ExchangeServer -ErrorAction Stop }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'Get-ExchangeServer failed for AV exclusions' -Data @{ error=$_.Exception.Message }
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'High' -Title $control.title -Description $control.target -Evidence @() -Remediation 'Run from EMS with rights to enumerate Exchange servers.' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale 'Unable to enumerate Exchange servers for AV exclusions.' -Metrics @{ error=$_.Exception.Message } -Meta @{ dataSources = @{ Exchange = @{ state='Error'; reason=$_.Exception.Message } }; evaluationStatus = 'Partial' }
    }

    $records = New-Object System.Collections.Generic.List[object]
    $recommendedTokens = @('Microsoft\\Exchange Server', 'TransportRoles', 'ClientAccess')

    foreach ($srv in @($servers)) {
        $result = $null
        $status = 'Success'
        $reason = ''
        try {
            $sb = { try { Get-MpPreference } catch { $null } }
            $mp = Invoke-Command -ComputerName $srv.Name -ScriptBlock $sb -ErrorAction Stop
            $result = $mp
            if (-not $mp) { $status = 'Missing'; $reason = 'Get-MpPreference returned null (Defender not available?)' }
        }
        catch {
            $status = 'Error'
            $reason = $_.Exception.Message
        }

        $records.Add([pscustomobject]@{
            server         = $srv.Name
            status         = $status
            reason         = $reason
            exclusionPaths = if ($result) { $result.ExclusionPath } else { @() }
            exclusionProc  = if ($result) { $result.ExclusionProcess } else { @() }
        }) | Out-Null
    }

    $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'security/av-exclusions.json' -ContentObject $records

    $missingData = @($records | Where-Object { $_.status -ne 'Success' })
    $noExchExclusions = @($records | Where-Object { ($_.exclusionPaths + $_.exclusionProc) -notmatch 'Exchange' })

    $outcome = 'Compliant'
    $sev = 'Medium'
    $suff = if ($missingData.Count -gt 0) { 'SoftFail' } else { 'Pass' }
    $rat = 'Defender exclusions collected; Exchange-related exclusions present.'

    if ($records.Count -eq 0) {
        $outcome = 'Unknown'
        $sev = 'High'
        $suff = 'HardFail'
        $rat = 'No Exchange servers inspected for AV exclusions.'
    }
    elseif ($noExchExclusions.Count -gt 0) {
        $outcome = 'PartiallyCompliant'
        $sev = 'High'
        $rat = 'One or more servers missing Exchange-related AV exclusions.'
    }
    elseif ($missingData.Count -gt 0) {
        $outcome = 'PartiallyCompliant'
        $rat = 'Some servers did not return Defender preferences.'
    }

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence @($evidencePath) `
        -Remediation 'Configure required Exchange AV exclusions on all servers (processes and paths); ensure Defender/AV reporting is available.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{ servers=$records.Count; missingData=$missingData.Count; missingExchangeExclusions=$noExchExclusions.Count } `
        -Meta @{ dataSources = @{ WinRM = @{ state= if($missingData.Count -gt 0){'Partial'} else {'Success'} ; reason = if($missingData.Count -gt 0){'Some servers unavailable'} else {''} } }; evaluationStatus = 'Complete' }
}

<#
ENV.OS-01 - Exchange server OS versions and supportability.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_ENV_OS_01_ExchangeOS {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'ENV.OS-01'

    $servers = @()
    try { $servers = Get-ExchangeServer -ErrorAction Stop }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'Get-ExchangeServer failed' -Data @{ error=$_.Exception.Message }
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'High' -Title $control.title -Description $control.target -Evidence @() -Remediation 'Run from an Exchange Management Shell with permissions to enumerate servers.' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale 'Unable to enumerate Exchange servers.' -Metrics @{ error=$_.Exception.Message } -Meta @{ dataSources = @{ Exchange = @{ state='Error'; reason=$_.Exception.Message } }; evaluationStatus = 'Partial' }
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($srv in @($servers)) {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $srv.Name -ErrorAction Stop
            $records.Add([pscustomobject]@{
                server        = $srv.Name
                edition       = $os.Caption
                version       = $os.Version
                buildNumber   = $os.BuildNumber
                lastBoot      = $os.LastBootUpTime
                error         = $null
            }) | Out-Null
        }
        catch {
            $records.Add([pscustomobject]@{
                server        = $srv.Name
                edition       = $null
                version       = $null
                buildNumber   = $null
                lastBoot      = $null
                error         = $_.Exception.Message
            }) | Out-Null
        }
    }

    $recArr = @($records.ToArray())
    $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'environment/exchange-os.json' -ContentObject $recArr

    $min2016 = [version]'10.0.14393'
    $pref2022 = [version]'10.0.20348'

    $errors = @($recArr | Where-Object { $_.error })
    $unsupported = @()
    $below2022 = @()
    foreach ($r in $recArr) {
        if ($r.version) {
            $verObj = $null
            try { $verObj = [version][string]$r.version } catch { $verObj = $null }
            if ($verObj) {
                if ($verObj -lt $min2016) { $unsupported += $r; continue }
                if ($verObj -lt $pref2022) { $below2022 += $r; continue }
            }
        }
    }

    $outcome = 'Unknown'
    $sev = 'Medium'
    $suff = if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }
    $rat = ''

    if ($recArr.Count -eq 0) {
        $outcome = 'Unknown'
        $suff = 'HardFail'
        $sev = 'High'
        $rat = 'No Exchange servers returned from Get-ExchangeServer.'
    }
    elseif ($unsupported.Count -gt 0) {
        $outcome = 'NonCompliant'
        $sev = 'High'
        $rat = 'One or more Exchange servers run below Windows Server 2016.'
    }
    elseif ($below2022.Count -gt 0 -or $errors.Count -gt 0) {
        $outcome = 'PartiallyCompliant'
        $rat = 'Not all servers are on Windows Server 2022 or some OS details could not be retrieved.'
    }
    else {
        $outcome = 'Compliant'
        $rat = 'All Exchange servers report Windows Server 2022+.'
    }

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence @($evidencePath) `
        -Remediation 'Plan OS upgrades to Windows Server 2022 for all Exchange servers; resolve WinRM issues preventing OS discovery.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{ servers = $recArr } `
        -Meta @{ dataSources = @{ Exchange = @{ state='Success'; reason='' }; WinRM = @{ state= if($errors.Count -gt 0){'Partial'} else {'Success'} ; reason = if($errors.Count -gt 0){ 'Some servers failed OS query' } else { '' } } }; evaluationStatus = 'Complete' }
}

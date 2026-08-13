<#
EX.CH-01 - Exchange build/CU currency.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_EX_CH_01_ExchangeVersionCU {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'EX.CH-01'

    $servers = @()
    try { $servers = Get-ExchangeServer -ErrorAction Stop }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'Get-ExchangeServer failed' -Data @{ error=$_.Exception.Message }
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'High' -Title $control.title -Description $control.target -Evidence @() -Remediation 'Run from Exchange Management Shell with rights to enumerate servers.' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale 'Unable to read Exchange server versions.' -Metrics @{ error=$_.Exception.Message } -Meta @{ dataSources = @{ Exchange = @{ state='Error'; reason=$_.Exception.Message } }; evaluationStatus = 'Partial' }
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($srv in @($servers)) {
        $records.Add([pscustomobject]@{
            server  = $srv.Name
            edition = $srv.Edition
            adminDisplayVersion = $srv.AdminDisplayVersion.ToString()
            major   = $srv.AdminDisplayVersion.Major
            minor   = $srv.AdminDisplayVersion.Minor
            build   = $srv.AdminDisplayVersion.Build
        }) | Out-Null
    }

    $recArr = @($records.ToArray())
    $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'exchange/builds.json' -ContentObject $recArr

    $outcome = 'Unknown'
    $sev = 'High'
    $suff = 'Pass'
    $rat = ''

    if ($recArr.Count -eq 0) {
        $outcome = 'Unknown'
        $suff = 'HardFail'
        $rat = 'No Exchange servers returned.'
    }
    else {
        $majors = @($recArr | Select-Object -ExpandProperty major -Unique)
        $hasLegacy = @($majors | Where-Object { $_ -lt 15 })
        $has2016 = @($recArr | Where-Object { $_.major -eq 15 -and $_.minor -lt 2 })
        $has2019 = @($recArr | Where-Object { $_.major -eq 15 -and $_.minor -ge 2 })

        if ($hasLegacy.Count -gt 0) {
            $outcome = 'NonCompliant'
            $rat = 'One or more servers below Exchange 2016.'
        }
        elseif ($has2016.Count -gt 0 -and $has2019.Count -gt 0) {
            $outcome = 'PartiallyCompliant'
            $rat = 'Mixed Exchange 2016/2019 estate; align on supported build/CU.'
        }
        elseif ($has2016.Count -gt 0) {
            $outcome = 'NonCompliant'
            $rat = 'All servers on Exchange 2016; plan upgrade to supported 2019 CU for SE readiness.'
        }
        elseif ($has2019.Count -gt 0) {
            $outcome = 'PartiallyCompliant'
            $sev = 'Medium'
            $rat = 'Exchange 2019 detected; verify CU is current (latest or -1) and security updates applied.'
        }
    }

    return New-ExchFinding `
        -ControlDomain $control.domain `
        -ControlId $control.controlId `
        -Severity $sev `
        -Title $control.title `
        -Description $control.target `
        -Evidence @($evidencePath) `
        -Remediation 'Standardize on supported Exchange 2019 CU (latest or -1) with security updates before progressing to Subscription Edition.' `
        -FrameworkMappings $control.mappings `
        -Outcome $outcome `
        -Sufficiency $suff `
        -Rationale $rat `
        -Metrics @{ servers = $recArr } `
        -Meta @{ dataSources = @{ Exchange = @{ state='Success'; reason='' } }; evaluationStatus = 'Complete' }
}

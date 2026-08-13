<#
Dispatcher for Exchange Assessment collectors (phase 1-2 set).
#>

function Invoke-ExchCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][switch]$SkipDomainQueries
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $findings = New-Object System.Collections.Generic.List[object]
    $domainFinding = $null
    $osFinding = $null
    $exchFinding = $null

    try { Ensure-ExchLocalShell -Run $Run } catch { Write-ExchEvent -Run $Run -Level ERROR -Message 'Exchange cmdlets unavailable' -Data @{ error = $_.Exception.Message } }

    if ($SkipDomainQueries) {
        Write-ExchEvent -Run $Run -Level WARN -Message 'Skipping domain/forest/schema collector' -Data @{}
    }
    else {
        try {
            $domainFinding = Invoke-ExchCollector_ENV_VERS_01_DomainForestSchema -Run $Run
            if ($domainFinding) { $findings.Add($domainFinding) | Out-Null }
        }
        catch {
            Write-ExchEvent -Run $Run -Level ERROR -Message 'ENV.VERS-01 collector failed' -Data @{ error=$_.Exception.Message }
        }
    }

    try {
        $osFinding = Invoke-ExchCollector_ENV_OS_01_ExchangeOS -Run $Run
        if ($osFinding) { $findings.Add($osFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'ENV.OS-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $exchFinding = Invoke-ExchCollector_EX_CH_01_ExchangeVersionCU -Run $Run
        if ($exchFinding) { $findings.Add($exchFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'EX.CH-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $upgFinding = Invoke-ExchCollector_UPG_01_SEReadiness -Run $Run -DomainFinding $domainFinding -OsFinding $osFinding -ExchangeFinding $exchFinding
        if ($upgFinding) { $findings.Add($upgFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'UPG-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $dbFinding = Invoke-ExchCollector_MB_DB_01_DatabaseHealth -Run $Run
        if ($dbFinding) { $findings.Add($dbFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'MB.DB-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $dagFinding = Invoke-ExchCollector_DAG_01_DagHealth -Run $Run
        if ($dagFinding) { $findings.Add($dagFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'DAG-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $connFinding = Invoke-ExchCollector_TR_CO_01_TransportConnectors -Run $Run
        if ($connFinding) { $findings.Add($connFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'TR.CO-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $certFinding = Invoke-ExchCollector_CERT_01_Certificates -Run $Run
        if ($certFinding) { $findings.Add($certFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'CERT-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $avFinding = Invoke-ExchCollector_MB_AV_01_AVExclusions -Run $Run
        if ($avFinding) { $findings.Add($avFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'MB.AV-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $spamFinding = Invoke-ExchCollector_AA_SPAM_01_AntiMalwareSpam -Run $Run
        if ($spamFinding) { $findings.Add($spamFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'AA.SPAM-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $hybFinding = Invoke-ExchCollector_HYB_01_HybridConfig -Run $Run
        if ($hybFinding) { $findings.Add($hybFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'HYB-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $syncFinding = Invoke-ExchCollector_ID_SYNC_01_AADConnectStatus -Run $Run
        if ($syncFinding) { $findings.Add($syncFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'ID.SYNC-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $logFinding = Invoke-ExchCollector_LOG_EX_01_EventLogErrors -Run $Run
        if ($logFinding) { $findings.Add($logFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'LOG.EX-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $admFinding = Invoke-ExchCollector_EX_ADM_01_AcceptedDomains -Run $Run
        if ($admFinding) { $findings.Add($admFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'EX.ADM-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    try {
        $vdirFinding = Invoke-ExchCollector_EX_VDIR_01_VirtualDirectories -Run $Run
        if ($vdirFinding) { $findings.Add($vdirFinding) | Out-Null }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'EX.VDIR-01 collector failed' -Data @{ error=$_.Exception.Message }
    }

    return $findings.ToArray()
}

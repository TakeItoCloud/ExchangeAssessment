<#!
Entry point for Exchange On-Prem/Hybrid Assessment.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantHint,
    [Parameter()][ValidateNotNullOrEmpty()][string]$OutputRoot = (Join-Path $PSScriptRoot '..\output'),
    [Parameter()][switch]$SkipDomainQueries
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$run = $null

try {
    $modulePath = Join-Path $PSScriptRoot '..\src\ExchangeAssessment\ExchangeAssessment.psd1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $run = New-ExchRun -OutputRoot $OutputRoot -TenantHint $TenantHint

    try {
        $pre = Get-ExchPreflightReport
        if ($pre -and $pre.warnings) {
            foreach ($w in $pre.warnings) {
                Write-Warning $w
                try { Write-ExchEvent -Run $run -Level WARN -Message 'Preflight' -Data @{ warning=$w } } catch { }
            }
        }
    } catch { }

    try {
        Write-ExchEvent -Run $run -Level INFO -Message 'Invoke-ExchAssess started' -Data @{
            tenantHint = $TenantHint
            outputRoot = $OutputRoot
            pwsh       = $PSVersionTable.PSVersion.ToString()
            host       = $env:COMPUTERNAME
            user       = $env:USERNAME
            skipDomain = [bool]$SkipDomainQueries.IsPresent
        }
    } catch { }

    $findings = Invoke-ExchCollection -Run $run -SkipDomainQueries:$SkipDomainQueries

    # Persist findings (always)
    $findingsPath = Save-ExchFindings -Run $run -Findings @($findings)

    # Close run
    Close-ExchRun -Run $run | Out-Null

    # Export bundle
    $zip = Export-ExchEvidenceBundle -Run $run -Findings @($findings)

    [pscustomobject]@{
        FindingsCount = @($findings).Count
        FindingsPath  = $findingsPath
        BundleZip     = $zip
        RunFolder     = $run.RunFolder
        HashManifest  = (Join-Path $run.RunFolder 'hash-manifest.json')
    }
}
catch {
    try {
        if ($run) {
            Write-ExchEvent -Run $run -Level ERROR -Message 'Invoke-ExchAssess failed' -Data @{ error=$_.Exception.Message; stack=$_.ScriptStackTrace }
            try { Close-ExchRun -Run $run } catch { }
        }
    } catch { }
    throw
}

<#!
Entry point for Exchange On-Prem/Hybrid Assessment.

Read-only against Exchange and Active Directory. Every write goes to the run folder.

Order matters: the reports are generated before the run is closed, so the SHA256 hash manifest
covers the CSV and JSON output as well as the raw evidence. The ZIP is built last, after the
manifest exists.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantHint,
    [Parameter()][ValidateNotNullOrEmpty()][string]$OutputRoot = (Join-Path $PSScriptRoot '..\output'),
    [Parameter()][switch]$SkipDomainQueries,
    # A .psd1 whose keys override Config/Thresholds.psd1 for this client.
    [Parameter()][string]$ConfigPath,
    # Put every inventory row in assessment.json instead of summarising the large sections.
    [Parameter()][switch]$FullInventory,
    [Parameter()][switch]$IncludeExchangeOnline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$run = $null

try {
    $modulePath = Join-Path $PSScriptRoot '..\src\ExchangeAssessment\ExchangeAssessment.psd1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $run = New-ExchRun -OutputRoot $OutputRoot -TenantHint $TenantHint -ConfigPath $ConfigPath `
        -FullInventory:$FullInventory -IncludeExchangeOnline:$IncludeExchangeOnline

    try {
        $pre = Get-ExchPreflightReport
        if ($pre -and $pre.warnings) {
            foreach ($w in $pre.warnings) {
                Write-Warning $w
                Write-ExchEvent -Run $run -Level WARN -Message 'Preflight' -Data @{ warning = $w }
            }
        }
    }
    catch {
        Write-Warning ("Preflight check failed: {0}" -f $_.Exception.Message)
    }

    Write-ExchEvent -Run $run -Level INFO -Message 'Invoke-ExchAssess started' -Data @{
        tenantHint    = $TenantHint
        outputRoot    = $OutputRoot
        pwsh          = $PSVersionTable.PSVersion.ToString()
        host          = $env:COMPUTERNAME
        user          = $env:USERNAME
        skipDomain    = [bool]$SkipDomainQueries.IsPresent
        fullInventory = [bool]$FullInventory.IsPresent
        includeCloud  = [bool]$IncludeExchangeOnline.IsPresent
    }

    $collection = Invoke-ExchCollection -Run $run -SkipDomainQueries:$SkipDomainQueries

    # Reports first, so the hash manifest covers them.
    $findingsPath = Save-ExchFindings -Run $run -Findings @($collection.Findings)
    $csvPaths     = Export-ExchCsvReport -Run $run -Sections @($collection.Sections) -Findings @($collection.Findings)
    $jsonPath     = New-ExchAssessmentJson -Run $run -Sections @($collection.Sections) -Findings @($collection.Findings) -Collection $collection
    $null         = Export-ExchControlSnapshot -Run $run

    $manifestPath = Close-ExchRun -Run $run

    $zip = Export-ExchEvidenceBundle -Run $run

    [pscustomobject]@{
        FindingsCount     = @($collection.Findings).Count
        SectionCount      = @($collection.Sections).Count
        CollectorsRun     = @($collection.Ran).Count
        CollectorsSkipped = @($collection.Skipped).Count
        CollectorsFailed  = @($collection.Failed).Count
        FindingsPath      = $findingsPath
        AssessmentJson    = $jsonPath
        CsvFolder         = (Join-Path $run.RunFolder 'csv')
        CsvFileCount      = @($csvPaths).Count
        BundleZip         = $zip
        RunFolder         = $run.RunFolder
        HashManifest      = $manifestPath
    }
}
catch {
    if ($run) {
        try {
            Write-ExchEvent -Run $run -Level ERROR -Message 'Invoke-ExchAssess failed' -Data @{ error = $_.Exception.Message; stack = $_.ScriptStackTrace }
            Close-ExchRun -Run $run | Out-Null
        }
        catch {
            Write-Warning ("Failed to close the run cleanly: {0}" -f $_.Exception.Message)
        }
    }
    throw
}

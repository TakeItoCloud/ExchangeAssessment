<#
.SYNOPSIS
    Entry point for Exchange On-Prem/Hybrid Assessment.

.DESCRIPTION
    Read-only against Exchange and Active Directory. Every write goes to the run folder.

    Order matters: the reports are generated before the run is closed, so the SHA256 hash
    manifest covers the CSV and JSON output as well as the raw evidence. The ZIP is built last,
    after the manifest exists.

    Domain controllers, domains, the forest and existing Exchange servers are discovered. A
    greenfield deployment's target servers, file share witness and planned names cannot be,
    so they are supplied in a deployment config passed with -ConfigPath. Without one the
    preflight check prints a delimited warning block saying so, and the run carries on.

.EXAMPLE
    PS> .\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso

    Assesses the organisation and returns the run summary object.

.EXAMPLE
    PS> Import-Module .\src\ExchangeAssessment\ExchangeAssessment.psd1
    PS> New-ExchDeploymentConfig -Path .\Deployment.psd1
    PS> notepad .\Deployment.psd1
    PS> .\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -ConfigPath .\Deployment.psd1

    Worked example for a greenfield deployment. New-ExchDeploymentConfig writes a fillable copy
    of the shipped deployment config template. Fill in TargetServers, WitnessServer, DagName,
    InternalNames, DatabaseVolume and LogVolume, then pass the file with -ConfigPath, which this
    script hands to New-ExchRun to merge over the default thresholds. Any key left empty is
    named in the preflight warning. The filled file holds client host names: keep it out of
    source control.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantHint,
    [Parameter()][ValidateNotNullOrEmpty()][string]$OutputRoot = (Join-Path $PSScriptRoot '..\output'),
    [Parameter()][switch]$SkipDomainQueries,
    # Skip the mailbox inventory, the one collector whose cost scales with the organisation.
    [Parameter()][switch]$SkipMailboxInventory,
    # Skip the external DNS lookups.
    [Parameter()][switch]$SkipDnsQueries,
    # A .psd1 whose keys override Config/Thresholds.psd1 for this client. It also carries the
    # Deployment section of a greenfield deployment config (New-ExchDeploymentConfig), and is
    # passed through to New-ExchRun -ConfigPath.
    [Parameter()][string]$ConfigPath,
    # A .psd1 replacing Config/BuildTable.psd1, for a run against a newer copy of Microsoft's
    # Exchange build list than the one shipped with the module.
    [Parameter()][string]$BuildTablePath,
    # A .psd1 replacing Config/PrereqTable.psd1, for a run against a newer or operator-verified
    # reading of the Exchange Server SE prerequisites than the one shipped with the module.
    [Parameter()][string]$PrereqTablePath,
    # A .psd1 replacing Config/PortMatrix.psd1, for a run against a newer or operator-verified
    # reading of the network flows probed from each greenfield target server.
    [Parameter()][string]$PortMatrixPath,
    # Skip the greenfield deployment checks, which contact the servers named in the deployment
    # config.
    [Parameter()][switch]$SkipDeploymentChecks,
    # Put every inventory row in assessment.json instead of summarising the large sections.
    [Parameter()][switch]$FullInventory,
    [Parameter()][switch]$IncludeExchangeOnline,
    # Exchange Online sign-in. Interactive needs only -CloudUserPrincipalName; unattended needs
    # -CloudAppId, -CloudCertificateThumbprint and -CloudOrganization. Nothing here is written to
    # the run folder.
    [Parameter()][string]$CloudUserPrincipalName,
    [Parameter()][string]$CloudAppId,
    [Parameter()][string]$CloudCertificateThumbprint,
    [Parameter()][string]$CloudOrganization,
    [Parameter()][switch]$CloudManagedIdentity,
    [Parameter()][string]$CloudManagedIdentityAccountId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$run = $null

try {
    $modulePath = Join-Path $PSScriptRoot '..\src\ExchangeAssessment\ExchangeAssessment.psd1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $run = New-ExchRun -OutputRoot $OutputRoot -TenantHint $TenantHint -ConfigPath $ConfigPath `
        -BuildTablePath $BuildTablePath -PrereqTablePath $PrereqTablePath -PortMatrixPath $PortMatrixPath `
        -FullInventory:$FullInventory -IncludeExchangeOnline:$IncludeExchangeOnline `
        -CloudUserPrincipalName $CloudUserPrincipalName -CloudAppId $CloudAppId `
        -CloudCertificateThumbprint $CloudCertificateThumbprint -CloudOrganization $CloudOrganization `
        -CloudManagedIdentity:$CloudManagedIdentity -CloudManagedIdentityAccountId $CloudManagedIdentityAccountId

    try {
        $pre = Get-ExchPreflightReport -Run $run
        if ($pre -and $pre.warnings) {
            foreach ($w in $pre.warnings) {
                if ($w.StartsWith('Deployment config:')) {
                    # A delimited block rather than one more warning line: in a scrolling run
                    # this is the warning about inputs the directory cannot supply, and it
                    # carries the commands that supply them.
                    $rule = '=' * 78
                    Write-Warning (@('', $rule, $w, $rule) -join [Environment]::NewLine)
                }
                else {
                    Write-Warning $w
                }
                Write-ExchEvent -Run $run -Level WARN -Message 'Preflight' -Data @{ warning = $w }
            }
        }
    }
    catch {
        Write-Warning ("Preflight check failed: {0}" -f $_.Exception.Message)
        $null = Write-ExchError -Run $run -Context 'Preflight check' -ErrorRecord $_ -Severity 'Warning'
    }

    Write-ExchEvent -Run $run -Level INFO -Message 'Invoke-ExchAssess started' -Data @{
        tenantHint    = $TenantHint
        outputRoot    = $OutputRoot
        pwsh          = $PSVersionTable.PSVersion.ToString()
        host          = $env:COMPUTERNAME
        user          = $env:USERNAME
        skipDomain    = [bool]$SkipDomainQueries.IsPresent
        skipMailboxes = [bool]$SkipMailboxInventory.IsPresent
        skipDns       = [bool]$SkipDnsQueries.IsPresent
        skipDeployment = [bool]$SkipDeploymentChecks.IsPresent
        fullInventory = [bool]$FullInventory.IsPresent
        includeCloud  = [bool]$IncludeExchangeOnline.IsPresent
    }

    $collection = Invoke-ExchCollection -Run $run -SkipDomainQueries:$SkipDomainQueries `
        -SkipMailboxInventory:$SkipMailboxInventory -SkipDnsQueries:$SkipDnsQueries `
        -SkipDeploymentChecks:$SkipDeploymentChecks

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
        ErrorsLogged      = @($collection.Errors).Count
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
            $null = Write-ExchError -Run $run -Context 'Invoke-ExchAssess' -ErrorRecord $_
            Close-ExchRun -Run $run | Out-Null
        }
        catch {
            Write-Warning ("Failed to close the run cleanly: {0}" -f $_.Exception.Message)
        }
    }
    throw
}

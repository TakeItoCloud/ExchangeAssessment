@{
    RootModule        = 'ExchangeAssessment.psm1'
    ModuleVersion     = '0.6.0'
    GUID              = 'ea1e88ee-6d63-40ec-bb48-4a715579c109'
    Author            = 'Carlos Annes'
    CompanyName       = 'Caannes IT Consulting'
    Copyright         = '(c) 2026 Carlos Annes. All rights reserved.'
    Description       = 'Exchange On-Prem/Hybrid Assessment - configuration inventory, health findings and CSV/JSON reporting (read-only).'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
        'New-ExchRun',
        'Close-ExchRun',
        'New-ExchFinding',
        'Write-ExchEvent',
        'Invoke-ExchCollection',
        'Export-ExchCsvReport',
        'New-ExchAssessmentJson',
        'Export-ExchControlSnapshot',
        'Export-ExchEvidenceBundle',
        'Save-ExchFindings',
        'Write-ExchEvidenceFile',
        'Get-ExchPreflightReport',
        'New-ExchDeploymentConfig'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags         = @('Exchange','Hybrid','Security','Audit','Evidence')
            ProjectUri   = 'https://github.com/TakeItoCloud/ExchangeAssessment'
            LicenseUri   = ''
            ReleaseNotes = 'P14.5 and P14.6: DEP.VOL-01 checks the database and log volumes named in the deployment config on each target server, and DEP-01 rolls ENV.VERS-01 and the five DEP.* controls up into one greenfield readiness verdict that fails closed. The set of controls changed; see CHANGELOG.md.'
        }
    }
}

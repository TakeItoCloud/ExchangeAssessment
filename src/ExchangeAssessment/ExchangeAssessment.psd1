@{
    RootModule        = 'ExchangeAssessment.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'ea1e88ee-6d63-40ec-bb48-4a715579c109'
    Author            = 'Carlos Annes'
    CompanyName       = 'Caannes IT Consulting'
    Copyright         = '(c) 2026 Carlos Annes. All rights reserved.'
    Description       = 'Exchange On-Prem/Hybrid Assessment - evidence collection, findings, and bundle export (read-only).'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
        'New-ExchRun',
        'Close-ExchRun',
        'New-ExchFinding',
        'Write-ExchEvent',
        'Invoke-ExchCollection',
        'Export-ExchEvidenceBundle',
        'New-ExchWordReport',
        'Save-ExchFindings',
        'Write-ExchEvidenceFile',
        'Get-ExchPreflightReport'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags         = @('Exchange','Hybrid','Security','Audit','Evidence')
            ProjectUri   = 'https://github.com/TakeItoCloud/ExchangeAssessment'
            LicenseUri   = ''
            ReleaseNotes = 'Initial extraction from infra-scripting-suite.'
        }
    }
}

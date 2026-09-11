@{
    RootModule        = 'ExchangeAssessment.psm1'
    ModuleVersion     = '0.4.0'
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
            ReleaseNotes = 'P14.2: DEP.NET-01 probes network reachability from each server named in Deployment.TargetServers, on the server itself over WinRM, against a Learn-cited PortMatrix.psd1 (-PortMatrixPath). The set of controls changed; see CHANGELOG.md.'
        }
    }
}

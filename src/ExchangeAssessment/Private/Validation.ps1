<#
Validation and preflight helpers for Exchange Assessment.
#>

Set-StrictMode -Version Latest

function Assert-ExchModulePresent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModuleName)

    $mod = Get-Module -ListAvailable $ModuleName
    if (-not $mod) { throw "Module not found: $ModuleName" }
}

function Test-ExchManagementShell {
    [CmdletBinding()]
    param()

    return [bool](Get-Command Get-ExchangeServer -ErrorAction SilentlyContinue)
}

function Get-ExchPreflightReport {
    [CmdletBinding()]
    param()

    $warnings = New-Object System.Collections.Generic.List[string]

    if (-not (Test-ExchManagementShell)) {
        $warnings.Add('Exchange cmdlets not detected. Open the Exchange Management Shell on an Exchange server.') | Out-Null
    }

    try {
        if (-not (Get-Module -ListAvailable ActiveDirectory)) {
            $warnings.Add('ActiveDirectory module not found; domain/forest/schema checks will be skipped or marked Unknown.') | Out-Null
        }
    } catch {
        $warnings.Add('Unable to probe ActiveDirectory module presence.') | Out-Null
    }

    [pscustomobject]@{
        warnings = @($warnings)
    }
}

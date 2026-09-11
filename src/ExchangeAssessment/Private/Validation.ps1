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
    param(
        # The run from New-ExchRun. Its merged configuration carries the Deployment section when
        # one was supplied with -ConfigPath. Omitted, the shipped defaults are read instead, and
        # they carry none.
        [Parameter()]$Run
    )

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

    # A greenfield deployment's target servers, witness and planned names cannot be discovered,
    # so their absence is said out loud. It is a warning and never a failure: an assessment of
    # an existing organisation needs none of them.
    try {
        if (-not $Run) { $Run = [pscustomobject]@{ Config = (Import-ExchConfiguration) } }
        $deploymentWarning = Get-ExchDeploymentConfigWarning -Deployment (Get-ExchThreshold -Run $Run -Name 'Deployment')
        if ($deploymentWarning) { $warnings.Add($deploymentWarning) | Out-Null }
    } catch {
        $warnings.Add(('Deployment config: could not be evaluated ({0}). Greenfield deployment controls will report Unknown.' -f $_.Exception.Message)) | Out-Null
    }

    [pscustomobject]@{
        warnings = @($warnings)
    }
}

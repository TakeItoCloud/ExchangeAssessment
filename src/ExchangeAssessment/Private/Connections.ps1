<#
Connection helpers for Exchange Assessment (local Exchange shell + AD module).
#>

Set-StrictMode -Version Latest

function Assert-ExchLocalShell {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    if (-not (Test-ExchManagementShell)) {
        Write-ExchEvent -Run $Run -Level WARN -Message 'Exchange cmdlets not detected; collectors may fail' -Data @{}
        throw 'Exchange Management Shell cmdlets are not available in this session.'
    }
}

function Assert-ExchADModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    if (-not (Get-Module ActiveDirectory -ErrorAction SilentlyContinue)) {
        try { Import-Module ActiveDirectory -ErrorAction Stop }
        catch {
            Write-ExchEvent -Run $Run -Level WARN -Message 'ActiveDirectory module missing' -Data @{ error = $_.Exception.Message }
            throw 'ActiveDirectory module is required for domain/forest checks.'
        }
    }
}

<#
Connection helpers for Exchange Assessment (local Exchange shell + AD module).
#>

Set-StrictMode -Version Latest

function Assert-ExchLocalShell {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    if (-not (Test-ExchManagementShell)) {
        Write-ExchEvent -Run $Run -Level WARN -Message 'Exchange cmdlets not detected; collectors may fail' -Data @{ probe = 'Get-Command Get-ExchangeServer' }
        throw 'Exchange Management Shell cmdlets are not available in this session.'
    }
}

function Assert-ExchADModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    if (-not (Get-Module ActiveDirectory -ErrorAction SilentlyContinue)) {
        try { Import-Module ActiveDirectory -ErrorAction Stop }
        catch {
            $null = Write-ExchError -Run $Run -Context 'Import-Module ActiveDirectory' -ErrorRecord $_ -Severity 'Warning'
            throw 'ActiveDirectory module is required for domain/forest checks.'
        }
    }
}

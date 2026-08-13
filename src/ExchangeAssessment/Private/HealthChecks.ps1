<#
Placeholder for Exchange health helper functions (to be expanded in later phases).
#>

Set-StrictMode -Version Latest

function Get-ExchServerList {
    [CmdletBinding()]
    param()
    try { return Get-ExchangeServer -ErrorAction Stop }
    catch { return @() }
}

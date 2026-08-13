<#
Public wrapper for structured logging.
#>

function Write-ExchEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][hashtable]$Data
    )

    if (-not $Run.LogPath) { throw 'Run context missing LogPath.' }
    Write-ExchLog -Level $Level -Message $Message -Data $Data -LogPath $Run.LogPath
}

<#
Core logging utilities for Exchange Assessment runs.
#>

Set-StrictMode -Version Latest

function Write-ExchLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][hashtable]$Data,
        [Parameter(Mandatory)][string]$LogPath
    )

    $entry = [ordered]@{
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        level         = $Level
        message       = $Message
        data          = $Data
    }

    ($entry | ConvertTo-Json -Depth 10 -Compress) | Add-Content -Path $LogPath -Encoding UTF8
}

function Get-ExchFileHashManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FolderPath
    )

    $files = Get-ChildItem -Path $FolderPath -File -Recurse -ErrorAction Stop
    foreach ($f in $files) {
        $h = Get-FileHash -Path $f.FullName -Algorithm SHA256
        [pscustomobject]@{
            path   = $f.FullName.Substring($FolderPath.Length).TrimStart([char[]]"\/")
            sha256 = $h.Hash
            bytes  = $f.Length
        }
    }
}

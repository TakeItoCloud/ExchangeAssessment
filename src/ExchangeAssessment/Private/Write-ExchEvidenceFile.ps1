<#
Writes an evidence artifact into the run evidence folder and returns the relative path.
#>

Set-StrictMode -Version Latest

function Write-ExchEvidenceFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RelativePath,
        [Parameter()]$ContentObject
    )

    $ErrorActionPreference = 'Stop'

    $evidenceRoot = Join-Path $Run.RunFolder 'evidence'
    $fullPath = Join-Path $evidenceRoot $RelativePath
    $dir = Split-Path -Path $fullPath -Parent
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    if ($null -eq $ContentObject) { $ContentObject = @() }

    $json = $null
    try { $json = $ContentObject | ConvertTo-Json -Depth 15 }
    catch { $json = (@{ value = [string]$ContentObject } | ConvertTo-Json -Depth 5) }

    Set-Content -Path $fullPath -Value $json -Encoding UTF8

    $bytes = 0
    try { $bytes = (Get-Item -LiteralPath $fullPath).Length } catch {}

    try {
        Write-ExchEvent -Run $Run -Level INFO -Message 'Evidence written' -Data @{ file = $RelativePath; bytes = $bytes }
    } catch { }

    return $RelativePath
}

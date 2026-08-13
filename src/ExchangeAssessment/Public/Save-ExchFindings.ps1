<#
Persists findings to evidence folder.
#>

function Save-ExchFindings {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][object[]]$Findings)

    $root = Join-Path $Run.RunFolder 'evidence\findings'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $path = Join-Path $root 'findings.json'

    ($Findings | ConvertTo-Json -Depth 12) | Set-Content -Path $path -Encoding UTF8

    Write-ExchEvent -Run $Run -Level INFO -Message 'Findings persisted' -Data @{ path=$path; count=$Findings.Count }
    return $path
}

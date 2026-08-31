<#
Packs the finished run into a single ZIP.

Runs after Close-ExchRun, so the hash manifest inside the archive already covers every file the
archive carries. The ZIP itself is not hashed - it contains the manifest.
#>

function Export-ExchEvidenceBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][ValidatePattern('^[a-zA-Z0-9\-_\.]{0,80}$')][string]$BundleName = ''
    )

    $ErrorActionPreference = 'Stop'

    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $name = if ($BundleName) { $BundleName } else { "ExchEvidence-$($Run.TenantHint)-$ts" }
    $zipPath = Join-Path $Run.RunFolder "$name.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    $candidates = @(
        (Join-Path $Run.RunFolder 'evidence')
        (Join-Path $Run.RunFolder 'csv')
        (Join-Path $Run.RunFolder 'logs')
        (Join-Path $Run.RunFolder 'generated')
        (Join-Path $Run.RunFolder 'hash-manifest.json')
    )
    $candidates += @(Get-ChildItem -Path $Run.RunFolder -Filter 'assessment*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

    $pathsToZip = @($candidates | Where-Object { $_ -and (Test-Path $_) })

    Compress-Archive -Path $pathsToZip -DestinationPath $zipPath -Force

    Write-ExchEvent -Run $Run -Level INFO -Message 'Bundle exported' -Data @{ zipPath = $zipPath; entries = $pathsToZip.Count }

    return $zipPath
}

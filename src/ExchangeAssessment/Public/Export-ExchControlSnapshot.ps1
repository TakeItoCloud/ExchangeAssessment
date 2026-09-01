<#
Writes the control catalog and its framework crosswalks into the run folder.

These are the "what was this assessed against" half of the evidence: the catalog as it stood at
run time, plus both directions of the framework mapping. They are written before the run closes
so the hash manifest covers them.
#>

function Export-ExchControlSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'

    $genRoot = Join-Path $Run.RunFolder 'generated'
    New-Item -ItemType Directory -Path $genRoot -Force | Out-Null

    $catalog = Get-ExchControlCatalog
    ($catalog | ConvertTo-Json -Depth 12) | Set-Content -Path (Join-Path $genRoot 'control-catalog.json') -Encoding UTF8

    $controlsToFrameworks = $catalog | ForEach-Object {
        [pscustomobject]@{ controlId = $_.controlId; domain = $_.domain; frameworks = $_.mappings }
    }

    $frameworkIndex = @{}
    foreach ($c in $catalog) {
        foreach ($m in @($c.mappings)) {
            $key = $m.framework
            if (-not $frameworkIndex.ContainsKey($key)) {
                $frameworkIndex[$key] = New-Object System.Collections.Generic.List[object]
            }
            $frameworkIndex[$key].Add([pscustomobject]@{ controlId = $c.controlId; title = $c.title; ref = $m.ref; note = $m.note }) | Out-Null
        }
    }

    $frameworksToControls = foreach ($k in ($frameworkIndex.Keys | Sort-Object)) {
        [pscustomobject]@{ framework = $k; controls = @($frameworkIndex[$k].ToArray()) }
    }

    ($controlsToFrameworks | ConvertTo-Json -Depth 12) | Set-Content -Path (Join-Path $genRoot 'controls-to-frameworks.json') -Encoding UTF8
    ($frameworksToControls | ConvertTo-Json -Depth 12) | Set-Content -Path (Join-Path $genRoot 'frameworks-to-controls.json') -Encoding UTF8

    Write-ExchEvent -Run $Run -Level INFO -Message 'Control snapshot written' -Data @{ folder = $genRoot; controls = @($catalog).Count }

    return $genRoot
}

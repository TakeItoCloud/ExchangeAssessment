<#
Writes the raw configuration as CSV: one file per inventory section, plus one for the findings.

The CSV is the complete record - it always carries every row, even for sections that
assessment.json summarises - so nothing collected is ever only available in a trimmed form.
#>

function Export-ExchCsvReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][object[]]$Sections = @(),
        [Parameter()][object[]]$Findings = @()
    )

    $ErrorActionPreference = 'Stop'

    $csvRoot = Join-Path $Run.RunFolder 'csv'
    New-Item -ItemType Directory -Path $csvRoot -Force | Out-Null

    $written = New-Object System.Collections.Generic.List[string]

    foreach ($section in @($Sections | Where-Object { $null -ne $_ })) {
        $path = Join-Path $csvRoot ("{0}.csv" -f $section.key)

        # allRows is the untrimmed set; rows may have been summarised for the JSON view.
        $rows = @($section.allRows)
        if ($rows.Count -eq 0) {
            # An empty section still gets a file with its header, so a reader can tell
            # "collected, nothing there" from "never collected".
            $header = ($section.columns | ForEach-Object { '"{0}"' -f ($_ -replace '"', '""') }) -join ','
            Set-Content -Path $path -Value $header -Encoding UTF8
        }
        else {
            $rows | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
        }

        $written.Add($path) | Out-Null
    }

    $findingRows = foreach ($f in @($Findings | Where-Object { $null -ne $_ })) {
        [pscustomobject]@{
            controlId     = $f.controlId
            controlDomain = $f.controlDomain
            severity      = $f.severity
            outcome       = $f.result.outcome
            sufficiency   = $f.result.sufficiency
            title         = $f.title
            rationale     = $f.result.rationale
            remediation   = $f.remediation
            evidence      = (ConvertTo-ExchFlatValue -Value $f.evidence)
            references    = ((@($f.references) | ForEach-Object { $_.url }) -join ';')
            frameworks    = ((@($f.frameworkMappings) | ForEach-Object { '{0}:{1}' -f $_.framework, $_.ref }) -join ';')
            metrics       = (ConvertTo-ExchFlatValue -Value $f.result.metrics)
            detectedAtUtc = $f.detectedAtUtc
        }
    }

    $findingsPath = Join-Path $csvRoot 'findings.csv'
    if (@($findingRows).Count -eq 0) {
        Set-Content -Path $findingsPath -Value '"controlId","controlDomain","severity","outcome","sufficiency","title","rationale","remediation","evidence","references","frameworks","metrics","detectedAtUtc"' -Encoding UTF8
    }
    else {
        $findingRows | Export-Csv -Path $findingsPath -NoTypeInformation -Encoding UTF8
    }
    $written.Add($findingsPath) | Out-Null

    Write-ExchEvent -Run $Run -Level INFO -Message 'CSV report written' -Data @{ folder = $csvRoot; files = $written.Count }

    return $written.ToArray()
}

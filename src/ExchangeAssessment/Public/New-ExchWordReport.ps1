<#
Generates a Word (docx) technical report from the technical markdown using pandoc when available; falls back to a text copy.
#>

function New-ExchWordReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][string]$TechMarkdownPath
    )

    $ErrorActionPreference = 'Stop'

    $genRoot = Join-Path $Run.RunFolder 'generated'
    New-Item -ItemType Directory -Path $genRoot -Force | Out-Null

    $techPath = if ($TechMarkdownPath) { $TechMarkdownPath } else { Join-Path $genRoot 'technical-report.md' }
    $docxPath = Join-Path $genRoot 'ExchangeAssessment-Technical.docx'

    $usedPandoc = $false
    $fallback = $false

    try {
        if ((Test-Path $techPath) -and (Get-Command pandoc -ErrorAction SilentlyContinue)) {
            pandoc $techPath -o $docxPath
            $usedPandoc = $true
        }
    }
    catch {
        $fallback = $true
    }

    if (-not $usedPandoc) {
        $fallback = $true
        # Simple fallback: copy markdown content into a .txt (or .docx-named) file
        $fallbackPath = Join-Path $genRoot 'ExchangeAssessment-Technical.txt'
        if (Test-Path $techPath) {
            Get-Content -Path $techPath -Raw | Set-Content -Path $fallbackPath -Encoding UTF8
        }
        else {
            "Exchange Assessment Technical Report (markdown source missing)" | Set-Content -Path $fallbackPath -Encoding UTF8
        }
        $docxPath = $fallbackPath
    }

    try {
        Write-ExchEvent -Run $Run -Level INFO -Message 'Word report generated' -Data @{
            path     = $docxPath
            usedPandoc = $usedPandoc
            fallback  = $fallback
        }
    } catch { }

    return $docxPath
}

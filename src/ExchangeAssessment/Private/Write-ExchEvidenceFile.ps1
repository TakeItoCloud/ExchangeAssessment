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
    catch {
        # Some Exchange objects will not serialise cleanly; keep the string form rather than
        # losing the evidence entirely, and say in the file that this happened.
        Write-Verbose ("Falling back to string evidence for {0}: {1}" -f $RelativePath, $_.Exception.Message)
        $json = (@{ value = [string]$ContentObject; serialisationError = $_.Exception.Message } | ConvertTo-Json -Depth 5)
    }

    Set-Content -Path $fullPath -Value $json -Encoding UTF8

    $bytes = 0
    try { $bytes = (Get-Item -LiteralPath $fullPath).Length }
    catch { Write-Verbose ("Could not stat evidence file {0}: {1}" -f $RelativePath, $_.Exception.Message) }

    try {
        Write-ExchEvent -Run $Run -Level INFO -Message 'Evidence written' -Data @{ file = $RelativePath; bytes = $bytes }
    }
    catch { Write-Verbose ("Could not log evidence write for {0}: {1}" -f $RelativePath, $_.Exception.Message) }

    return $RelativePath
}

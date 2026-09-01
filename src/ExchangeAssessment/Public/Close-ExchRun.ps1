<#
Closes the run context and writes the integrity manifest.

Order matters here. The transcript is stopped, then redacted, and only then hashed - so the
manifest covers the redacted file and the bundle can never carry a sign-in secret that the
manifest vouches for.
#>

function Close-ExchRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    try { Stop-Transcript | Out-Null }
    catch {
        Write-ExchLog -Level 'WARN' -Message 'Stop-Transcript failed or not running' -Data @{ error = $_.Exception.Message } -LogPath $Run.LogPath
    }

    $redacted = Protect-ExchRunTranscript -Run $Run

    $manifest = Get-ExchFileHashManifest -FolderPath $Run.RunFolder
    $manifestPath = Join-Path $Run.RunFolder 'hash-manifest.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding UTF8

    Write-ExchLog -Level 'INFO' -Message 'Run closed' -Data @{
        runId = $Run.RunId
        manifestPath = $manifestPath
        transcriptRedactions = $redacted
        finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    } -LogPath $Run.LogPath

    return $manifestPath
}

function Protect-ExchRunTranscript {
    <#
    Removes sign-in identifiers from the PowerShell transcript.

    Start-Transcript records the command line that launched the run, so an operator who passed
    -CloudAppId and -CloudCertificateThumbprint would otherwise have them written into a file
    that gets zipped and handed to the client. The assessment promises that no credential reaches
    the run folder, and this is what keeps that promise.

    The tenant name is deliberately not redacted: the report needs to say which organisation was
    assessed. Returns the number of values replaced.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $transcriptPath = $null
    $property = $Run.PSObject.Properties.Match('TranscriptPath') | Select-Object -First 1
    if ($property) { $transcriptPath = [string]$property.Value }
    if (-not $transcriptPath -or -not (Test-Path -LiteralPath $transcriptPath)) { return 0 }

    $auth = $null
    $authProperty = $Run.PSObject.Properties.Match('CloudAuth') | Select-Object -First 1
    if ($authProperty) { $auth = $authProperty.Value }
    if ($null -eq $auth) { return 0 }

    $secrets = @()
    foreach ($name in @('UserPrincipalName', 'AppId', 'CertificateThumbprint', 'ManagedIdentityAccountId')) {
        $value = Get-ExchAuthValue -Auth $auth -Name $name
        if ($value -and ([string]$value).Trim().Length -ge 3) { $secrets += [string]$value }
    }
    if ($secrets.Count -eq 0) { return 0 }

    try {
        $content = Get-Content -LiteralPath $transcriptPath -Raw -ErrorAction Stop
        $replacements = 0
        foreach ($secret in ($secrets | Sort-Object -Property Length -Descending)) {
            $pattern = [regex]::Escape($secret)
            $matched = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($matched.Count -gt 0) {
                $replacements += $matched.Count
                $content = [regex]::Replace($content, $pattern, '[redacted]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            }
        }

        if ($replacements -gt 0) {
            Set-Content -LiteralPath $transcriptPath -Value $content -Encoding UTF8 -ErrorAction Stop
        }
        return $replacements
    }
    catch {
        # If the transcript cannot be rewritten it may still hold a secret, so say so loudly
        # rather than letting it ship quietly.
        Write-Warning ("Could not redact the run transcript at {0}: {1}. Review it before sharing the bundle." -f $transcriptPath, $_.Exception.Message)
        Write-ExchLog -Level 'WARN' -Message 'Transcript redaction failed' -Data @{ path = $transcriptPath; error = $_.Exception.Message } -LogPath $Run.LogPath
        return -1
    }
}

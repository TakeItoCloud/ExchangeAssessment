<#
Runs the collectors named in the registry, in dependency order.

Returns everything the reports need: the inventory sections, the findings, and an honest record
of which collectors ran, which were skipped and which failed. A collector that throws does not
stop the run, but it is never silently lost either - it becomes an Unknown/HardFail finding
naming the error, so a gap in the assessment is visible in the output rather than only in the
log.
#>

function Invoke-ExchCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter()][switch]$SkipDomainQueries
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $findings = New-Object System.Collections.Generic.List[object]
    $sections = New-Object System.Collections.Generic.List[object]
    $ran      = New-Object System.Collections.Generic.List[string]
    $skipped  = New-Object System.Collections.Generic.List[string]
    $failed   = New-Object System.Collections.Generic.List[object]
    $results  = @{}

    $skipFlags = @{ SkipDomainQueries = [bool]$SkipDomainQueries.IsPresent }
    $includeCloud = Get-ExchRunFlag -Run $Run -Name 'IncludeExchangeOnline'

    try { Assert-ExchLocalShell -Run $Run }
    catch { Write-ExchEvent -Run $Run -Level ERROR -Message 'Exchange cmdlets unavailable' -Data @{ error = $_.Exception.Message } }

    foreach ($entry in Get-ExchCollectorOrder) {

        if ($entry.SkipFlag -and $skipFlags.ContainsKey($entry.SkipFlag) -and $skipFlags[$entry.SkipFlag]) {
            $skipped.Add($entry.Id) | Out-Null
            Write-ExchEvent -Run $Run -Level WARN -Message 'Collector skipped' -Data @{ controlId = $entry.Id; reason = $entry.SkipFlag }
            continue
        }

        if ($entry.Cloud -and -not $includeCloud) {
            $skipped.Add($entry.Id) | Out-Null
            Write-ExchEvent -Run $Run -Level INFO -Message 'Collector skipped' -Data @{ controlId = $entry.Id; reason = 'Exchange Online not requested' }
            continue
        }

        try {
            $arguments = @{ Run = $Run }
            if (@($entry.Requires).Count -gt 0) {
                $upstream = @{}
                foreach ($req in @($entry.Requires)) {
                    if ($results.ContainsKey($req)) { $upstream[$req] = $results[$req] }
                }
                $arguments['Upstream'] = $upstream
            }

            $raw = & $entry.Function @arguments
            $result = ConvertTo-ExchCollectorResult -InputObject $raw

            $results[$entry.Id] = $result
            foreach ($s in $result.sections) { $sections.Add($s) | Out-Null }
            foreach ($f in $result.findings) { $findings.Add($f) | Out-Null }
            $ran.Add($entry.Id) | Out-Null
        }
        catch {
            $message = $_.Exception.Message
            Write-ExchEvent -Run $Run -Level ERROR -Message ('{0} collector failed' -f $entry.Id) -Data @{ error = $message; stack = $_.ScriptStackTrace }
            $failed.Add([pscustomobject]@{ controlId = $entry.Id; error = $message }) | Out-Null

            # A collector that fell over is a gap in the assessment, and the report has to say so.
            $findings.Add((New-ExchCollectorFailureFinding -ControlId $entry.Id -Area $entry.Area -Message $message)) | Out-Null
        }
    }

    [pscustomobject]@{
        Findings = $findings.ToArray()
        Sections = $sections.ToArray()
        Ran      = $ran.ToArray()
        Skipped  = $skipped.ToArray()
        Failed   = $failed.ToArray()
    }
}

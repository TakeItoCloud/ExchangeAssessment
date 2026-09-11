<#
Access to the Exchange Server SE prerequisite table.

The data itself lives in Config/PrereqTable.psd1 so it can be refreshed - or replaced for one run
with -PrereqTablePath - without touching code. This file only loads it. It mirrors
Catalog/BuildTable.ps1: the same path resolution, the same loading and the same validation.

A missing or unparseable table is an error, not an empty table: judging readiness against nothing
would report every check as unjudged and hide that the reference itself was missing.
#>

Set-StrictMode -Version Latest

function Get-ExchPrereqTablePath {
    <#
    The table this run should use: the caller's copy when one was supplied, otherwise the one
    that ships with the module.
    #>
    [CmdletBinding()]
    param([Parameter()]$Run)

    if ($Run) {
        $prop = $Run.PSObject.Properties.Match('PrereqTablePath') | Select-Object -First 1
        if ($prop -and $prop.Value) { return [string]$prop.Value }
    }

    return (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Config/PrereqTable.psd1')
}

function Get-ExchPrereqTable {
    <#
    Loads the prerequisite table. TableAsOf comes back as a [datetime], as the build table's does.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$Path,
        [Parameter()]$Run
    )

    $resolved = if ($Path) { $Path } else { Get-ExchPrereqTablePath -Run $Run }

    if (-not (Test-Path -LiteralPath $resolved)) {
        throw "Exchange prerequisite table not found at $resolved. Supply a valid -PrereqTablePath, or restore Config/PrereqTable.psd1."
    }

    $data = $null
    try { $data = Import-PowerShellDataFile -Path $resolved }
    catch { throw "Exchange prerequisite table at $resolved could not be parsed: $($_.Exception.Message)" }

    if ($null -eq $data) { throw "Exchange prerequisite table at $resolved is empty." }
    foreach ($key in @('TableAsOf', 'Source', 'Prerequisites')) {
        if (-not $data.Contains($key)) { throw "Exchange prerequisite table at $resolved is missing the '$key' key." }
    }

    $asOf = $null
    try { $asOf = [datetime]::ParseExact([string]$data.TableAsOf, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
    catch { throw "Exchange prerequisite table at $resolved has a TableAsOf of '$($data.TableAsOf)', which is not a yyyy-MM-dd date." }

    return [pscustomobject]@{
        TableAsOf     = $asOf
        Source        = [string]$data.Source
        Path          = $resolved
        Prerequisites = $data.Prerequisites
    }
}

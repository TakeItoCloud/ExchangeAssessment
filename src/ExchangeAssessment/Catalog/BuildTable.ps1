<#
Access to the Exchange build table.

The data itself lives in Config/BuildTable.psd1 so it can be refreshed - or replaced for one run
with -BuildTablePath - without touching code. This file only loads it and answers questions
about it.

A missing or unparseable table is an error, not an empty table: judging build currency against
nothing would report every server as unverifiable and look like a clean run.
#>

Set-StrictMode -Version Latest

function Get-ExchBuildTablePath {
    <#
    The table this run should use: the caller's copy when one was supplied, otherwise the one
    that ships with the module.
    #>
    [CmdletBinding()]
    param([Parameter()]$Run)

    if ($Run) {
        $prop = $Run.PSObject.Properties.Match('BuildTablePath') | Select-Object -First 1
        if ($prop -and $prop.Value) { return [string]$prop.Value }
    }

    return (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Config/BuildTable.psd1')
}

function Get-ExchBuildTable {
    <#
    Loads the build table. TableAsOf comes back as a [datetime] so callers can do date
    arithmetic on it without re-parsing.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$Path,
        [Parameter()]$Run
    )

    $resolved = if ($Path) { $Path } else { Get-ExchBuildTablePath -Run $Run }

    if (-not (Test-Path -LiteralPath $resolved)) {
        throw "Exchange build table not found at $resolved. Supply a valid -BuildTablePath, or restore Config/BuildTable.psd1."
    }

    $data = $null
    try { $data = Import-PowerShellDataFile -Path $resolved }
    catch { throw "Exchange build table at $resolved could not be parsed: $($_.Exception.Message)" }

    if ($null -eq $data) { throw "Exchange build table at $resolved is empty." }
    foreach ($key in @('TableAsOf', 'Source', 'Builds')) {
        if (-not $data.Contains($key)) { throw "Exchange build table at $resolved is missing the '$key' key." }
    }

    $asOf = $null
    try { $asOf = [datetime]::ParseExact([string]$data.TableAsOf, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
    catch { throw "Exchange build table at $resolved has a TableAsOf of '$($data.TableAsOf)', which is not a yyyy-MM-dd date." }

    return [pscustomobject]@{
        TableAsOf = $asOf
        Source    = [string]$data.Source
        Path      = $resolved
        Builds    = @($data.Builds)
    }
}

function Resolve-ExchBuild {
    <#
    Looks a build up in the table.

    Returns the matched row when the exact build is known. When it is not, says whether the
    build is ahead of everything the table knows for that product - which means the table is
    behind, not that the server is wrong.

    -Table is mandatory, and deliberately so. It used to be optional with a fall back to
    Get-ExchBuildTable, which meant a run started with -BuildTablePath could silently be judged
    against the table shipped in the repository instead of the operator's - the caller loads the
    table once, from the run, and hands it here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Build,
        [Parameter(Mandatory)][ValidateNotNull()]$Table,
        [Parameter()][string]$Product = ''
    )

    $parsed = $null
    try { $parsed = [version]$Build } catch { $parsed = $null }

    $exact = @($Table.Builds | Where-Object { $_.Build -eq $Build }) | Select-Object -First 1
    if ($exact) {
        return [pscustomobject]@{
            Known          = $true
            NewerThanTable = $false
            Release        = [string]$exact.Release
            Product        = [string]$exact.Product
            Released       = [datetime]$exact.Released
            TableAsOf      = $Table.TableAsOf
        }
    }

    $newest = $null
    if ($parsed) {
        $family = @($Table.Builds | Where-Object { -not $Product -or $_.Product -eq $Product })
        foreach ($row in $family) {
            $rowVersion = $null
            try { $rowVersion = [version]$row.Build } catch { continue }
            if ($null -eq $newest -or $rowVersion -gt $newest) { $newest = $rowVersion }
        }
    }

    return [pscustomobject]@{
        Known          = $false
        NewerThanTable = [bool]($parsed -and $newest -and $parsed -gt $newest)
        Release        = ''
        Product        = $Product
        Released       = $null
        TableAsOf      = $Table.TableAsOf
    }
}

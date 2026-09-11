<#
Access to the port matrix: the network flows DEP.NET-01 probes from each greenfield target server.

The data itself lives in Config/PortMatrix.psd1 so it can be refreshed - or replaced for one run with
-PortMatrixPath - without touching code. This file only loads it. It mirrors Catalog/PrereqTable.ps1:
the same path resolution, the same loading and the same validation.

A missing, unparseable or empty table is an error, not an empty table: probing nothing would report
no flow at all and hide that the reference itself was missing.
#>

Set-StrictMode -Version Latest

function Get-ExchPortMatrixPath {
    <#
    The table this run should use: the caller's copy when one was supplied, otherwise the one that
    ships with the module.
    #>
    [CmdletBinding()]
    param([Parameter()]$Run)

    if ($Run) {
        $prop = $Run.PSObject.Properties.Match('PortMatrixPath') | Select-Object -First 1
        if ($prop -and $prop.Value) { return [string]$prop.Value }
    }

    return (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Config/PortMatrix.psd1')
}

function Get-ExchPortMatrix {
    <#
    Loads the port matrix. TableAsOf comes back as a [datetime], as the prerequisite table's does,
    and Flows as an array in the order the file lists them.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$Path,
        [Parameter()]$Run
    )

    $resolved = if ($Path) { $Path } else { Get-ExchPortMatrixPath -Run $Run }

    if (-not (Test-Path -LiteralPath $resolved)) {
        throw "Port matrix not found at $resolved. Supply a valid -PortMatrixPath, or restore Config/PortMatrix.psd1."
    }

    $data = $null
    try { $data = Import-PowerShellDataFile -Path $resolved }
    catch { throw "Port matrix at $resolved could not be parsed: $($_.Exception.Message)" }

    if ($null -eq $data) { throw "Port matrix at $resolved is empty." }
    foreach ($key in @('TableAsOf', 'Source', 'Flows')) {
        if (-not $data.Contains($key)) { throw "Port matrix at $resolved is missing the '$key' key." }
    }

    $asOf = $null
    try { $asOf = [datetime]::ParseExact([string]$data.TableAsOf, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
    catch { throw "Port matrix at $resolved has a TableAsOf of '$($data.TableAsOf)', which is not a yyyy-MM-dd date." }

    $flows = @($data.Flows | Where-Object { $null -ne $_ })
    if ($flows.Count -eq 0) { throw "Port matrix at $resolved lists no flows." }

    return [pscustomobject]@{
        TableAsOf = $asOf
        Source    = [string]$data.Source
        Path      = $resolved
        Flows     = $flows
    }
}

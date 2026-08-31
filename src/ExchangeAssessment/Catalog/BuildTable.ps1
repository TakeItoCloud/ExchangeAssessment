<#
Known Exchange Server builds.

Source: https://learn.microsoft.com/exchange/new-features/build-numbers-and-release-dates

This table is a point-in-time copy and it will go stale. It therefore carries the date it was
last refreshed, and the collector that uses it treats "your build is newer than anything I know
about" as "cannot verify", never as "current". A tool that reports a pass from a stale table is
worse than one that says it does not know.

Refresh: add the new rows, move TableAsOf, note it in CHANGELOG.md.
#>

Set-StrictMode -Version Latest

function Get-ExchBuildTable {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        TableAsOf = [datetime]'2026-08-31'
        Source    = 'https://learn.microsoft.com/exchange/new-features/build-numbers-and-release-dates'
        Builds    = @(
            # Exchange Server SE
            @{ Build='15.2.2562.20'; Product='Exchange Server SE'; Release='Exchange Server SE RTM Aug25SU'; Released='2025-08-12' }
            @{ Build='15.2.2562.17'; Product='Exchange Server SE'; Release='Exchange Server SE RTM';         Released='2025-07-01' }

            # Exchange Server 2019 - out of support since 2025-10-14
            @{ Build='15.2.1748.49'; Product='Exchange Server 2019'; Release='Exchange Server 2019 CU15 Aug26SU'; Released='2026-08-11' }
            @{ Build='15.2.1748.48'; Product='Exchange Server 2019'; Release='Exchange Server 2019 CU15 Jul26SU'; Released='2026-07-14' }
            @{ Build='15.2.1748.46'; Product='Exchange Server 2019'; Release='Exchange Server 2019 CU15 Jun26SU'; Released='2026-06-09' }
            @{ Build='15.2.1748.43'; Product='Exchange Server 2019'; Release='Exchange Server 2019 CU15 Feb26SU'; Released='2026-02-10' }
            @{ Build='15.2.1748.42'; Product='Exchange Server 2019'; Release='Exchange Server 2019 CU15 Dec25SU'; Released='2025-12-09' }
            @{ Build='15.2.1544.4';  Product='Exchange Server 2019'; Release='Exchange Server 2019 CU14 (2024H1)'; Released='2024-02-13' }
            @{ Build='15.2.1258.12'; Product='Exchange Server 2019'; Release='Exchange Server 2019 CU13 (2023H1)'; Released='2023-05-03' }
            @{ Build='15.2.1118.7';  Product='Exchange Server 2019'; Release='Exchange Server 2019 CU12 (2022H1)'; Released='2022-04-20' }

            # Exchange Server 2016 - out of support since 2025-10-14
            @{ Build='15.1.2507.6';  Product='Exchange Server 2016'; Release='Exchange Server 2016 CU23 (2022H1)'; Released='2022-04-20' }
        )
    }
}

function Resolve-ExchBuild {
    <#
    Looks a build up in the table.

    Returns the matched row when the exact build is known. When it is not, says whether the
    build is ahead of everything the table knows for that product - which means the table is
    behind, not that the server is wrong.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Build,
        [Parameter()][string]$Product = ''
    )

    $table = Get-ExchBuildTable
    $parsed = $null
    try { $parsed = [version]$Build } catch { $parsed = $null }

    $exact = @($table.Builds | Where-Object { $_.Build -eq $Build }) | Select-Object -First 1
    if ($exact) {
        return [pscustomobject]@{
            Known        = $true
            NewerThanTable = $false
            Release      = $exact.Release
            Product      = $exact.Product
            Released     = [datetime]$exact.Released
            TableAsOf    = $table.TableAsOf
        }
    }

    $newest = $null
    if ($parsed) {
        $family = @($table.Builds | Where-Object { -not $Product -or $_.Product -eq $Product })
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
        TableAsOf      = $table.TableAsOf
    }
}

<#
Known Exchange Server builds.

Source: https://learn.microsoft.com/exchange/new-features/build-numbers-and-release-dates
Verified 2026-09-02.

This table is a point-in-time copy of a page Microsoft updates every time a cumulative update,
security update or hotfix ships, so it will go stale. It therefore carries the date it was last
refreshed, and the collector that uses it treats "your build is newer than anything I know
about" as "cannot verify", never as "current" - and says so out loud once the table itself is
older than Exchange.MaxBuildTableAgeDays.

Coverage is deliberate rather than exhaustive: every Exchange Server SE build, every Exchange
2019 CU14/CU15 and 2016 CU23 build, and for the older cumulative updates the base build plus the
final security update where one exists. Builds older than these are absent on purpose. An
organisation running one of them reports Unknown for build currency, which is the honest answer;
inventing rows to make it report Compliant would not be.

Refresh: add the new rows, move TableAsOf, note it in CHANGELOG.md. A caller with a newer copy
can pass it to the assessment with -BuildTablePath instead of editing this file.
#>
@{
    TableAsOf = '2026-09-02'
    Source    = 'https://learn.microsoft.com/exchange/new-features/build-numbers-and-release-dates'

    Builds = @(
        # ----- Exchange Server SE - the only supported Exchange version -------------------
        @{ Build = '15.2.2562.46'; Product = 'Exchange Server SE'; Release = 'Exchange Server SE RTM Aug26SU'; Released = '2026-08-11' }
        @{ Build = '15.2.2562.45'; Product = 'Exchange Server SE'; Release = 'Exchange Server SE RTM Jul26SU'; Released = '2026-07-14' }
        @{ Build = '15.2.2562.43'; Product = 'Exchange Server SE'; Release = 'Exchange Server SE RTM Jun26SU'; Released = '2026-06-09' }
        @{ Build = '15.2.2562.41'; Product = 'Exchange Server SE'; Release = 'Exchange Server SE RTM May26HU'; Released = '2026-05-07' }
        @{ Build = '15.2.2562.37'; Product = 'Exchange Server SE'; Release = 'Exchange Server SE RTM Feb26SU'; Released = '2026-02-10' }
        @{ Build = '15.2.2562.35'; Product = 'Exchange Server SE'; Release = 'Exchange Server SE RTM Dec25SU'; Released = '2025-12-09' }
        @{ Build = '15.2.2562.29'; Product = 'Exchange Server SE'; Release = 'Exchange Server SE RTM Oct25SU'; Released = '2025-10-14' }
        @{ Build = '15.2.2562.27'; Product = 'Exchange Server SE'; Release = 'Exchange Server SE RTM Sep25HU'; Released = '2025-09-08' }
        @{ Build = '15.2.2562.20'; Product = 'Exchange Server SE'; Release = 'Exchange Server SE RTM Aug25SU'; Released = '2025-08-12' }
        @{ Build = '15.2.2562.17'; Product = 'Exchange Server SE'; Release = 'Exchange Server SE RTM';         Released = '2025-07-01' }

        # ----- Exchange Server 2019 CU15 - out of support since 2025-10-14 ----------------
        @{ Build = '15.2.1748.49'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU15 Aug26SU';  Released = '2026-08-11' }
        @{ Build = '15.2.1748.48'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU15 Jul26SU';  Released = '2026-07-14' }
        @{ Build = '15.2.1748.46'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU15 Jun26SU';  Released = '2026-06-09' }
        @{ Build = '15.2.1748.43'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU15 Feb26SU';  Released = '2026-02-10' }
        @{ Build = '15.2.1748.42'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU15 Dec25SU';  Released = '2025-12-09' }
        @{ Build = '15.2.1748.39'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU15 Oct25SU';  Released = '2025-10-14' }
        @{ Build = '15.2.1748.37'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU15 Sep25HU';  Released = '2025-09-08' }
        @{ Build = '15.2.1748.36'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU15 Aug25SU';  Released = '2025-08-12' }
        @{ Build = '15.2.1748.26'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU15 May25HU';  Released = '2025-05-29' }
        @{ Build = '15.2.1748.24'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU15 Apr25HU';  Released = '2025-04-18' }
        @{ Build = '15.2.1748.10'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU15 (2025H1)'; Released = '2025-02-10' }

        # ----- Exchange Server 2019 CU14 --------------------------------------------------
        @{ Build = '15.2.1544.44'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Aug26SU';   Released = '2026-08-11' }
        @{ Build = '15.2.1544.43'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Jul26SU';   Released = '2026-07-14' }
        @{ Build = '15.2.1544.41'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Jun26SU';   Released = '2026-06-09' }
        @{ Build = '15.2.1544.39'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Feb26SU';   Released = '2026-02-10' }
        @{ Build = '15.2.1544.37'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Dec25SU';   Released = '2025-12-09' }
        @{ Build = '15.2.1544.36'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Oct25SU';   Released = '2025-10-14' }
        @{ Build = '15.2.1544.34'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Sep25HU';   Released = '2025-09-08' }
        @{ Build = '15.2.1544.33'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Aug25SU';   Released = '2025-08-12' }
        @{ Build = '15.2.1544.27'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 May25HU';   Released = '2025-05-29' }
        @{ Build = '15.2.1544.25'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Apr25HU';   Released = '2025-04-18' }
        @{ Build = '15.2.1544.14'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Nov24SUv2'; Released = '2024-11-27' }
        @{ Build = '15.2.1544.13'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Nov24SU';   Released = '2024-11-12' }
        @{ Build = '15.2.1544.11'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Apr24HU';   Released = '2024-04-23' }
        @{ Build = '15.2.1544.9';  Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 Mar24SU';   Released = '2024-03-12' }
        @{ Build = '15.2.1544.4';  Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU14 (2024H1)';  Released = '2024-02-13' }

        # ----- Exchange Server 2019, older CUs: base build plus final SU ------------------
        @{ Build = '15.2.1258.39'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU13 Nov24SUv2'; Released = '2024-11-27' }
        @{ Build = '15.2.1258.12'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU13 (2023H1)';  Released = '2023-05-03' }
        @{ Build = '15.2.1118.40'; Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU12 Nov23SU';   Released = '2023-11-14' }
        @{ Build = '15.2.1118.7';  Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU12 (2022H1)';  Released = '2022-04-20' }
        @{ Build = '15.2.986.42';  Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU11 Mar23SU';   Released = '2023-03-14' }
        @{ Build = '15.2.986.5';   Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU11';           Released = '2021-09-28' }
        @{ Build = '15.2.922.27';  Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU10 Mar22SU';   Released = '2022-03-08' }
        @{ Build = '15.2.922.7';   Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU10';           Released = '2021-06-29' }
        @{ Build = '15.2.858.15';  Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU9 Jul21SU';    Released = '2021-07-13' }
        @{ Build = '15.2.858.5';   Product = 'Exchange Server 2019'; Release = 'Exchange Server 2019 CU9';            Released = '2021-03-16' }

        # ----- Exchange Server 2016 CU23 - out of support since 2025-10-14 ----------------
        @{ Build = '15.1.2507.72'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Aug26SU';   Released = '2026-08-11' }
        @{ Build = '15.1.2507.71'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Jul26SU';   Released = '2026-07-14' }
        @{ Build = '15.1.2507.69'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Jun26SU';   Released = '2026-06-09' }
        @{ Build = '15.1.2507.66'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Feb26SU';   Released = '2026-02-10' }
        @{ Build = '15.1.2507.63'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Dec25SU';   Released = '2025-12-09' }
        @{ Build = '15.1.2507.61'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Oct25SU';   Released = '2025-10-14' }
        @{ Build = '15.1.2507.59'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Sep25HU';   Released = '2025-09-08' }
        @{ Build = '15.1.2507.58'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Aug25SU';   Released = '2025-08-12' }
        @{ Build = '15.1.2507.57'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 May25HU';   Released = '2025-05-29' }
        @{ Build = '15.1.2507.55'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Apr25HU';   Released = '2025-04-18' }
        @{ Build = '15.1.2507.44'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Nov24SUv2'; Released = '2024-11-27' }
        @{ Build = '15.1.2507.43'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Nov24SU';   Released = '2024-11-12' }
        @{ Build = '15.1.2507.39'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Apr24HU';   Released = '2024-04-23' }
        @{ Build = '15.1.2507.37'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Mar24SU';   Released = '2024-03-12' }
        @{ Build = '15.1.2507.35'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Nov23SU';   Released = '2023-11-14' }
        @{ Build = '15.1.2507.34'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Oct23SU';   Released = '2023-10-10' }
        @{ Build = '15.1.2507.32'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Aug23SUv2'; Released = '2023-08-15' }
        @{ Build = '15.1.2507.31'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Aug23SU';   Released = '2023-08-08' }
        @{ Build = '15.1.2507.27'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Jun23SU';   Released = '2023-06-13' }
        @{ Build = '15.1.2507.23'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Mar23SU';   Released = '2023-03-14' }
        @{ Build = '15.1.2507.21'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Feb23SU';   Released = '2023-02-14' }
        @{ Build = '15.1.2507.17'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Jan23SU';   Released = '2023-01-10' }
        @{ Build = '15.1.2507.16'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Nov22SU';   Released = '2022-11-08' }
        @{ Build = '15.1.2507.13'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Oct22SU';   Released = '2022-10-11' }
        @{ Build = '15.1.2507.12'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 Aug22SU';   Released = '2022-08-09' }
        @{ Build = '15.1.2507.9';  Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 May22SU';   Released = '2022-05-10' }
        @{ Build = '15.1.2507.6';  Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU23 (2022H1)';  Released = '2022-04-20' }

        # ----- Exchange Server 2016, older CUs: base build plus final SU ------------------
        @{ Build = '15.1.2375.37'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU22 Nov22SU'; Released = '2022-11-08' }
        @{ Build = '15.1.2375.7';  Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU22';         Released = '2021-09-28' }
        @{ Build = '15.1.2308.27'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU21 Mar22SU'; Released = '2022-03-08' }
        @{ Build = '15.1.2308.8';  Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU21';         Released = '2021-06-29' }
        @{ Build = '15.1.2242.12'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU20 Jul21SU'; Released = '2021-07-13' }
        @{ Build = '15.1.2242.4';  Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU20';         Released = '2021-03-16' }
        @{ Build = '15.1.2176.14'; Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU19 May21SU'; Released = '2021-05-11' }
        @{ Build = '15.1.2176.2';  Product = 'Exchange Server 2016'; Release = 'Exchange Server 2016 CU19';         Released = '2020-12-15' }
    )
}

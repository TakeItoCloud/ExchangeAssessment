# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial extraction from infra-scripting-suite
  (`powershell/Assessments/ExchangeAssessment`): the `ExchangeAssessment` module — control
  catalog, 15 collectors, private helpers and 10 public functions, with
  `Generate-WordReport.py` already inside the module — plus the `scripts\Invoke-ExchAssess.ps1`
  entry point.
- Smoke tests: manifest validity, module import, the 5.1 floor, a non-placeholder GUID, every
  promised function resolving, no function defined twice, every collector the dispatcher
  calls being defined, **every control id a collector asks the catalog for resolving to a
  catalog entry**, the entry script parsing and returning an object instead of writing to the
  host, and the Word helper shipping.
- The suite's module README preserved at `docs\README-source.md`.

### Changed

- Module `GUID` replaced: the source carried the placeholder
  `00000000-0000-0000-0000-000000000102`.
- `CompatiblePSEditions = @('Desktop','Core')` added, and explicit empty
  `CmdletsToExport` / `VariablesToExport` / `AliasesToExport`. `PowerShellVersion` stays at
  `5.1` — the module runs inside the Exchange Management Shell, so the house
  "add `#Requires -Version 7.4`" rule is deliberately not applied here.
- `ProjectUri` set to this repository; `ReleaseNotes` no longer say "Initial scaffold with
  core collectors", which had stopped being true.
- `Invoke-ExchAssess.ps1` returns a summary object (`FindingsCount`, `FindingsPath`,
  `BundleZip`, `RunFolder`, `HashManifest`) instead of writing four `Write-Host` lines. This
  also puts `$findingsPath` to use — it was assigned and then discarded.
- `PSScriptAnalyzerSettings.psd1` suspends `PSAvoidUsingEmptyCatchBlock` (19),
  `PSUseSingularNouns` (7), `PSUseShouldProcessForStateChangingFunctions` (3) and
  `PSUseApprovedVerbs` (2). Tracked as phase P2 in [PORT-PLAN.md](PORT-PLAN.md).
  `PSAvoidUsingWriteHost`, `PSUseDeclaredVarsMoreThanAssignments` and
  `PSPossibleIncorrectComparisonWithNull` are enforced.

### Fixed

- Six `$x -ne $null` comparisons reversed to `$null -ne $x`, in the certificate expiry
  thresholds (`CERT-01`), the ADSync recency check (`ID.SYNC-01`) and the schema version gate
  (`UPG-01`). All three feed compliance outcomes, so operand order is not cosmetic there.
- `Export-ExchEvidenceBundle` assigned `Save-ExchFindings` output to an unused
  `$findingsPath`. Replaced with `$null =`, preserving the output suppression.
- `Invoke-ExchCollector_UPG_01_SEReadiness` suppresses `PSReviewUnusedParameter` for `$Run`
  at the function, documenting that the roll-up derives everything from the findings it is
  handed.
- `Invoke-ExchCollector_MB_AV_01_AVExclusions` suppresses
  `PSUseDeclaredVarsMoreThanAssignments` for `$recommendedTokens`, with a comment recording
  *why* the variable is unused: the collector reports the AV exclusions that are configured
  but never compares them against the recommended set. The variable is the specification for
  a check that was never written — kept deliberately visible rather than deleted. Phase P4.

### Not done

- **Runtime verification against an Exchange organisation is deferred.** This extraction was
  gated on PSScriptAnalyzer and Pester smoke tests only. No collector has been executed
  against a real organisation from this repository — see phase P3 in
  [PORT-PLAN.md](PORT-PLAN.md).
- The manifest still carries `Author = 'Carlos Annes'` /
  `CompanyName = 'Caannes IT Consulting'` from the original. Left as found; the same open
  question as M365AuditEvidencePack.

## [0.1.0] - 2026-08-13

### Added

- Initial scaffold from template-ps-tool.

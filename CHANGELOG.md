# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — 2026-09-01 (phase P10, partial)

Three collectors, closing the coverage gaps that were named explicitly: transport settings,
replication, and a real server inventory.

- **`SRV-01` — server inventory and service health.** How many Exchange servers there are,
  what roles they hold, which Active Directory site each sits in, whether `Test-ServiceHealth`
  reports every required service running, and whether any server component has been left
  Inactive. The organisation previously called `Get-ExchangeServer` three times and kept only
  the name, edition and version.
- **`TR.CFG-01` — transport configuration.** Organisation-wide limits, shadow redundancy and
  Safety Net hold time, per-server transport and frontend transport services including message
  tracking, and the transport and journal rules that redirect or copy mail. Transport settings
  were previously absent entirely.
- **`REPL-01` — replication and client connectivity.** `Test-ReplicationHealth` on every DAG
  member and `Test-MAPIConnectivity` against every mounted database. `Test-Mailflow` is
  deliberately not used: it sends live messages, and this assessment stays read-only.

The read-only test now walks the PowerShell AST rather than the file text, so a cmdlet named
in a comment or a message string is no longer mistaken for a call, and a real invocation of a
state-changing cmdlet is caught wherever it appears.

### Fixed — 2026-09-01

- Two boolean checks compared against the strings `'True'` and `'False'`. PowerShell coerces
  the right operand of `-eq` to the left operand's type and every non-empty string is a true
  boolean, so the message-tracking check reported exactly the servers that were fine and
  ignored the ones that were not.

### Changed — 2026-08-31 (phase P9)

The assessment is reworked around a configuration inventory that is separate from the
findings, and the reporting layer is replaced with raw CSV and a single consolidated JSON.

**Inventory model.** A collector now returns inventory sections and findings
(`New-ExchCollectorResult`) instead of one finding plus an ad-hoc JSON blob. A section is a
table with a stable key, an area, an ordered column list and rows already flattened to
CSV-safe scalars, so the report writers render whatever sections exist without knowing
anything about Exchange. This is what removes the pressure on a collector to invent a finding
when all it had was an inventory to report.

**Nothing is hardcoded.** `Config/Thresholds.psd1` holds every value the tool judges against —
supported builds and operating systems, certificate expiry windows, queue and backup
thresholds, the Microsoft-recommended anti-malware exclusions, TLS and DNS expectations.
`-ConfigPath` merges a client-specific `.psd1` over those defaults, so the same tool assesses
organisations with different baselines without editing code. `-Outcome` and `-Rationale` are
now mandatory on `New-ExchFinding`, and a test fails the build if any collector assigns a
literal `Compliant`.

**Output is CSV and JSON.** `csv/<section>.csv` per configuration area plus `csv/findings.csv`,
and one `assessment.json` carrying the inventory, the findings with their rationale and
Microsoft references, and the control catalog. High-cardinality sections are summarised in the
JSON (`-FullInventory` emits everything) and the file splits into per-area parts above a size
budget; the CSVs always hold every row. The reports are generated before the run closes, so
`hash-manifest.json` now covers them.

**Fixed**

- `LOG.EX-01` never produced a finding. The catalog gave it domain `Monitoring`, which was not
  in `New-ExchFinding`'s `ControlDomain` ValidateSet, so the collector threw on every run and
  the dispatcher swallowed it. The ValidateSet gains `Monitoring`, `Compliance`, `Client`,
  `Network` and `Cloud`, and a test now fails if the catalog and the ValidateSet drift apart
  again.
- `EX.ADM-01` and `EX.VDIR-01` returned a literal `Compliant`/`Pass` regardless of what they
  found. Both now evaluate: accepted domains check for wildcard and external relay domains, a
  missing or duplicated default, and auto-forwarding on the default remote domain; virtual
  directories check for missing external URLs, plain HTTP, Basic authentication on externally
  published directories, inconsistent URLs across servers, and a missing Autodiscover SCP.
- `EX.CH-01` scored an Exchange 2019 organisation as `PartiallyCompliant`. Exchange 2016 and
  2019 both reached end of support on 2025-10-14, so only Exchange Server SE is supported.
  `Catalog/BuildTable.ps1` provides real build currency and carries the date it was last
  refreshed; a build newer than the table is reported as unverifiable, never as current.
- `ENV.OS-01` used Windows Server 2016 as its floor; Exchange SE requires Windows Server 2019
  or later.
- `ENV.VERS-01` checked `Get-ADRootDSE.schemaVersion`, which is the Active Directory schema
  version rather than the Exchange one. It now reads `rangeUpper` on
  `ms-Exch-Schema-Version-Pt` and `objectVersion` on both the organisation container and
  Microsoft Exchange System Objects — the three values Exchange setup actually gates on.
- The open-relay test in `TR.CO-01` matched the literal string `0.0.0.0-255.255.255.255` and
  missed `0.0.0.0/0` and the IPv6 equivalents.
- `MB.AV-01` declared the Microsoft-recommended exclusions and never compared against them
  (PORT-PLAN P4). It now reports what is missing per server.
- `MB.DB-01` collected copy queue lengths and content index state and never evaluated them,
  and did not look at backups at all.
- `Export-ExchEvidenceBundle` ran after `Close-ExchRun`, so nothing it produced was covered by
  the hash manifest.
- `README.md` credited Python 3 and `python-docx` for a Word report that was never generated
  that way, and showed the entry script with no arguments although `-TenantHint` is mandatory.

**Removed**

- The Word, PDF and Markdown output paths, including `New-ExchWordReport`, the pandoc calls,
  and `Scripts/Generate-WordReport.py`, which was a seven-line stub nothing ever called. The
  230-line `Write-ExchMarkdown` inside the bundle exporter is gone with them: it hardcoded a
  renderer per evidence-file shape and would not have survived the collector expansion.
- Two of the four PSScriptAnalyzer suspensions (PORT-PLAN P2). `PSAvoidUsingEmptyCatchBlock`
  went from 19 hits to zero and `PSUseApprovedVerbs` from 2 to zero, so both now fail the
  build. The remaining two are documented in `PSScriptAnalyzerSettings.psd1` as cosmetic
  rather than outstanding.

**Collector dispatch** is driven by `Catalog/CollectorRegistry.ps1`, an ordered registry with
declared dependencies, replacing 148 lines of hand-written try/catch. A collector that throws
now becomes an `Unknown`/`HardFail` finding naming the error, so a gap in the assessment is
visible in the output rather than only in the log.

### Changed — 2026-08-14 (phase P5.3)

The three workflow files backfilled in P4.4 are refreshed from
`TakeItoCloud/template-ps-tool`, which moved a phase ahead in P5.2. All three are copied
byte-for-byte from the template's `main` and verified by git blob SHA, so this repository's
mirrors are identical to the canonical files rather than merely similar to them.

- `.github/pull_request_template.md` — the seven-item self-review checklist is replaced by
  three evidence lines (`- **Read-only default:**`, `- **No fabricated data:**`,
  `- **Verified against real data:**`), each of which must state **how** the property was
  verified. The checklist was ticked by whoever wrote the change, so it recorded a claim
  rather than controlling anything.
- `.github/workflows/pr-hygiene.yml` — the Conventional Commits title check is unchanged.
  The unticked-box check is replaced by an evidence check that fails, naming each line, when
  a label carries nothing after its colon, and fails when the `## Evidence` section is
  absent. `- [ ]` no longer fails anything anywhere: a grep cannot tell a stray box inside
  pasted gate output from a real unticked item.
- `docs/WORKFLOW.md` — §2 to §6 are rewritten around the three commands in `ps-toolbox`
  (`Start-ToolChange`, `Complete-ToolChange`, `Publish-ToolRelease`), plus a section on
  where they come from and on a repository with no CI reporting `CiChecks / NotAssessed` and
  merging anyway. §1 and §7 to §11 are unchanged, including the "Rewriting `main`"
  prohibition and §8's account of what the Free plan actually enforces.

Nothing outside those three files changed: `.githooks/pre-push` and `.gitattributes` were
compared against the template by blob SHA and already matched, and `README.md`, `ci.yml`,
`src/` and `tests/` are untouched.

### Added — 2026-08-13 (phase P4.4)

- Trunk-based workflow conventions backfilled from `TakeItoCloud/template-ps-tool`, which
  gained them after this repository was created: [`docs/WORKFLOW.md`](docs/WORKFLOW.md) (a
  mirror of the canonical rulebook), `.github/pull_request_template.md` (the PR self-review
  checklist), `.github/workflows/pr-hygiene.yml` (fails a PR on unticked checklist boxes or
  on a PR title that is not a Conventional Commit), and `.githooks/pre-push` (refuses direct
  pushes to `main`).
- `.gitattributes` forcing LF on `.githooks/**`, so a Windows checkout cannot hand the hook a
  CRLF shebang and silently break it.
- README: a pointer to `docs/WORKFLOW.md`, and a **Green gate** section. This repository
  uses the default gate — `Invoke-Pester -CI` plus the analyzer, both run from the
  repository root.

Git hooks are not cloned with a repository. Each existing clone needs
`git config core.hooksPath .githooks` run once before the pre-push hook is live.

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

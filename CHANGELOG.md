# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

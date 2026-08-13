# ExchangeAssessment — Port Plan

## Purpose

ExchangeAssessment is the extracted, versioned home of the Exchange on-prem/hybrid assessment
framework that lived in `infra-scripting-suite/powershell/Assessments/ExchangeAssessment`. It
collects read-only evidence from an Exchange organisation, scores it against a control
catalog, and exports an auditor-consumable bundle. "Finished" means: it runs end-to-end
against a real organisation with no manual repair, every collector distinguishes "could not
evaluate" from "passed", and the analyzer suspensions below are gone.

## Phases

| Phase | Scope | Status | Date |
| --- | --- | --- | --- |
| P1 | Extraction onto template-ps-tool: manifest hygiene, smoke tests, CI green | Done | 2026-08-13 |
| P2 | Retire the four analyzer suspensions (see *Inherited analyzer debt*) | Planned | |
| P3 | Runtime verification against a live Exchange organisation | Planned | |
| P4 | Finish the AV exclusion check — compare, do not just report | Planned | |
| P5 | Operational health checks: service, mail flow, replication, queues, index | Planned | |
| P6 | Ignore list, alerting and scheduled-run modes | Planned | |
| P7 | Operational documentation output | Planned | |
| P8 | Packaging and first tagged release | Planned | |

## The 5.1 constraint

The module runs inside the Exchange Management Shell, which is Windows PowerShell. The
manifest declares `PowerShellVersion = '5.1'` with
`CompatiblePSEditions = @('Desktop','Core')`, `PSUseCompatibleSyntax` targets `5.1` and `7.4`,
and a test asserts it. The house "add `#Requires -Version 7.4`" rule is deliberately not
applied — the same call as ADForestAssessment and ExchangeEnvironmentToolkit.

## Backlog detail

### P2 — Inherited analyzer debt

| Rule | Hits | What the fix means |
| --- | --- | --- |
| `PSAvoidUsingEmptyCatchBlock` | 19 | The big one. Collectors swallow per-control failures, so a control that could not be evaluated is indistinguishable from one that passed. The findings model already has `Unknown` outcomes and `HardFail` sufficiency for exactly this case, and several collectors use them properly on their outer error path — the 19 bare `catch { }` blocks are the ones that do not. In an evidence tool, a silent gap is worse than a failure. |
| `PSUseSingularNouns` | 7 | e.g. `Get-ExchAcceptedDomains`, `Get-ExchVirtualDirectories`. Internal to the module. |
| `PSUseShouldProcessForStateChangingFunctions` | 3 | `New-*` / `Save-*` / `Export-*` write to the run folder. The assessment itself never writes to Exchange. |
| `PSUseApprovedVerbs` | 2 | `Ensure-ExchLocalShell`, `Ensure-ExchADModule`, both private. |

### P3 — Runtime verification

The extraction was gated on static analysis and smoke tests only. No collector has been run
against an Exchange organisation from this repository. Run a full
`Invoke-ExchAssess.ps1` against a lab organisation and confirm: all 15 collectors return, the
hash manifest covers every evidence file, the CAB CSV is populated, and the Word report
generates.

### P4 — Finish the AV exclusion check

`MB.AV-01.AVExclusions.ps1` declares the Microsoft-recommended exclusion tokens —
`Microsoft\Exchange Server`, `TransportRoles`, `ClientAccess` — and then never compares the
collected exclusions against them. The collector reports what *is* configured; it does not
report what is *missing*, which is the question the control is actually asking. The variable
is kept with a documented analyzer suppression precisely so this gap stays visible.

### P5–P7 — Harvested from the Exchange siblings being archived

**Provenance warning, and it matters for P3-F.** Both harvest sources named for this phase
are third-party code, not authored in-house:

- `powershell/Exchange/GatherInfo/Test-ExchangeServerHealth.ps1` is Paul Cunningham's
  well-known health-check script (practical365.com). The inventory recommends "finish" for
  it, which would mean maintaining someone else's script.
- `powershell/Assessments/Exchange/Exc.Assess/Exc.Doc` is a community Exchange documenter
  (`Main.ps1` + `Template.doc` + XML-driven content), with its own readme and disclaimer.

Take the **ideas**, not the code. Neither should be vendored here.

**P5 — operational health checks (from `Test-ExchangeServerHealth.ps1`).** This tool assesses
*configuration*; that script tests *operation*. The gap is real and the checks are concrete:

- `Test-ServiceHealth` per server — are the required Exchange services actually running
- `Test-Mailflow` — end-to-end message delivery, not just connector configuration
- `Test-MAPIConnectivity` — client access actually works
- `Test-ReplicationHealth` — DAG replication beyond the static DAG config `DAG-01` collects
- `Get-MailboxDatabaseCopyStatus` → `CopyQueueLength`, `ReplayQueueLength`,
  `ContentIndexState` — the three numbers that say whether a DAG is healthy right now
- Server uptime, and last full backup age per database

`DAG-01` and `MB.DB-01` already collect the static shape of both; adding the live queue and
index state turns them from an inventory into a health check.

**P6 — ignore list and alerting (same source).** That script supports an `ignorelist.txt` for
servers, DAGs and databases that should be skipped (test and dev boxes), plus an
`-AlertsOnly` mode that emails only when something is actually wrong. Both are what make a
check runnable on a schedule instead of on demand. This tool has neither.

**P7 — operational documentation (from `Exc.Doc`).** That documenter separates *collection*
from *rendering*: collect on a server into a `Data\` folder, then generate the Word document
on any machine that has Word, driven by XML that says which sections appear in what order.
Two things worth taking: the split, so a server without Word can still be assessed (this tool
already leans that way — its Word step is a Python helper), and content configurability, so a
section can be dropped from a client deliverable without touching code. Its output is
*operational documentation* rather than an audit finding set, which is a genuinely different
deliverable from the same evidence.

## Rules

- A phase is **Done** only at GREEN: `Invoke-Pester` all-pass **and**
  `Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1`
  with zero findings, and no stubs, placeholders, or `TODO` markers left in the code.
  Anything short of that stays `In progress`.
- Every phase updates **this file** (Status and Date on its row) and **CHANGELOG.md**
  (an entry under `## [Unreleased]`) in the same commit as the code.
- Nothing is deferred silently. Work moved out of a phase becomes a **new row** in the
  table above with its own scope and `Planned` status — it is never dropped in a comment
  or left implicit in the commit message.
- The assessment stays read-only against Exchange and AD. Any phase that introduces a write
  must ship it behind `SupportsShouldProcess` and cover `-WhatIf` in tests.
- A control that could not be evaluated reports `Unknown`, never a silent pass. That is the
  whole point of P2.
- No fabricated data: sample output, fixtures, and documentation examples reflect what
  the code actually produces.
- Third-party scripts are read for ideas, never vendored.

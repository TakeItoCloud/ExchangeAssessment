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
| P2 | Retire the four analyzer suspensions (see *Inherited analyzer debt*) | Mostly done | 2026-08-31 |
| P3 | Runtime verification against a live Exchange organisation | Planned | |
| P4 | Finish the AV exclusion check — compare, do not just report | Done | 2026-08-31 |
| P5 | Operational health checks: service, mail flow, replication, queues, index | Partly done | 2026-08-31 |
| P6 | Ignore list, alerting and scheduled-run modes | Planned | |
| P7 | Operational documentation output | Superseded by P9 | 2026-08-31 |
| P8 | Packaging and first tagged release | Planned | |
| P9 | Inventory model, threshold configuration, CSV and JSON reporting | Done | 2026-08-31 |
| P10 | Full-environment collector coverage (see *P10 scope*) | Partly done | 2026-09-01 |
| P11 | Exchange Online collection for the tenant side of a hybrid organisation | Planned | |

## The 5.1 constraint

The module runs inside the Exchange Management Shell, which is Windows PowerShell. The
manifest declares `PowerShellVersion = '5.1'` with
`CompatiblePSEditions = @('Desktop','Core')`, `PSUseCompatibleSyntax` targets `5.1` and `7.4`,
and a test asserts it. The house "add `#Requires -Version 7.4`" rule is deliberately not
applied — the same call as ADForestAssessment and ExchangeEnvironmentToolkit.

## Backlog detail

### P2 — Inherited analyzer debt

Two of the four suspensions are gone as of P9 and now fail the build.

| Rule | Hits then | Hits now | State |
| --- | --- | --- | --- |
| `PSAvoidUsingEmptyCatchBlock` | 19 | 0 | **Cleared.** Every collector was rewritten to report `Unknown`/`HardFail` with a reason instead of swallowing the failure. The rule is enabled explicitly in the settings file so a silent gap fails CI. |
| `PSUseApprovedVerbs` | 2 | 0 | **Cleared.** `Ensure-ExchLocalShell` and `Ensure-ExchADModule` are now `Assert-*`. |
| `PSUseSingularNouns` | 7 | 7 | **Suspended, not outstanding.** Six are collector functions whose names encode the control they implement; the seventh is `Save-ExchFindings`, which saves all of them. Renaming would make the names less accurate. |
| `PSUseShouldProcessForStateChangingFunctions` | 3 | 8 | **Suspended, not outstanding.** All on `New-*` factories. Three build in-memory objects and change nothing; the rest write only inside the run folder. Read-only against Exchange is enforced by the read-only cmdlet test instead, which is a real check rather than a naming convention. |

### P3 — Runtime verification

The extraction was gated on static analysis and smoke tests only. No collector has been run
against an Exchange organisation from this repository. Run a full
`Invoke-ExchAssess.ps1` against a lab organisation and confirm: all 15 collectors return, the
hash manifest covers every evidence file, the CAB CSV is populated, and the Word report
generates.

### P4 — Finish the AV exclusion check — Done 2026-08-31

`MB.AV-01` now compares each server's configured exclusions against the recommended folder and
process lists in `Config/Thresholds.psd1` and reports the gap per server, with a
`security.av-exclusion-gaps` section naming every missing entry. A server whose anti-malware
product is not Microsoft Defender is reported as not assessed rather than as compliant.

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

### P9 — Inventory, thresholds and reporting — Done 2026-08-31

Collectors return inventory sections plus findings; the report writers are generic over
sections. Every judgement value moved into `Config/Thresholds.psd1` with `-ConfigPath` for
per-client overrides. Output is CSV per area plus one `assessment.json`. Word, PDF and
Markdown output removed. See CHANGELOG for the full list, including the six correctness bugs
this uncovered.

### P10 scope — full-environment coverage

Three of the named gaps are closed: `SRV-01` (server inventory, roles, AD sites, service
health, component states), `TR.CFG-01` (organisation and per-server transport configuration,
transport and journal rules) and `REPL-01` (`Test-ReplicationHealth`, `Test-MAPIConnectivity`).

Still absent, in rough priority order:

- **Transport queues** — `Get-Queue`, `Get-Message`, queue age and depth
- **RBAC** — role groups, management role assignments, management scopes
- **Mailboxes** — inventory, quotas, archives, litigation hold
- **Retention and compliance** — retention policies and tags, audit configuration
- **Client access policies** — ActiveSync and OWA mailbox policies, `Get-CASMailbox`,
  authentication policies, mobile devices
- **Address lists** — address lists, GAL, offline address books, address book policies
- **Public folders**
- **TLS** — SCHANNEL and .NET registry state, `Get-AuthConfig` serialised data signing
- **Patch state** — `Get-HotFix`, Exchange Emergency Mitigation Service, CVE matrix against
  the build table
- **DNS posture** — MX, SPF, DMARC and MTA-STS for each authoritative accepted domain

Each is a registry row plus a collector file plus its threshold keys; the reporting layer does
not change.

### P11 scope — Exchange Online

`Connect-ExchOnline` behind `-IncludeExchangeOnline`, supporting interactive and app-only
authentication, plus collectors for EXO organisation configuration and accepted domains,
connectors, anti-spam and Defender policies, and migration endpoints. Cloud collectors are
already modelled in the registry (`Cloud = $true`) and are skipped unless the switch is given.
No credential may be written to the run folder.

### P3 note — property availability across versions

Collectors read Exchange object properties directly, and `Set-StrictMode -Version Latest`
makes a missing property throw. On a version that does not expose one, the dispatcher turns
that into an `Unknown`/`HardFail` finding naming the error rather than losing the control, so
the failure is visible — but it costs the whole control. Shaking this out is part of P3: run
against each Exchange version in scope and replace any property that turns out to vary with a
guarded read.

### Cosmetic backlog

Rationale text builds count phrases with a bare format placeholder, so a count of one reads
"1 servers are..." rather than "1 server is...". Cosmetic only; the counts and the named
objects are correct.

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

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
| P5 | Operational health checks: service, mail flow, replication, queues, index | Done | 2026-09-01 |
| P6 | Ignore list, alerting and scheduled-run modes | Dropped | 2026-09-02 |
| P7 | Operational documentation output | Superseded by P9 | 2026-08-31 |
| P8 | Packaging and first tagged release | Dropped | 2026-09-02 |
| P9 | Inventory model, threshold configuration, CSV and JSON reporting | Done | 2026-08-31 |
| P10 | Full-environment collector coverage (see *P10 scope*) | Done | 2026-09-01 |
| P11 | Exchange Online collection for the tenant side of a hybrid organisation | Done | 2026-09-01 |
| P12 | Correctness fixes verified against Microsoft Learn: relay permission check, refreshed and externalised build table, 2016/2013 AD preparation levels, functional-level and OS supportability corrections, per-server queue scope | Done | 2026-09-02 |
| P13 | Deployment config contract: shipped template, `New-ExchDeploymentConfig`, and a preflight warning naming what a greenfield deployment has not supplied (see *P13*) | Done | 2026-09-11 |
| P14 | Greenfield deployment (`DEP.*`) collectors that read the P13 `Deployment` section | Planned | |
| P15 | Generate the P13 deployment config from an approval table | Planned | |

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
`Invoke-ExchAssess.ps1` against a lab organisation and confirm: all 32 collectors return, the
hash manifest covers every file the run produced, `csv/` holds one file per inventory section
plus `findings.csv`, `run.collectors.csv` and `run.errors.csv`, and `assessment.json` parses
and carries `inventory`, `findings` and `controls`. Then confirm that every control reports
either a computed outcome or an explicit `Unknown` with a reason.

Two things to shake out specifically, because CI cannot: the relay permission read in
`TR.CO-01` needs rights to run `Get-ADPermission` against receive connectors, and `TR.QUE-01`
needs to reach every transport server. Both report `Unknown` per object rather than failing,
so the run will succeed either way — check the counts.

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

**P6 — ignore list and alerting (same source). Dropped 2026-09-02.** That script supports an
`ignorelist.txt` for servers, DAGs and databases that should be skipped, plus an `-AlertsOnly`
mode that emails only when something is actually wrong. Both belong to a monitoring tool that
runs on a schedule and tells you when today differs from yesterday.

Dropped because this is not that tool and the two goals pull against each other. This is a
point-in-time assessment run by a consultant against a client organisation: every control
reports, the operator reads the whole report once, and the value is in the completeness. An
ignore list is a way to make a finding disappear without fixing it, which is precisely what the
"no silent pass" rule exists to prevent - a client-specific baseline belongs in `-ConfigPath`,
where the changed threshold is visible in the run's own configuration rather than hidden in a
list of exemptions. Alerting needs somewhere to send the alert and a previous run to compare
against, neither of which this tool has. Anyone wanting scheduled monitoring should run a
monitoring product; the artifact this tool produces is a report, not a signal.

**P7 — operational documentation (from `Exc.Doc`).** That documenter separates *collection*
from *rendering*: collect on a server into a `Data\` folder, then generate the Word document
on any machine that has Word, driven by XML that says which sections appear in what order.
Two things worth taking: the split, so a server without Word can still be assessed (this tool
already leans that way — its Word step is a Python helper), and content configurability, so a
section can be dropped from a client deliverable without touching code. Its output is
*operational documentation* rather than an audit finding set, which is a genuinely different
deliverable from the same evidence.

### P8 — Packaging and first tagged release — Dropped 2026-09-02

`build/package.ps1` already writes `dist/ExchangeAssessment-v<version>.zip`, and the module
imports from a clone with no build step, so the packaging half of the phase is done and needs
no phase of its own. The tagged release half is dropped rather than deferred: PORT-PLAN P3 -
running this against a real Exchange organisation - has never happened, and tagging a release
of an assessment tool that has never been pointed at the thing it assesses would put a version
number on an untested claim. P12 exists because reading the code carefully found six answers it
was getting wrong; only a real run will find the rest.

The `ModuleVersion` bump that a release would have carried now happens per phase instead, under
the rule below. When P3 closes, open a release phase then, with the run behind it.

### P9 — Inventory, thresholds and reporting — Done 2026-08-31

Collectors return inventory sections plus findings; the report writers are generic over
sections. Every judgement value moved into `Config/Thresholds.psd1` with `-ConfigPath` for
per-client overrides. Output is CSV per area plus one `assessment.json`. Word, PDF and
Markdown output removed. See CHANGELOG for the full list, including the six correctness bugs
this uncovered.

### P10 scope — full-environment coverage

Closed. With the four Exchange Online controls added in P11 the organisation is covered by 32
controls; the thirteen this phase added are:

| Added | Control |
| --- | --- |
| Server inventory, roles, AD sites, service health, component states | `SRV-01` |
| Organisation and per-server transport configuration, transport and journal rules | `TR.CFG-01` |
| `Test-ReplicationHealth` and `Test-MAPIConnectivity` | `REPL-01` |
| Transport queue depth, age, retry and suspended state | `TR.QUE-01` |
| Role groups, privileged membership, role assignments and scopes | `RBAC-01` |
| Mailbox, quota and archive inventory, external forwarding | `MB.INV-01` |
| Retention policies and tags, holds, administrator and mailbox audit | `RET-01` |
| Authentication policies, Basic auth, OWA and mobile policies, per-mailbox protocols, devices | `CAS-01` |
| Address lists, GAL, offline address books, address book policies | `AL-01` |
| Public folder mailboxes, hierarchy, legacy databases | `PF-01` |
| SCHANNEL and .NET TLS state, serialised data signing | `TLS-01` |
| Security update currency, Emergency Mitigation Service, Windows patch cycle | `PTCH-01` |
| MX, SPF and DMARC per authoritative domain | `DNS-01` |

Deliberately not covered, with reasons:

- **`Test-Mailflow`** sends live probe messages, which is a write. Mail flow is assessed from
  connector configuration, transport configuration and queue state instead.
- **`Get-Message`** returns per-message data that would be a privacy exposure in an assessment
  artifact. `TR.QUE-01` reports queue depth and age, not message contents.
- **Performance counters** (`Get-Counter`) need a sampling window to mean anything; a
  point-in-time assessment would report noise.

### P11 — Exchange Online — Done 2026-09-01

`Connect-ExchOnlineSession` behind `-IncludeExchangeOnline`, supporting interactive, app-only
certificate and managed identity authentication, plus `CLD.ORG-01`, `CLD.CONN-01`, `CLD.SEC-01`
and `CLD.MIG-01`. Cloud collectors are marked `Cloud = $true` in the registry and are skipped,
visibly, unless the switch is given.

Two properties are enforced by tests rather than by convention:

- **Prefix isolation.** The tenant session is imported with a command prefix, and cloud
  collectors read only through `Invoke-ExchCloudQuery`, which resolves the prefixed name and
  will not fall back to the unprefixed one. Without this, a cloud collector running inside the
  Exchange Management Shell would silently report on-premises data as tenant data. A test scans
  the syntax tree of every `CLD.*` collector and fails on any direct Exchange cmdlet call.
- **No credential in the run folder.** `Start-Transcript` records the launching command line, so
  `Protect-ExchRunTranscript` redacts the app id, thumbprint, UPN and managed identity account id
  before the hash manifest is written. The tenant name is deliberately kept.

### P3 note — property availability across versions

Collectors read Exchange object properties directly, and `Set-StrictMode -Version Latest`
makes a missing property throw. On a version that does not expose one, the dispatcher turns
that into an `Unknown`/`HardFail` finding naming the error rather than losing the control, so
the failure is visible — but it costs the whole control. Shaking this out is part of P3: run
against each Exchange version in scope and replace any property that turns out to vary with a
guarded read.

### P12 — Correctness fixes — Done 2026-09-01

Six fixes, each verified against Microsoft Learn, that had to land before the tool was pointed
at a real organisation. CHANGELOG carries the detail. In short:

- `TR.CO-01`'s open-relay test was the shape of Microsoft's own default frontend connector, so
  it returned NonCompliant/High on every correctly built organisation. It now reads the relay
  permission itself and is three-state.
- The build table was externalised to `Config/BuildTable.psd1`, refreshed to 2026-09-02, and
  given a staleness rule of its own.
- Active Directory preparation levels now cover Exchange 2016 and 2013 as well as 2019 and SE.
- `Windows2025Forest`/`Windows2025Domain` were removed: Microsoft has not added functional
  level 10 to the Exchange supportability matrix, so claiming it was an unverified assertion.
- Operating system supportability is per Exchange version rather than a single global floor.
- `TR.QUE-01` queries each transport server by name instead of implying the local one.

### P13 — Deployment config contract — Done 2026-09-11

The assessment discovers domain controllers, domains and the forest, and finds existing Exchange
servers with `Get-ExchangeServer`. It cannot discover a server that is not an Exchange server
yet, so a greenfield Exchange Server SE deployment's target servers, file share witness and
planned names have to be supplied by the operator. P13 defines where: a `Deployment` section,
shaped by the shipped and empty `Config/Deployment.template.psd1`, written out by
`New-ExchDeploymentConfig` and passed back with the existing `-ConfigPath`. Preflight warns -
never fails - when the section is missing, with the template's resolved path and both commands,
and names exactly the keys a partly filled config leaves empty. `Invoke-ExchAssess.ps1` prints
that warning as a delimited block.

No collector reads the section yet. P14 owns every `DEP.*` control and any change to
`CollectorRegistry.ps1`; P15 owns generating the config from an approval table.

Verified on the dev VM only, under PowerShell 7.6 and Windows PowerShell 5.1, with synthetic
`.test` host names, plus one end-to-end `Invoke-ExchAssess.ps1` run on that VM with no Exchange
present, which completed and printed the block. No Exchange organisation, domain controller or
client host was involved, because the phase reads none.

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
- **A phase that changes what a finding says bumps `ModuleVersion` in the same commit.** Any
  change to an outcome, a severity, a rationale, or the set of controls counts - two runs
  reporting different things about the same organisation must not claim to be the same version
  of the tool. Reports carry the version, so this is what lets a reader tell "the organisation
  changed" from "the tool changed its mind". Minor version for changed findings, patch for
  fixes that leave every finding identical.
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

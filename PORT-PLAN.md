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
| P14 | Greenfield deployment (`DEP.*`) collectors that read the P13 `Deployment` section (see *P14*) | In progress | 2026-09-11 |
| P14.1 | `DEP.TGT-01` target server prerequisite readiness, `Config/PrereqTable.psd1` and `-PrereqTablePath` | In progress - green over mocks; first real run is P14.7 | 2026-09-11 |
| P14.2 | `DEP.NET-01` port reachability probed from each target server outward, `Config/PortMatrix.psd1` and `-PortMatrixPath` | In progress - green over mocks; first real run is P14.8 | 2026-09-11 |
| P14.3 | `DEP.WIT-01` file share witness prerequisites | In progress - green over mocks; first real run is P14.9 | 2026-09-11 |
| P14.4 | `DEP.NAME-01` name and DNS availability for the planned names | In progress - green over mocks; first real run is P14.10 | 2026-09-11 |
| P14.5 | `DEP.VOL-01` database and log volume checks on the target servers (`DatabaseVolume`, `LogVolume`) | In progress - green over mocks; first real run is P14.12 | 2026-09-11 |
| P14.6 | `DEP-01` greenfield roll-up, declaring `ENV.VERS-01` and the five `DEP.*` controls in `Requires` | In progress - green over mocks; first end-to-end real run is P14.13 | 2026-09-11 |
| P14.7 | First run of `DEP.TGT-01` against real target servers - owner: Carlos Annes (operator) | Planned | |
| P14.8 | First run of `DEP.NET-01` from real target servers over a real network path - owner: Carlos Annes (operator) | Planned | |
| P14.9 | First run of `DEP.WIT-01` against a real, sanitised witness server, before and after `/PrepareAD` - owner: Carlos Annes (operator) | Planned | |
| P14.10 | First run of `DEP.NAME-01` against a real directory and real DNS - owner: Carlos Annes (operator) | Planned | |
| P14.11 | Add `WitnessDirectory` to the P13 template and key list as an optional key, so the `DEP.WIT-01` witness directory check can be found from the template; preflight must not report it missing | Planned | |
| P14.12 | First run of `DEP.VOL-01` against real target servers with real database and log volumes - owner: Carlos Annes (operator) | Planned | |
| P14.13 | First end-to-end real run of `DEP-01`: one `Invoke-ExchAssess.ps1` run with a filled deployment config against a real, sanitised greenfield environment, all six upstream controls running - owner: Carlos Annes (operator) | Planned | |
| P15 | Generate the P13 deployment config from an approval table | Planned | |
| P16 | Test debt reported by P13: the comment-based help guard names one function, so it cannot catch the next export added without help, and the twelve older exports have none; and nothing runs the suite under Windows PowerShell 5.1 (see *P16*) | Planned | |
| P17 | Reported by P14.6: `UPG-01`, and `ENV.VERS-01` within itself, combine an `Unknown` with a `Compliant` through `Get-ExchWorstOutcome`, which returns `Compliant`; decide whether they should fail closed as the `DEP.*` controls do (see *P17*) | Planned | |

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

When P13 closed no collector read the section. P14 owns every `DEP.*` control and any change to
`CollectorRegistry.ps1`; P15 owns generating the config from an approval table.

Verified on the dev VM only, under PowerShell 7.6 and Windows PowerShell 5.1, with synthetic
`.test` host names, plus one end-to-end `Invoke-ExchAssess.ps1` run on that VM with no Exchange
present, which completed and printed the block. No Exchange organisation, domain controller or
client host was involved, because the phase reads none.

### P14 — Greenfield deployment collectors

**P14.1 `DEP.TGT-01` — In progress 2026-09-11.** Every other collector that inspects servers
takes its list from `Get-ExchangeServer`, so it cannot see a server that is not an Exchange server
yet. `DEP.TGT-01` reads `Deployment.TargetServers` and nothing else - no `Get-ExchangeServer`, no
guess from the directory - and checks each named server against the Exchange Server SE
prerequisites in `Config/PrereqTable.psd1`: seventeen keys, one check each. Every value was read
on Microsoft Learn on 2026-09-11 and carries its URL and date. Five are `$null` because Learn does
not state them, and those checks report `Unknown`; the README lists them.

Each name is resolved before anything is sent to it. A name that resolves is read over CIM and
over WinRM, which fail independently, class by class and item by item; the per-server record says
which mechanisms answered, and each check names the mechanisms it needs. A supplied target that is
a domain controller, already an Exchange server, not a domain member or in another forest is a
finding, not a failure.

Built and green on the dev VM against mocks only. That says the mocks behave as described, and
nothing about a real server; the phase stays In progress until P14.7.

**P14.7 — first real run. Owner: Carlos Annes (operator).** Against at least one real,
sanitised target server, from a host that can reach it: run `Invoke-ExchAssess.ps1` with a filled
deployment config, and confirm that the name resolves, that CIM and WinRM each answer or fail with
their own error, that every one of the seventeen checks has a row with an outcome or an `Unknown`
naming its cause, that the uninstall-key reading finds the Visual C++ 2012 and UCMA entries by the
names in the table, that `Get-WindowsFeature` returns `InstallState` over WinRM, and that the
volume holding `%ProgramFiles%` is matched. Record what differs from the mocks.

**P14.2 `DEP.NET-01` — In progress 2026-09-11.** A reachability result is about one source reaching
one destination, so every probe runs on the target over WinRM, and every result names the target
it was sent to and the host name the target reported while it ran. Flows come from
`Config/PortMatrix.psd1` (twenty, each with its Learn URL and read date, `-PortMatrixPath` to
override); domain controllers from the directory, the witness and peers from the `Deployment`
section, DNS servers from the target's own configuration. A target WinRM cannot reach is `Unknown`
on every flow and is never probed from the assessment host instead. A timeout is `Unknown`, never
`Closed`; a `Closed` flow is reported, not judged. One port is `$null` - the WMI flow the DAG uses to
create the witness share, which Learn names without a port - and that flow is measured and stays
`Unknown`. Exchange's broader rule, unrestricted traffic to domain controllers and between Exchange
servers including the dynamic RPC range, cannot be proven by probing fixed ports, and the control
says so rather than implying it.

Built and green on the dev VM against mocks, plus direct execution of the probe scriptblock against
loopback listeners under 7.6 and 5.1. That says the probe runs and the mapping holds, and nothing
about a network path between real servers; the phase stays In progress until P14.8.

**P14.8 — first real run of `DEP.NET-01`. Owner: Carlos Annes (operator).** From a host that reaches
at least two real, sanitised target servers over WinRM, with a filled deployment config naming them
and a witness: run `Invoke-ExchAssess.ps1` and confirm that each result's `ProbeOrigin` is the
target's own host name (`OriginCheck` Match), that the domain controllers probed are the directory's
and the DNS servers the target's own, that a refused port reads `Closed` and a filtered one `Unknown`
with cause `timeout`, how long a refusal takes against the 5000 ms default, what the `WitnessWmi`
measurement records inside a WinRM session with no delegation, and how long the run takes against
the forest's number of domain controllers. Record what differs from the mocks.

**P14.3 `DEP.WIT-01` - In progress 2026-09-11.** The witness comes from `Deployment.WitnessServer`
and nowhere else; empty - the shipped template's state - is one `Unknown` finding that contacts
nothing, not an error. Thirteen checks, each tied to a Learn statement read on 2026-09-11, with the
values in `Config/Thresholds.psd1` under `WitnessPrerequisites`. The server is read the `DEP.TGT-01`
way: `Get-ExchTargetState` now takes the CIM queries and WinRM reader as parameters, and the
per-mechanism gate was extracted to `Get-ExchTargetMechanismGate`, so both controls degrade
identically. The Exchange Trusted Subsystem grant is three states - not in the directory yet
(`Unknown`, expected before `/PrepareAD`), present and not a local Administrator (`NonCompliant`),
present and a member (`Compliant`) - and an unreadable directory is a fourth cause, never one of
them. Learn does not forbid an Exchange server as witness - it recommends one - so that is reported,
not failed. Two values are measured rather than read: the firewall rule-group ids, read on the dev
VM's Windows 11, which P14.9 confirms on Windows Server. The optional `WitnessDirectory` key is read
but not yet in the template; P14.11 owns that.

**P14.4 `DEP.NAME-01` - In progress 2026-09-11.** Checks that each planned name is free, not that it
exists. The DAG name: at most 15 characters (manage-dags), a valid computer name (KB 909264), held
by no computer object in the forest, by no planned server, and by no object under
`CN=Microsoft Exchange` in the configuration partition - where an existing DAG lives; the schema
pages name the class `Exch-MDB-Availability-Group` but not its LDAP name, so the search is by name,
not class. Target and witness names are judged against the server itself, as the operator decided on
2026-09-11: a member server holds its own computer account, so one object whose `dNSHostName` is the
supplied name is expected, and any other holder or a duplicate is a finding. Internal names must not
exist in DNS. Every rationale states the scope of the global catalog and resolvers queried and what
they cannot see.

**P14.9 - first real run of `DEP.WIT-01`. Owner: Carlos Annes (operator).** Against a real,
sanitised witness server: confirm the two firewall group ids return rules on Windows Server, that
`Get-WindowsFeature -Name FS-FileServer` answers over WinRM, that the WinNT read of the local
Administrators group returns SIDs, that `Get-ADDomainController -Discover -Service GlobalCatalog` and
`Get-ADGroup` over port 3268 find the Exchange Trusted Subsystem group, and that the grant reads state
(a) before `/PrepareAD` and (b) or (c) after it. Record what differs from the mocks.

**P14.10 - first real run of `DEP.NAME-01`. Owner: Carlos Annes (operator).** Against a real
directory and DNS: confirm the global catalog search matches computer objects by `cn`,
`sAMAccountName` and `dNSHostName`, that a domain-joined target reads `OwnAccount`, that the
configuration search finds an existing DAG by name and reads `NoExchangeOrganization` in a forest
not prepared for Exchange, and that `Resolve-DnsName -DnsOnly` separates `NameDoesNotExist` from
`NoAddressRecord` against the client's resolvers. Record what differs from the mocks.

**P14.5 `DEP.VOL-01` - In progress 2026-09-11.** Owns the checks the P13 template promises for
`DatabaseVolume` and `LogVolume`. On each target, over CIM only (`Get-ExchTargetState -CimOnly`, a new
switch that leaves the other callers unchanged), for each supplied volume: a volume is mounted at
exactly that path - a folder on another volume is reported as absent, naming the volume it would fall
on, and that volume is never judged in its place; free space against `DeploymentVolumes`; NTFS or ReFS;
and the allocation unit size. Once per target, whether the two are the same volume. Read on Learn on
2026-09-11: storage-configuration gives "Supported: NTFS and ReFS" and, for allocation unit size,
"Supported: All allocation unit sizes. Best practice: 64 KB", so another size is reported, not failed.
Learn is not silent on separation, but it states a best practice that depends on the architecture -
for a stand-alone server separate volumes "backed by different physical disks", for high availability
"Isolation of logs and databases isn't required" - and no requirement, so a shared volume is reported
for the reader and never failed. Learn gives no absolute free-space figure, so both minimums ship
`$null` and that check is `Unknown` until the operator supplies them. Green over mocks only; P14.12 is
the first real run.

**P14.6 `DEP-01` - In progress 2026-09-11.** The greenfield counterpart of `UPG-01`, in its shape, and
deliberately without its two Exchange-organisation dependencies: it requires `ENV.VERS-01` and the five
`DEP.*` controls and not `EX.CH-01` or `ENV.OS-01`, both of which read `Get-ExchangeServer`. It fails
closed where `UPG-01` does not: any prerequisite not assessed makes the verdict `Unknown` before
`Get-ExchWorstOutcome` is consulted, so a `Compliant` never outvotes an `Unknown`, and a `Compliant` the
upstream itself marked `SoftFail` or `HardFail` is not counted as passed. A control that did not run
and one that ran and reported `Unknown` carry different statuses and messages. The rationale always
writes three groups - passed, did not pass, could not be assessed with the cause - an empty one as
`(0): none`. With the shipped reference files it cannot report `Compliant`; the README names every
`$null` that stops it. Green over mocks only; P14.13 is the first end-to-end real run.

**P14.12 - first real run of `DEP.VOL-01`. Owner: Carlos Annes (operator).** Against at least one real,
sanitised target server with the planned volumes created: confirm that `Win32_Volume` over CIM returns
`Name`, `DeviceID`, `FileSystem`, `FreeSpace` and `BlockSize` for a drive-letter volume and for a
mount-point volume, that a mount point is matched by its own path and a folder is not, and that the
free-space figures supplied from the sizing are judged. Record what differs from the mocks.

**P14.13 - first end-to-end real run of `DEP-01`. Owner: Carlos Annes (operator).** One
`Invoke-ExchAssess.ps1` run with a filled deployment config against a real, sanitised greenfield
environment: confirm that all six upstream controls ran before `DEP-01` (`csv/run.collectors.csv`),
that its three groups match their findings one for one, that a control skipped with
`-SkipDomainQueries` reads "did not run", and what the verdict is before and after `/PrepareAD`. Record
what differs from the mocks.

### P16 — Test debt reported by P13

Two gaps P13 reported and did not close:

- The comment-based help test checks a named list holding one function, `New-ExchDeploymentConfig`.
  The next export added without help will not be caught, and the twelve exports that predate P13
  carry a file header instead of help. Make the guard cover every name in `FunctionsToExport`,
  and backfill the twelve so it can.
- The dev VM's Windows PowerShell 5.1 has only Pester 3.4.0, so the suite never runs under the
  edition the module actually ships for. P13 and P14.1 exercised new code under 5.1 by direct
  execution only. Automate a 5.1 regression - a Pester 5 install for Windows PowerShell, or a
  `windows-latest` CI leg under `powershell`.

### P17 — Roll-ups that let a Compliant outvote an Unknown

Found while reading `UPG-01` as the model for `DEP-01`. `Get-ExchWorstOutcome` returns `Compliant` for
`@('Compliant','Unknown')` - its own comment says "Unknown only wins when there is nothing else" - and
`UPG-01` hands it an `Unknown` for an upstream that did not report. Run on the dev VM on 2026-09-11 with
`EX.CH-01` absent from `-Upstream` and the other two `Compliant`, `UPG-01` returned outcome `Compliant`,
sufficiency `SoftFail`, rationale "Not assessed: Supported Exchange product version and build.".
`ENV.VERS-01` combines its own items the same way, so unreadable Exchange preparation values beside
supported functional levels yield `Compliant` with sufficiency `SoftFail`. The `DEP.*` collectors avoid
this by adding `Compliant` only when nothing else fired. Changing either would change what they report,
so it is a phase of its own, with a `ModuleVersion` bump; `DEP-01` already reads a `SoftFail` `Compliant`
as not assessed.

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

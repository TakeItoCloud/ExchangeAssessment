# ExchangeAssessment

## Purpose

ExchangeAssessment reads an on-premises or hybrid Exchange organisation and reports two things:
the **configuration** it found, and the **problems** in that configuration. It is read-only —
every collector reads, and the only writes are into the local run folder.

A run drives 34 collectors across the whole organisation - servers, Active Directory, Exchange
version and patch state, databases, DAG and replication, transport configuration, connectors and
queues, certificates, TLS, anti-malware, RBAC, mailboxes, retention and audit, client access,
public folders, address lists, hybrid, identity sync, DNS posture and event logs, and the
prerequisites and network reachability of the member servers named for a greenfield deployment -
plus, on request, the Exchange Online side of a hybrid organisation. It then writes:

- **`csv/`** — one CSV per configuration area, plus `csv/findings.csv`. The complete record.
- **`assessment.json`** — the whole assessment in one file: configuration inventory, findings
  with the reasoning behind each one, the Microsoft article behind each control, and the
  control catalog. Sized so it can be uploaded to an assistant for remediation advice.
- **`evidence/`** — the raw per-control JSON, `hash-manifest.json` covering every file the run
  produced, and a ZIP of the lot.

Extracted from `infra-scripting-suite/powershell/Assessments/ExchangeAssessment`.

## What it reports on

| Control | Covers |
| --- | --- |
| `SRV-01` | Server inventory: roles, AD site, required services, server component states |
| `ENV.VERS-01` | Forest and domain functional levels; Exchange AD preparation (`rangeUpper`, both `objectVersion` values); Schema Master readiness |
| `ENV.OS-01` | Server operating system supportability for the Exchange version installed on it, uptime, free disk |
| `EX.CH-01` | Exchange product version, support state, and build currency against a dated build table |
| `UPG-01` | Exchange Server SE readiness, rolled up from the three above |
| `MB.DB-01` | Database configuration (paths, size, quotas, retention, circular logging, backups) and copy health |
| `DAG-01` | DAG membership, witness and quorum, replication networks |
| `REPL-01` | `Test-ReplicationHealth` per DAG member and MAPI connectivity per mounted database |
| `TR.CO-01` | Send and receive connectors: relay permission, TLS, authentication, size limits |
| `TR.CFG-01` | Organisation transport config, shadow redundancy, Safety Net, per-server transport, transport and journal rules |
| `CERT-01` | Certificate expiry, key size, signature algorithm, service bindings, self-signed |
| `MB.AV-01` | Anti-malware exclusions, reported as what is **missing** per server |
| `AA.SPAM-01` | Malware agent and anti-spam filter posture |
| `HYB-01` | Hybrid configuration, intra-org connectors, OAuth, federation, organization relationships |
| `ID.SYNC-01` | Directory synchronisation service and cycle age |
| `LOG.EX-01` | Exchange-related error and critical events, grouped by provider and event id |
| `EX.ADM-01` | Accepted domains, remote domains, email address policies |
| `EX.VDIR-01` | Nine virtual directory types, Outlook Anywhere, Autodiscover SCP |
| `TR.QUE-01` | Transport queue depth, age, retry and suspended state, per transport server |
| `RBAC-01` | Role groups, privileged membership, management role assignments and scopes |
| `MB.INV-01` | Mailbox, quota and archive inventory; external forwarding |
| `RET-01` | Retention policies and tags, litigation hold, administrator and mailbox audit |
| `CAS-01` | Authentication policies and Basic auth, OWA and mobile device policies, per-mailbox protocols, devices |
| `AL-01` | Address lists, global address list, offline address books, address book policies |
| `PF-01` | Public folder mailboxes, hierarchy and legacy public folder databases |
| `TLS-01` | SCHANNEL protocol state, .NET strong cryptography, serialised data signing |
| `PTCH-01` | Security update currency, Emergency Mitigation Service, Windows patch cycle |
| `DNS-01` | MX, SPF and DMARC for every authoritative accepted domain |
| `DEP.TGT-01` | Greenfield deployment: Exchange Server SE prerequisites on the member servers named in `Deployment.TargetServers` - see *Planning a new deployment* |
| `DEP.NET-01` | Greenfield deployment: network reachability probed **from** each server in `Deployment.TargetServers` to the domain controllers, the witness, the other targets and its DNS servers - see *Planning a new deployment* |

Four more run only with `-IncludeExchangeOnline`:

| Control | Covers |
| --- | --- |
| `CLD.ORG-01` | Tenant organisation config, modern authentication, accepted domains |
| `CLD.CONN-01` | Inbound and outbound connectors, TLS enforcement, transport rules |
| `CLD.SEC-01` | Anti-spam, anti-malware, anti-phishing, Safe Links/Attachments, DKIM |
| `CLD.MIG-01` | Migration endpoints, batches and move requests |

Every finding states an outcome **and** the reasoning that produced it. A control that could
not be evaluated reports `Unknown` with the reason, never a silent pass.

### When something fails

Failures are recorded, not swallowed. Every failed query and every collector that throws is
written to `logs/run.jsonl` with the exception type, the fully qualified error id, the target,
the script and line it was thrown from, the offending source line, the full stack trace and the
whole inner-exception chain. The same failures appear as report rows in `csv/run.errors.csv`
and in the `run.errors` section of `assessment.json`, so a gap in the assessment is visible to
whoever reads the report rather than only to whoever reads the log.

`csv/run.collectors.csv` lists every collector with its status, duration and what it produced,
so a slow or skipped control is obvious at a glance.

## Requirements

- **Windows PowerShell 5.1** — the module runs inside the Exchange Management Shell on an
  Exchange server, or a remote EMS session. The manifest declares 5.1 with
  `CompatiblePSEditions = @('Desktop','Core')`; do not raise it.
- Exchange Server, with `Get-ExchangeServer` available in the session
- RSAT `ActiveDirectory` — for the domain, forest and schema collector
- `ADSync` — optional; the identity sync collector reports "not assessed from here" without it
- [Pester](https://pester.dev) 5.0+ and
  [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) 1.21+ — for the quality gate

## Permissions

The current Windows and Active Directory context is used — no separate credential prompt.
View-Only Organization Management in Exchange plus domain read covers most collectors. The
event log and anti-malware exclusion collectors need local administrative rights on the
Exchange servers.

Four controls need a little more, and say so in their output rather than failing:

- **`TR.CO-01`** runs `Get-ADPermission` against each receive connector to find out whether an
  anonymous principal actually holds `ms-Exch-SMTP-Accept-Any-Recipient` — the permission that
  grants relay. Without rights to read connector permissions, or against an Edge Transport
  server's AD LDS instance, that read fails and the connector is reported as
  `AnonymousRelayRight = Unknown` with `RelayAssessable = False`. The control then reports
  `Unknown`/SoftFail naming those connectors, because open relay cannot be ruled out on them.
  It is never reported as a pass.
- **`TR.QUE-01`** reads queues on every transport server, not just the local one. A server it
  cannot reach is named in the finding and makes the control SoftFail.
- **`DEP.TGT-01`** reads each server named in `Deployment.TargetServers` over CIM and over WinRM
  (`Invoke-Command`), so the account needs rights to query both on those servers. A mechanism it
  cannot use makes the checks that need it `Unknown`, naming the mechanism and the error; the
  checks the other mechanism answered still stand.
- **`DEP.NET-01`** runs its probes **on** each server named in `Deployment.TargetServers`, over
  WinRM, and reads the domain controllers from the directory with `Get-ADForest` and
  `Get-ADDomainController`. A target it cannot reach over WinRM has every flow `Unknown`, naming
  the error - it is never probed from the assessment host instead, because that would answer a
  different question. The WMI flow to the witness runs inside that WinRM session, where the
  operator's credentials do not pass on to a third host without delegation, so an access-denied
  there is about authentication rather than the network; the flow stays `Unknown` either way.

## Install

```powershell
git clone https://github.com/TakeItoCloud/ExchangeAssessment.git
Set-Location .\ExchangeAssessment
Import-Module .\src\ExchangeAssessment\ExchangeAssessment.psd1 -Force
```

## Usage

`-TenantHint` is mandatory; it names the run folder.

```powershell
# Assess an organisation
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso

# Skip the Active Directory domain/forest/schema queries
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -SkipDomainQueries

# Skip the mailbox enumeration (the one collector whose cost scales with the organisation)
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -SkipMailboxInventory

# Skip the external DNS lookups, for an assessment that must not leave the network
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -SkipDnsQueries

# Include the Exchange Online side of a hybrid organisation, signing in interactively
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -IncludeExchangeOnline `
    -CloudUserPrincipalName admin@contoso.onmicrosoft.com

# ...or unattended, with app-only certificate authentication
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -IncludeExchangeOnline `
    -CloudAppId <app id> -CloudCertificateThumbprint <thumbprint> `
    -CloudOrganization contoso.onmicrosoft.com

# Put every inventory row in assessment.json instead of summarising the large sections
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -FullInventory

# Assess against a client-specific baseline
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -ConfigPath .\contoso-thresholds.psd1

# Judge build currency against a newer copy of Microsoft's build list than the one shipped
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -BuildTablePath .\BuildTable.psd1

# Judge greenfield target servers against a newer or operator-verified prerequisite table
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -ConfigPath .\Deployment.psd1 -PrereqTablePath .\PrereqTable.psd1

# Probe the greenfield target servers against a newer or operator-verified port matrix
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -ConfigPath .\Deployment.psd1 -PortMatrixPath .\PortMatrix.psd1

# Skip the greenfield deployment checks, which contact the servers named in the deployment config
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -SkipDeploymentChecks
```

The script returns a summary object carrying `FindingsCount`, `SectionCount`, `CollectorsRun`,
`CollectorsSkipped`, `CollectorsFailed`, `ErrorsLogged`, `FindingsPath`, `AssessmentJson`,
`CsvFolder`, `CsvFileCount`, `BundleZip`, `RunFolder` and `HashManifest`.

### Output layout

```
<OutputRoot>/<tenant>-<utc timestamp>-<run id>/
  assessment.json           the whole assessment in one file
  csv/                      one CSV per configuration area, plus findings.csv,
                            run.collectors.csv and run.errors.csv
  evidence/                 raw per-control JSON, and findings/findings.json
  generated/                control catalog and framework crosswalks
  logs/                     run.jsonl and the transcript
  hash-manifest.json        SHA256 over everything above
  ExchEvidence-*.zip        all of it, packed
```

Run output contains real environment data and is gitignored — never commit it.

### Exchange Online

Cloud collection is off unless `-IncludeExchangeOnline` is given, and needs the
[`ExchangeOnlineManagement`](https://learn.microsoft.com/powershell/exchange/exchange-online-powershell-v2)
module. Interactive sign-in needs only `-CloudUserPrincipalName`; unattended runs use app-only
certificate authentication (`-CloudAppId`, `-CloudCertificateThumbprint`, `-CloudOrganization`)
or `-CloudManagedIdentity` on an Azure-hosted host.

Two things are worth knowing about how this is done.

**The tenant session is always imported with a command prefix** (`Cloud` by default, configurable
as `Cloud.CommandPrefix`). Exchange Online and on-premises Exchange share cmdlet names -
`Get-AcceptedDomain`, `Get-OrganizationConfig`, `Get-MigrationEndpoint` and many more. This module
normally runs inside the Exchange Management Shell, where those names already belong to the
on-premises organisation. Importing the tenant cmdlets unprefixed would shadow them and a cloud
collector would report on-premises data as though it came from the tenant. Cloud collectors
therefore read tenant data only through a helper that resolves the prefixed name and refuses to
fall back to the unprefixed one, and a test fails the build if one of them calls an Exchange
cmdlet directly.

**No credential reaches the run folder.** Only the authentication mode and the organisation are
recorded. `Start-Transcript` captures the command line that launched the run, so the transcript is
redacted before the hash manifest is written - an app id, certificate thumbprint, UPN or managed
identity account id becomes `[redacted]`, while the tenant name is kept because the report needs
it.

If the module is missing or the connection fails, each cloud control reports `Unknown` with the
reason rather than being silently dropped.

### Tuning it per client

Every value the tool judges against lives in
[`src/ExchangeAssessment/Config/Thresholds.psd1`](src/ExchangeAssessment/Config/Thresholds.psd1)
— supported builds and operating systems, certificate expiry windows, queue and backup
thresholds, the recommended anti-malware exclusions, TLS and DNS expectations. Nothing is baked
into collector code.

To assess a client whose baseline differs, copy the keys you want to change into your own
`.psd1` and pass it with `-ConfigPath`. Your values are merged over the defaults, so anything
you leave out keeps the default:

```powershell
@{
    Certificate = @{ ExpiryWarningDays = 45 }
    Dag         = @{ RequireHighAvailability = $true }
    Database    = @{ MaxBackupAgeDays = 1 }
}
```

### Keeping the build table current

Exchange build currency is judged against
[`src/ExchangeAssessment/Config/BuildTable.psd1`](src/ExchangeAssessment/Config/BuildTable.psd1),
a point-in-time copy of Microsoft's
[build numbers and release dates](https://learn.microsoft.com/exchange/new-features/build-numbers-and-release-dates)
that carries the date it was last refreshed. Microsoft updates that page every time a
cumulative update, security update or hotfix ships, so the file goes stale between releases of
this tool.

Two things follow. A build the table does not know is reported as unverifiable, never as
current. And once the table itself is older than `Exchange.MaxBuildTableAgeDays` (60 by
default), `EX.CH-01` says so in its rationale and drops to `PartiallyCompliant` — the tool
would rather admit the reference is old than quietly imply a server is patched.

To assess against a fresher list without editing the module, copy the file, add the new rows,
move `TableAsOf`, and pass it with `-BuildTablePath`. A missing or unparseable file is an error
rather than an empty table, because an empty table reports every server as unverifiable and
that looks a lot like a clean run.

### Planning a new deployment

Most of what the assessment needs, it finds for itself. Domain controllers, domains and the
forest are **discovered** from Active Directory, and existing Exchange servers with
`Get-ExchangeServer` — none of them is ever supplied. A greenfield Exchange Server SE deployment
also needs three things the directory cannot supply, because they do not exist yet: the member
servers that will **become** the Exchange servers, the server that will host the file share
witness, and the planned names — DAG name, internal namespace, database and log volumes. Those
**cannot be discovered and must be supplied**, in a deployment config. With the module imported
as under *Install*:

```powershell
# 1. Write a fillable copy of the shipped template
New-ExchDeploymentConfig -Path .\Deployment.psd1

# 2. Fill in TargetServers, WitnessServer, DagName, InternalNames, DatabaseVolume and LogVolume
notepad .\Deployment.psd1

# 3. Pass it to the run
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -ConfigPath .\Deployment.psd1
```

The template is
[`src/ExchangeAssessment/Config/Deployment.template.psd1`](src/ExchangeAssessment/Config/Deployment.template.psd1).
It ships empty, and every key carries a comment saying what it is, what supplying it enables and
what leaving it empty costs. Copy it out rather than editing it. The copy is merged over the
thresholds like any other `-ConfigPath` file, and a run takes one `-ConfigPath` — so a client
with threshold overrides as well keeps both in the same file.

Without a deployment config, preflight prints a delimited warning block saying that greenfield
deployment controls will report `Unknown`, with the template's full path and the commands
above. That is expected for an assessment of an existing organisation, and the run carries on.
A config with some keys still empty gets a warning naming exactly those keys.

`DEP.TGT-01` reads `TargetServers` and checks each named server against the Exchange Server SE
prerequisites. It never calls `Get-ExchangeServer` and never picks a server from the directory:
with `TargetServers` empty it reports one `Unknown` finding naming the template and both commands,
because none was supplied - not because there are none. Each name is resolved first, so a typo
is reported as a name that does not resolve rather than as a server that is down.

`DEP.NET-01` probes network reachability **from** each of those servers, because a port that is
open from the assessment host says nothing about the path from the server that will run Exchange.
The probe runs on the target over WinRM, and every result names its source and the host name the
target reported while it ran. It probes every domain controller the directory lists, the
`WitnessServer`, the other `TargetServers` and the target's own DNS servers. With `WitnessServer`
empty the witness flows are `Unknown` naming the key, and every other flow still runs. A timeout is
`Unknown`, never `Closed`, and a `Closed` flow is reported rather than judged - before Exchange is
installed nothing listens on a peer's replication port, so a refusal there is expected.

The other greenfield controls - witness, planned names, database and log volumes, and the roll-up -
are [PORT-PLAN.md](PORT-PLAN.md) phase P14. A filled copy holds client host names, so keep it out
of source control. `Deployment.psd1` is gitignored in this repository for that reason.

### Keeping the port matrix current

`DEP.NET-01` probes the flows in
[`src/ExchangeAssessment/Config/PortMatrix.psd1`](src/ExchangeAssessment/Config/PortMatrix.psd1):
each with its source and destination role, port, protocol, probe and purpose, and the Microsoft
Learn page and date it was read. Exchange Learn names no port list for traffic between Exchange
servers and domain controllers - it asks for that traffic to be unrestricted on any port - so the
domain controller flows are the Active Directory and Kerberos rows Windows Learn gives, and a target
on which they are all `Open` has not thereby been shown to meet the broader rule. As shipped, one
port is `$null`: the WMI flow the DAG uses to create the witness share, which Learn names without a
port. That flow is measured - the TCP connections the WMI attempt opened are recorded - and stays
`Unknown`. Each probe waits `PortProbe.TimeoutMilliseconds` (5000 by default) in
`Config/Thresholds.psd1`. To probe against a different table, copy the file, change it, and pass it
with `-PortMatrixPath`, which loads, validates and overrides as `-PrereqTablePath` does.

### Keeping the prerequisite table current

`DEP.TGT-01` judges against
[`src/ExchangeAssessment/Config/PrereqTable.psd1`](src/ExchangeAssessment/Config/PrereqTable.psd1):
supported operating system builds and editions, the minimum .NET Framework release value per
operating system, the Visual C++ 2012 and 2013 and UCMA 4.0 packages and their versions, IIS URL
Rewrite, the Windows feature lists, Remote Registry, free space on the install, system and queue
volumes, the page file rule and the pending-restart indicators. Every value carries the Microsoft
Learn page it was read from and the date.

Where Learn does not state a value the table holds `$null` and says so, and that check reports
`Unknown` - so with the shipped table the control never reports `Compliant`. As shipped, that is
the Visual C++ 2013 and IIS URL Rewrite uninstall names, the minimum Visual C++ and UCMA versions,
and the .NET Framework row for Exchange Server SE on Windows Server 2019. An operator who has
verified a value can supply it: copy the file, fill it in, and pass it with `-PrereqTablePath`,
which loads, validates and overrides exactly as `-BuildTablePath` does.

## Development

Development workflow (branching, PRs, releases): [`docs/WORKFLOW.md`](docs/WORKFLOW.md).

### Green gate

The commands that prove GREEN in this repository, per section 7 of
[`docs/WORKFLOW.md`](docs/WORKFLOW.md):

```powershell
Invoke-Pester -CI
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

Both must report zero failures and zero findings, run from the repository root. This is what
[.github/workflows/ci.yml](.github/workflows/ci.yml) runs on every push and pull request.

CI runs on Linux with no Exchange available, so the suite checks structure rather than
behaviour against a live organisation: that the catalog and the finding schema agree, that the
collector registry resolves and orders correctly, that **no collector invokes a cmdlet that
changes state** (checked against the parsed syntax tree, so a cmdlet named in a comment is not
mistaken for a call), that no collector hardcodes a `Compliant` outcome, that a failure is
captured with its full detail and reaches the run's error list, and that the CSV and JSON
writers produce what they promise. Verifying the collectors against a real organisation is
[PORT-PLAN.md](PORT-PLAN.md) phase P3 and is still open.

`PSScriptAnalyzerSettings.psd1` suspends two rules; the file records why each is cosmetic here
rather than outstanding work.

Package a release artifact:

```powershell
.\build\package.ps1
```

This writes `dist\ExchangeAssessment-v<version>.zip` and prints the artifact path.

## Related

`ExchangeAssessment` reports on an Exchange organisation.
[ExchangeEnvironmentToolkit](https://github.com/TakeItoCloud/ExchangeEnvironmentToolkit) is
the sibling that exports, transforms and rebuilds one during a migration. The `UPG-01`
Subscription Edition readiness roll-up here is the natural front door to that tool.

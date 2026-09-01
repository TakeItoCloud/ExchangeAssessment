# ExchangeAssessment

## Purpose

ExchangeAssessment reads an on-premises or hybrid Exchange organisation and reports two things:
the **configuration** it found, and the **problems** in that configuration. It is read-only —
every collector reads, and the only writes are into the local run folder.

A run drives 18 collectors across environment and server inventory, Exchange version,
databases, DAG and replication, transport configuration and connectors, certificates,
anti-malware, hybrid, identity sync, accepted domains, virtual directories and event logs,
then writes:

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
| `ENV.VERS-01` | Forest and domain functional levels; Exchange AD preparation (`rangeUpper`, both `objectVersion` values) |
| `ENV.OS-01` | Server operating system supportability, uptime, free disk |
| `EX.CH-01` | Exchange product version, support state, and build currency against a dated build table |
| `UPG-01` | Exchange Server SE readiness, rolled up from the three above |
| `MB.DB-01` | Database configuration (paths, size, quotas, retention, circular logging, backups) and copy health |
| `DAG-01` | DAG membership, witness and quorum, replication networks |
| `REPL-01` | `Test-ReplicationHealth` per DAG member and MAPI connectivity per mounted database |
| `TR.CO-01` | Send and receive connectors: open relay, TLS, authentication, size limits |
| `TR.CFG-01` | Organisation transport config, shadow redundancy, Safety Net, per-server transport, transport and journal rules |
| `CERT-01` | Certificate expiry, key size, signature algorithm, service bindings, self-signed |
| `MB.AV-01` | Anti-malware exclusions, reported as what is **missing** per server |
| `AA.SPAM-01` | Malware agent and anti-spam filter posture |
| `HYB-01` | Hybrid configuration, intra-org connectors, OAuth, federation, organization relationships |
| `ID.SYNC-01` | Directory synchronisation service and cycle age |
| `LOG.EX-01` | Exchange-related error and critical events, grouped by provider and event id |
| `EX.ADM-01` | Accepted domains, remote domains, email address policies |
| `EX.VDIR-01` | Nine virtual directory types, Outlook Anywhere, Autodiscover SCP |

Every finding states an outcome **and** the reasoning that produced it. A control that could
not be evaluated reports `Unknown` with the reason, never a silent pass.

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

# Put every inventory row in assessment.json instead of summarising the large sections
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -FullInventory

# Assess against a client-specific baseline
.\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -ConfigPath .\contoso-thresholds.psd1
```

The script returns a summary object carrying `FindingsCount`, `SectionCount`, `CollectorsRun`,
`CollectorsSkipped`, `CollectorsFailed`, `FindingsPath`, `AssessmentJson`, `CsvFolder`,
`CsvFileCount`, `BundleZip`, `RunFolder` and `HashManifest`.

### Output layout

```
<OutputRoot>/<tenant>-<utc timestamp>-<run id>/
  assessment.json           the whole assessment in one file
  csv/                      one CSV per configuration area, plus findings.csv
  evidence/                 raw per-control JSON, and findings/findings.json
  generated/                control catalog and framework crosswalks
  logs/                     run.jsonl and the transcript
  hash-manifest.json        SHA256 over everything above
  ExchEvidence-*.zip        all of it, packed
```

Run output contains real environment data and is gitignored — never commit it.

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
changes state**, that no collector hardcodes a `Compliant` outcome, and that the CSV and JSON
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

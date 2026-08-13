# ExchangeAssessment

## Purpose

ExchangeAssessment collects audit-ready evidence from an on-premises or hybrid Exchange
organisation and turns it into findings against a control catalog. A run drives 15 collectors
across environment, Exchange version, DAG, databases, certificates, transport, hybrid,
identity sync and event logs, writes the raw output as evidence files, and exports a bundle
with a hash manifest, a CAB remediation sheet and a Word report.

It is read-only against Exchange and Active Directory: every collector reads configuration
and writes only to the local run folder.

Extracted from `infra-scripting-suite/powershell/Assessments/ExchangeAssessment`.

## Controls

| Control | Collector |
| --- | --- |
| `ENV.OS-01` | Exchange server operating system |
| `ENV.VERS-01` | Domain, forest and schema versions |
| `EX.CH-01` | Exchange version and cumulative update |
| `EX.ADM-01` | Accepted domains |
| `EX.VDIR-01` | Virtual directories |
| `DAG-01` | Database availability group health |
| `MB.DB-01` | Mailbox database health |
| `MB.AV-01` | Antivirus exclusions |
| `TR.CO-01` | Transport connectors, including open-relay detection |
| `CERT-01` | Certificates and expiry |
| `AA.SPAM-01` | Anti-malware and anti-spam configuration |
| `HYB-01` | Hybrid configuration |
| `ID.SYNC-01` | Entra Connect / ADSync status |
| `LOG.EX-01` | Exchange event log errors |
| `UPG-01` | Subscription Edition readiness roll-up |

## Requirements

- **Windows PowerShell 5.1** — the module runs inside the Exchange Management Shell on an
  Exchange server, or a remote EMS session. The manifest declares 5.1 with
  `CompatiblePSEditions = @('Desktop','Core')`; do not raise it.
- Exchange Server, with `Get-ExchangeServer` available in the session
- RSAT `ActiveDirectory` — for the domain, forest and schema collectors
- `ADSync` — optional; the identity sync collector degrades without it
- Python 3 with `python-docx` — for the Word report (`New-ExchWordReport`)
- [Pester](https://pester.dev) 5.0+ and
  [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) 1.21+ — for the quality gate

## Permissions

The current Windows / AD context is used — no separate credential prompt. View-Only
Organization Management in Exchange plus domain read is enough for most collectors; the event
log and AV exclusion collectors need local administrative rights on the Exchange servers.

## Install

```powershell
git clone https://github.com/TakeItoCloud/ExchangeAssessment.git
Set-Location .\ExchangeAssessment
Import-Module .\src\ExchangeAssessment\ExchangeAssessment.psd1 -Force
```

## Usage

```powershell
.\scripts\Invoke-ExchAssess.ps1

# Skip the AD domain/forest/schema queries
.\scripts\Invoke-ExchAssess.ps1 -SkipDomainQueries
```

The script creates a run, collects, persists `findings.json`, closes the run and exports the
bundle, then returns a summary object carrying `FindingsCount`, `FindingsPath`, `BundleZip`,
`RunFolder` and `HashManifest`.

### Outputs

A run writes evidence files grouped by control domain, a `hash-manifest.json` covering them,
a CAB remediation CSV, and the Word technical report. Run output contains real environment
data and is gitignored — never commit it.

## Development

Run the tests:

```powershell
Invoke-Pester
```

Run the linter:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

Both must be clean — zero failing tests, zero analyzer findings — before a phase in
[PORT-PLAN.md](PORT-PLAN.md) may be marked Done. The same two commands run in CI on every
push and pull request (see [.github/workflows/ci.yml](.github/workflows/ci.yml)).

`PSScriptAnalyzerSettings.psd1` suspends four rules for the inherited code; each is a backlog
row in [PORT-PLAN.md](PORT-PLAN.md) and the settings file records the hit count and the work
the fix implies.

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

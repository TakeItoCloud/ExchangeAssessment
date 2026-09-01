# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed — 2026-09-01 (phase P12)

Six correctness fixes, each checked against Microsoft Learn before it was written. Every one of
them changed an answer the tool was giving, and two of them were giving that answer on every
organisation it would ever be pointed at.

- **`TR.CO-01` reported an open relay on every Exchange organisation.** The test was
  `AnonymousUsers -and an unrestricted remote IP range`, which is the exact shape of
  `Default Frontend <ServerName>` - the receive connector Exchange setup creates on every
  Mailbox server. So the control returned NonCompliant/High on 100% of correctly built
  organisations, which is worse than not having the control at all. The Anonymous users
  permission group maps to `NT AUTHORITY\ANONYMOUS LOGON` and grants accept-any-sender and
  submit; it does **not** grant `ms-Exch-SMTP-Accept-Any-Recipient`, the right that actually
  permits relay. Each receive connector's permissions are now read with `Get-ADPermission`
  (non-denied, non-inherited entries only) and the answer is three-state: `Granted`,
  `NotGranted` or `Unknown`. A connector is an open relay only when it is enabled, listens on an
  unrestricted range, and either grants that right to an anonymous principal or combines the
  `ExchangeServers` permission group with `ExternalAuthoritative` authentication. A connector
  whose permissions could not be read is reported as not assessable - an `Unknown` outcome and a
  SoftFail naming it - because a failed read cannot rule relay out. `AllowsAnonymous` and
  `UnrestrictedRange` remain as inventory columns; they are facts, just not verdicts.
- **The build table was twelve months stale and is now a data file.** `TableAsOf` said
  2026-08-31 while the newest Exchange Server SE row was 15.2.2562.20 from 2025-08-12 - and SE
  is the only supported Exchange version, so `EX.CH-01` returned `Unknown` for every correctly
  patched server. The table moved to `Config/BuildTable.psd1` (81 builds, verified 2026-09-02),
  `-BuildTablePath` points a run at a newer copy without editing the module, and a missing or
  unparseable table now throws instead of degrading to an empty one that would report every
  server as unverifiable. A new `Exchange.MaxBuildTableAgeDays` threshold makes the table's own
  age a finding: past 60 days the rationale says build currency is being judged against a stale
  reference and the outcome drops to PartiallyCompliant. A build absent from the table is still
  `Unknown`, never Compliant.
- **Active Directory preparation levels covered only Exchange 2019 and SE.** A 2016
  organisation - the main population an SE readiness assessment meets - reported
  "Unrecognised preparation level". Twenty-eight rows were added covering Exchange 2016 RTM to
  CU23, Exchange 2013 RTM to CU23, and Exchange 2019 CU2-CU6. Each `rangeUpper`/`objectVersion`
  pair appears exactly once, so no lower cumulative update can shadow a higher one, and a test
  enforces that.
- **`Windows2025Forest` and `Windows2025Domain` were removed as unverified.** Windows Server
  2025 introduced functional level 10, and Microsoft has not added it to the Exchange
  supportability matrix - which lists Windows Server 2016 and 2012 R2 only. Claiming support
  Microsoft has not stated is a worse failure than reporting the level as unlisted. `ENV.VERS-01`
  now words that outcome as "not listed by Microsoft as supported", naming the levels that are,
  rather than asserting the level is broken.
- **Operating system supportability is per Exchange version, not global.** `Resolve-ExchOsSupport`
  applied one floor of Windows Server 2019 to every server, so a correctly built Exchange 2016
  server on Windows Server 2016 was reported as running an unsupported operating system.
  `OperatingSystem.SupportMatrix` now holds a row per Exchange version with an explicit
  `SupportedBuilds` list - Exchange 2016's set has an upper bound as well as a floor, which a
  `>=` comparison cannot express - and `ENV.OS-01` resolves each server's Exchange family before
  judging its operating system, naming both sides in the rationale. An Exchange version with no
  row reports `Unknown` with the reason rather than a verdict. `ENV.VERS-01` also gained a
  Schema Master check: on Windows Server 2025 it must be on build 10.0.26100.7171 or later
  (KB5068861) before any `/PrepareSchema` or `/PrepareAD`, and a Schema Master whose operating
  system cannot be read makes that one item Unknown instead of losing the control.
- **`TR.QUE-01` reported one server's queues as though they were the organisation's.**
  `Get-Queue` with no `-Server` qualifier implies the local server. The collector now enumerates
  transport servers and queries each by name, adds a `Server` column, and states in the
  rationale how many servers were queried and how many answered. A server that did not answer is
  named, contributes an `Unknown` outcome and makes the control SoftFail. `Get-QueueDigest` was
  considered and rejected: it returns only queues holding ten or more messages, its data is one
  to two minutes old, it excludes subscribed Edge Transport servers, and it does not carry the
  retry age or `LastError` this control reports.

**Added** — `-BuildTablePath` on `Invoke-ExchAssess.ps1` and `New-ExchRun`; four thresholds
(`Transport.AnonymousSecurityPrincipals`, `Transport.RelayPermission`,
`Transport.ExternallySecuredAuthMechanism`, `Transport.ExternallySecuredPermissionGroup`),
`Exchange.MaxBuildTableAgeDays`, `ActiveDirectory.MinimumSchemaMaster2025Build` and
`OperatingSystem.SupportMatrix`; and a new `environment.schema-master` inventory section.

**Removed** — `Private/HealthChecks.ps1`. Twelve lines describing themselves as a placeholder
for a later phase, holding one function nothing called, whose only behaviour was to swallow the
error and return an empty list. That is the pattern P2 spent a phase removing everywhere else.

**Tests** — sixteen added. Fixture-driven open-relay cases covering Microsoft's default frontend
connector (must not be a finding), an explicitly granted relay permission, an externally secured
`ExchangeServers` connector, and an unreadable permission; that `ExchangeLegacyServers` is not
mistaken for `ExchangeServers`; anonymous principal matching by full name and by leaf; every
form of unrestricted range, and two forms that are not; build table integrity, no duplicate
builds, and that a missing table throws; preparation levels unique and named, with the
configured SE target present as a row; a regression guard that no functional-level list mentions
Windows Server 2025; that the operating system matrix keys on real product families and parses;
that Exchange 2016 on Windows Server 2016 is supported while the same operating system under SE
is not; and an AST check that every `Get-Queue` call names a `-Server`.

### Added — 2026-09-01 (phase P11)

Exchange Online collection for the tenant side of a hybrid organisation, off unless
`-IncludeExchangeOnline` is given. Coverage is now 32 controls.

- **`CLD.ORG-01`** tenant organisation configuration and accepted domains, including modern
  authentication and tenant-wide mailbox auditing.
- **`CLD.CONN-01`** inbound and outbound connectors and transport rules. An inbound connector
  that accepts mail from any address without requiring TLS or a matching certificate is the
  cloud equivalent of an open relay and is what this control mainly looks for.
- **`CLD.SEC-01`** anti-spam, anti-malware and anti-phishing policies, Safe Links and Safe
  Attachments, and DKIM signing. A tenant where every policy is still the built-in default is
  reported as untailored rather than as configured. Safe Links and Safe Attachments being absent
  is reported as "not licensed or not configured", because the Exchange Online session cannot
  tell those two apart.
- **`CLD.MIG-01`** migration endpoints, batches and move requests, including batches left failed
  or open past the configured age.

`Connect-ExchOnlineSession` supports interactive, app-only certificate and managed identity
authentication. A missing module or failed connection makes each cloud control report `Unknown`
with the reason; it never drops the control silently, and it never stops the on-premises
assessment.

**Prefix isolation.** Exchange Online and on-premises Exchange share cmdlet names, and this
module normally runs inside the Exchange Management Shell where those names are already bound to
the on-premises organisation. The tenant session is therefore always imported with a command
prefix (`Cloud` by default, configurable), and cloud collectors read tenant data only through
`Invoke-ExchCloudQuery`, which resolves the prefixed name and deliberately will not fall back to
the unprefixed one - answering a cloud question with on-premises data would be worse than
answering it with nothing. A test walks the syntax tree of every `CLD.*` collector and fails the
build on any direct Exchange cmdlet call.

### Fixed — 2026-09-01

- **The run transcript leaked sign-in identifiers.** `Start-Transcript` records the command line
  that launched the run, so an operator passing `-CloudAppId` and
  `-CloudCertificateThumbprint` had them written into `logs/transcript.txt`, which is hashed,
  zipped and handed to the client. `Protect-ExchRunTranscript` now redacts the app id,
  certificate thumbprint, user principal name and managed identity account id from the
  transcript before the hash manifest is written, so the manifest covers the redacted file. The
  tenant name is kept: the report needs to say which organisation was assessed. If the
  transcript cannot be rewritten the run warns loudly rather than shipping it quietly.

### Added — 2026-09-01 (phase P10, complete)

Ten collectors, taking coverage to 28 controls across the whole organisation.

- **`TR.QUE-01`** transport queue depth, age, retry and suspended state, with the poison queue
  called out separately. The finding says it is a single sample, because a queue that is
  draining and one that is stuck look identical from one reading.
- **`RBAC-01`** role groups, privileged membership, management role assignments and scopes.
  Organization Management membership is the headline number: it is administrative control of
  every mailbox in the estate.
- **`MB.INV-01`** mailbox, quota and archive inventory, and mailboxes forwarding outside the
  organisation. Capped by `Mailbox.MaxMailboxes` and skippable with `-SkipMailboxInventory`;
  when the cap bites the finding says so rather than reporting a sample as the whole estate.
- **`RET-01`** retention policies and tags, litigation hold, administrator audit configuration
  and mailbox audit bypass.
- **`CAS-01`** authentication policies and whether any of them actually blocks Basic
  authentication on every protocol, OWA and mobile device policies, per-mailbox legacy
  protocols, and stale device partnerships.
- **`AL-01`** address lists, global address list and offline address books, including an OAB
  with no generating mailbox, which leaves Outlook with a stale address book.
- **`PF-01`** public folder mailboxes, hierarchy and legacy public folder databases.
- **`TLS-01`** SCHANNEL protocol state per server and role, .NET strong cryptography and system
  default TLS versions, and Exchange serialised data signing. An absent SCHANNEL key is reported
  as the operating system default rather than guessed as on or off.
- **`PTCH-01`** security update currency (taken from `EX.CH-01` rather than re-derived),
  Emergency Mitigation Service state, and Windows patch cycle.
- **`DNS-01`** MX, SPF and DMARC for every authoritative accepted domain, including an SPF
  record ending in a permissive qualifier and a DMARC policy of none.

Two new switches: `-SkipMailboxInventory` and `-SkipDnsQueries`, alongside the existing
`-SkipDomainQueries`. `Test-Mailflow`, `Get-Message` and performance counters are deliberately
out of scope; PORT-PLAN records why.

### Changed — 2026-09-01 (failure logging)

A failure is now recorded in enough detail to diagnose without re-running, and it reaches the
report rather than only the log.

- `Get-ExchErrorDetail` flattens an ErrorRecord into the exception type, message, fully
  qualified error id, category, target object, script name and line number, the offending
  source line, the full script stack trace, and the whole inner-exception chain.
- `Write-ExchError` writes that to `logs/run.jsonl` **and** appends it to the run's error list.
  Every collector's catch block and every `Invoke-ExchQuery` failure now goes through it.
- Two new report sections and CSVs: `run.errors` (every failure with its detail) and
  `run.collectors` (every collector with its status, duration and output). The entry script
  returns `ErrorsLogged`.
- A collector that throws produces a finding carrying the error detail and naming the file and
  line it was thrown from.
- `Write-ExchLog` retries a locked log file and degrades to a warning rather than failing the
  run, and falls back to a serialisable form when something in the payload will not convert.

### Fixed — 2026-09-01

- **The run's error list never collected anything.** `Get-ExchRunErrorList` returned the list
  directly, and PowerShell unrolls a collection on return, so an empty list came back as
  `$null`. The caller took that to mean there was no list, skipped the `Add`, and left the list
  empty for the rest of the run - so every failure reached the log and none reached the report.
  Returning `, $list` prevents the unroll, and a test now guards it.
- `PF-01` assigned a literal `Compliant` when no public folders were deployed, the same class of
  hardcoded verdict already removed from `DAG-01`. Whether public folders are expected is now a
  threshold (`PublicFolder.RequirePublicFolders`), so a client that depends on them gets a
  failure instead of a pass.
- `PTCH-01` produced a doubled full stop when embedding the upstream `EX.CH-01` rationale.
- `TLS-01` passed its protocol list into the remote scriptblock with `-ArgumentList`; it now
  uses `$using:`, which is idiomatic and satisfies the analyzer's new-runspace scope rule.

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

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — 2026-09-11 (phases P14.5 and P14.6, `DEP.VOL-01` and `DEP-01`)

The last two greenfield deployment controls, which complete the `DEP.*` set: the database and log
volumes the plan names, and one readiness verdict rolled up from everything a greenfield deployment is
checked for.

- **`Collectors/DEP.VOL-01.VolumeReadiness.ps1`**, registered as `DEP.VOL-01`, area `Deployment`, no
  `Requires`, `Cloud = $false`, skip flag `SkipDeploymentChecks`, catalog domain `Environment` as for the
  other `DEP.*` controls, so the `ControlDomain` ValidateSet is unchanged. It reads
  `Deployment.TargetServers`, `Deployment.DatabaseVolume` and `Deployment.LogVolume` and nothing else.
  **With no target server, or neither volume, it reports one `Unknown` finding, severity Info, naming the
  missing keys through the shared P13 helper, and contacts nothing.** With one volume supplied it checks
  that one and names the other. On each target, over CIM only, for each supplied volume: a volume is
  mounted at exactly that path - a path that is only a folder on another volume is reported as absent,
  naming the volume it would fall on, and that volume is never judged in its place; free space against
  `DeploymentVolumes`; NTFS or ReFS; the allocation unit size. Once per target: whether the database and
  log volumes are the same volume - by the paths supplied, or by a shared `DeviceID`. A target that does
  not resolve or does not answer CIM has every check `Unknown`, naming the cause.
- **A shared volume and a non-64 KB allocation unit are reported, never failed** (`PartiallyCompliant`).
  Both are best practices on Learn, not requirements. A free-space minimum that has not been supplied is
  `Unknown` naming the key; the free space measured is still reported.
- **`Collectors/DEP-01.DeploymentReadiness.ps1`**, registered as `DEP-01`, area `Deployment`, skip flag
  `SkipDeploymentChecks`, domain `Environment`, with `Requires = @('ENV.VERS-01','DEP.TGT-01','DEP.NET-01',
  'DEP.WIT-01','DEP.NAME-01','DEP.VOL-01')`. The greenfield counterpart of `UPG-01`, in its shape: it
  measures nothing, keeps one row per prerequisite with the upstream rationale, and returns one verdict.
  `ENV.VERS-01` supplies the directory-side prerequisites and `DEP-01` does not re-derive them. **It does
  not require `EX.CH-01` or `ENV.OS-01`**: both read `Get-ExchangeServer`, so both need an existing
  Exchange organisation, which a greenfield deployment does not have. The file header says so.
- **`DEP-01` fails closed, where `UPG-01` does not.** Any prerequisite that could not be assessed makes
  the verdict `Unknown` before `Get-ExchWorstOutcome` is consulted; that function only ever combines
  measured outcomes, so a `Compliant` never outvotes an `Unknown`. A `Compliant` that the upstream itself
  marked `SoftFail` or `HardFail` is not counted as passed. A control that did not run (`DidNotRun`: "did
  not run: no result from it reached DEP-01 ...") and one that ran and reported `Unknown` ("ran and
  reported Unknown:" followed by its own rationale) carry different statuses, messages and metrics (`notRun`,
  `reportedUnknown`); a result with no finding under its own id is a third cause (`NoFinding`). The
  rationale always writes three groups - measured and passed, measured and did not pass, could not be
  assessed with the cause of each - an empty one as `(0): none`, and ends by saying that `Compliant` does
  not mean Exchange Setup will succeed. Beside a known failure an unassessed prerequisite still makes
  the verdict `Unknown`, and the severity stays High. With no deployment config the severity is Info and
  the rationale carries the P13 instructions.
- **`DeploymentVolumes`** in `Config/Thresholds.psd1`: four values, each with its Learn URL, read date and
  a note quoting the text. `FileSystems` NTFS and ReFS; `AllocationUnitBytes` 65536; and
  `DatabaseVolumeMinimumFreeGB` and `LogVolumeMinimumFreeGB` **`$null`**, because Learn gives no absolute
  figure. Override with `-ConfigPath`; nested tables merge, so an override may change `Value` alone.
- **Shared code.** `Get-ExchTargetState` gains `-CimOnly`, which skips the WinRM reading and records why
  in `WinRmError`. Without the switch nothing changes, and the `DEP.TGT-01` and `DEP.WIT-01` tests pass
  unchanged. `Get-ExchTargetMechanismGate` now gates `DEP.VOL-01` as well.

**Read on Microsoft Learn, 2026-09-11.** Exchange Server storage configuration options (applies to 2016,
2019 and Subscription Edition): File system "Supported: NTFS and ReFS."; NTFS and ReFS allocation unit
size "Supported: All allocation unit sizes. Best practice: 64 KB for both .edb and log file volumes.";
database per log isolation, stand-alone "Best practice: For recoverability, move database (.edb) file and
logs from the same database to different volumes backed by different physical disks.", high
availability "Supported: Isolation of logs and databases isn't required."; co-location "not recommended
in standalone architectures"; with JBOD "create a single volume with separate directories for
database(s) and for log files"; sizing "Provision for 120 percent of calculated maximum database size"
and "three days of log generation capacity". System requirements: ReFS "Supported on partitions that
contain" mailbox databases and transaction logs. **Learn is not silent on separation, but it states no
requirement either way**, and the deployment config does not say how many database copies are
planned, so the tool reports the fact and does not decide which column applies.

**Found, not fixed - P17.** `UPG-01`, the roll-up `DEP-01` was modelled on, does not fail closed at the
outcome level. Run on the dev VM with `EX.CH-01` absent from `-Upstream` and the other two `Compliant`, it
returned outcome `Compliant`, sufficiency `SoftFail`. `Get-ExchWorstOutcome` returns `Compliant` for
`Compliant, Unknown`, and `ENV.VERS-01` combines its own items the same way. Changing either would change
their findings, so it is a new planned row, P17, and not part of this phase.

**Changed.** `ModuleVersion` is **0.6.0**: the set of controls changed, which the PORT-PLAN rule treats as
a changed finding. With no deployment config every run now carries two more findings, `DEP.VOL-01` and
`DEP-01`, both `Unknown`, severity Info.

**Tests** — eighteen added (116 to 134), all against mocks and TestDrive. For `DEP.VOL-01`, ten: the
registry row; neither volume supplied, three ways, and no target server, each giving one `Unknown`/Info
finding that names the missing keys and carries the P13 strings, with nothing contacted; one volume
supplied; a volume that is not mounted, and a folder path, reported absent without judging the volume
underneath; free space below a supplied minimum failed, and the shipped `$null` minimum `Unknown` naming the
key; database and log on the same volume, by path and by `DeviceID`, reported with Learn's text and not
failed, and distinct volumes `Compliant`; a target that does not answer CIM and a name that does not
resolve, each `Unknown` on all 9 checks, with the other target unaffected and WinRM never called; all 9
declared checks per target, counted from the collector's text; file system and allocation unit
judgements; and a Learn URL and read date on every `DeploymentVolumes` value. For `DEP-01`, eight: the
registry row, with `EX.CH-01` and `ENV.OS-01` absent from its `Requires`, the file header saying why, and
no directory, CIM, WinRM, DNS or Exchange call in the file; `Requires` exactly the 6 declared controls,
equal to every `DEP.*` registry row plus `ENV.VERS-01` and to the keys the collector reads, all ordered
before it; all six `Compliant` giving `Compliant`; each of the six in turn reporting `Unknown` giving
`Unknown` naming it and its reason; each of the six in turn absent, told apart from the same control
reporting `Unknown`, plus a result with no finding; all three groups present when all passed, when none
ran and when mixed; a `SoftFail` `Compliant` not counted as passed; and Info severity with no deployment
config.

**Falsification.** With the suite green, five mutations, each restored from a copy and proven identical
by SHA256: letting a `Compliant` outvote an `Unknown` - `Get-ExchWorstOutcome` over every row, an
unassessed one as `Unknown` - failed 4 tests; dropping `DEP.VOL-01` from `DEP-01`'s `Requires` failed 1
("Expected 6, but got 5"); making a control that did not run read as passed failed 2; removing the
did-not-pass group from the rationale failed 1; making database and log on the same volume report as
distinct failed 1. The two new contexts re-ran 18 passed, 0 failed.

**Verified on the dev VM only.** Under PowerShell 7.6.6 and Windows PowerShell 5.1.26100 - where the
Pester suite cannot run - the new code was executed directly, with the same results under both.
`Get-ExchTargetState -CimOnly` against `localhost` recorded the dev VM's WS-Management refusal as `CimState`
Failed and `WinRmState` NotAttempted, "not attempted: the calling control reads CIM only". `Win32_Volume`
read locally returned `Name`, `DeviceID`, `FileSystem`, `FreeSpace` and `BlockSize` on all four fixed
volumes, and a volume with no drive letter reports its `\\?\Volume{...}\` path as `Name`. With only the CIM
transport helper redefined to read locally, `DEP.VOL-01` with database and log both on `C:` reported the
volume present and NTFS, the 4096-byte allocation unit `PartiallyCompliant`, free space measured and
`Unknown` against the shipped `$null`, and the shared volume `PartiallyCompliant`; a folder path read "no
volume at C:\ExchangeDatabases\; the path falls on C:\" and a missing letter "no volume at Q:\ among the 4
fixed volumes read". `DEP-01` over synthetic upstream results returned `Compliant`, then `Unknown` for one
upstream `Unknown`, then `Unknown` with status `DidNotRun` for an absent one. Free space printed as "49,9 GB
free": the figure follows the host's culture, as `DEP.TGT-01`'s already does. **Not verified against a real
target server or a real greenfield environment** - that is P14.12 and P14.13, owned by the operator.

Two more greenfield deployment controls: the prerequisites of the file share witness, and whether
the planned names are free. Neither can be discovered - the witness serves a DAG that does not
exist yet, and the names are a plan - so both read the P13 `Deployment` section and nothing else.

- **`Collectors/DEP.WIT-01.WitnessReadiness.ps1`**, registered as `DEP.WIT-01`, area `Deployment`,
  no `Requires`, `Cloud = $false`, skip flag `SkipDeploymentChecks` - the existing switch. Its catalog
  domain is `Environment`, as `DEP.TGT-01`'s and `DEP.NET-01`'s are, so the `ControlDomain`
  ValidateSet is unchanged. The server comes from `Deployment.WitnessServer` only. **With it empty -
  the shipped template's state - the control reports one `Unknown` finding, severity Info, naming the
  template and both P13 commands, and contacts nothing; it is not an error.** Otherwise thirteen
  checks: the name resolves; CIM and WinRM answer (which says the reads ran, not that anything is
  met); domain member; same forest as the assessment host; a server edition at version 6.0 or later;
  not a domain controller; not already an Exchange server; not one of `TargetServers`, by name or by
  resolved address; `FS-FileServer` installed; the File and Printer Sharing and WMI firewall
  exceptions on every network profile in use; the Exchange Trusted Subsystem grant; and, when the
  optional `Deployment.WitnessDirectory` is supplied, a local non-root full path.
- **The Trusted Subsystem grant has three states, never two.** The group is not in the directory yet
  - `Unknown`, with the cause that `/PrepareAD` creates it and the grant becomes checkable after it
  has run; the group exists and is not a direct member of the witness's local Administrators group -
  `NonCompliant`; it is a member - `Compliant`. Membership is compared by SID, read with the WinNT
  provider from the Administrators group found by its well-known SID. A directory that cannot be
  searched is `Unknown` with that cause, and is never reported as state (a).
- **A domain-controller witness is a finding** carrying Learn's consequence: the group then has to be
  added to `Builtin\Administrators`, which Learn calls "an unnecessary elevation of privileges" and
  "not a recommended configuration". **An Exchange-server witness is reported, not failed**
  (`PartiallyCompliant`): Learn recommends an Exchange server with Client Access services as witness.
- **`Collectors/DEP.NAME-01.NameAvailability.ps1`**, registered as `DEP.NAME-01` on the same terms.
  With none of the four keys supplied it reports one `Unknown` finding carrying the P13 strings and
  contacts nothing; with some supplied it checks those and names the rest. The DAG name: at most 15
  characters, a valid computer name, held by no computer object in the forest and no planned server,
  and by no object under `CN=Microsoft Exchange` in the configuration partition. Target and witness
  names: free when no computer object holds the name, or exactly one does whose `dNSHostName` is the
  supplied name - the server's own account; another holder or a duplicate is a finding. Internal
  names: must not exist in DNS; one that resolves, or exists holding other record types, is reported
  with its records and not judged a failure. **Every rationale says what the instruments cannot
  see** - the one global catalog and the assessment host's resolvers that were asked - so an absence
  is never read as proof that a name is free.
- **`WitnessPrerequisites` and `PlannedNames`** in `Config/Thresholds.psd1`: nine values, each with
  its Learn URL, read date and the text it came from. The two firewall rule-group ids
  (`@FirewallAPI.dll,-28502`, `@FirewallAPI.dll,-34251`) are not on Learn; they were measured on the
  dev VM's Windows 11 and say so in a `Measured` field.
- **Shared code.** `Private/Deployment.ps1` gains `Get-ExchDeploymentSupplyInstruction`,
  `Get-ExchDeploymentValue` and `Get-ExchDeploymentWitnessServer`; `DEP.TGT-01`'s "none supplied"
  rationale now ends with the shared instruction, and its text is unchanged byte for byte (SHA256
  `D502A221…5E95` before and after). `Get-ExchTargetState` takes `-CimQuery`, `-RemoteReader` and
  `-RemoteArgumentList`, and the per-mechanism gate moved out of `Invoke-ExchPrereqCheck` into
  `Get-ExchTargetMechanismGate`, so `DEP.WIT-01` reads a server and degrades exactly as `DEP.TGT-01`
  does. The `DEP.TGT-01` tests are unchanged and pass.

**Read on Microsoft Learn, 2026-09-11.** The witness requirements are manage-dags ("can't be a member
of the DAG", "must be in the same Active Directory forest", "Windows Server 2008 or later", the File
and Printer Sharing exception, and firewall exceptions "configured for WMI"), with Windows Server 2008
as 6.0 in the operating system version table. The group's spelling differs by page: create-dags,
manage-dags, New-DatabaseAvailabilityGroup and ad-changes (which lists it among the groups `/PrepareAD`
creates) say **Exchange Trusted Subsystem**; the Azure witness page says **Exchange Trusted
Subsystems**. The value used is the singular. The DAG name rule is manage-dags ("no longer than 15
characters that's unique within the Active Directory forest") and New-DatabaseAvailabilityGroup ("a
valid computer name"), with the character rules from the Active Directory naming conventions article.
The schema pages name the DAG class `Exch-MDB-Availability-Group` but not its LDAP name, so the
configuration search is by name, not class.

**Decided by the operator, 2026-09-11.** The phase asked for an existing computer object on a target
or witness name to be reported as in use. Every correctly joined target holds its own computer
account, so read literally that would fire on every prepared deployment. The rule above - the
server's own account is expected, anything else is reported - is the operator's choice.

**Changed.** `ModuleVersion` is **0.5.0**: the set of controls changed, which the PORT-PLAN rule
treats as a changed finding. With no deployment config every run now carries two more findings -
`DEP.WIT-01` and `DEP.NAME-01`, `Unknown`, severity Info - which say none was supplied.

**Tests** — twenty-six added (90 to 116), all against mocks and TestDrive. For each control: the
registry row is well formed, resolves, reuses the one switch and the `DEP.TGT-01` category, and with
nothing supplied there is exactly one `Unknown` finding carrying the template path and both commands
and nothing is contacted - for `DEP.WIT-01` asserted against the shipped template's empty
`WitnessServer`. For `DEP.WIT-01`: Trusted Subsystem states (a), (b) and (c) each asserted on its own
and then as three distinct outcomes, with an unreadable directory a fourth cause; a domain-controller
witness; a witness that resolves and does not answer told apart from one that does not resolve;
per-mechanism degradation both ways; all 13 checks, counted from the collector's text; a witness that
is a target by name and by address; an Exchange-server witness; firewall judgement per profile; the
witness directory rule; and a Learn URL and read date on every value. For `DEP.NAME-01`: a DAG name
held by a computer object; an internal name that already resolves; own account versus another holder
and a duplicate; all 7 declared checks - 1 per target, 1 for the witness, 4 for the DAG name, 1 per
internal name - against an expected row count; the scope sentence present when everything is free;
invalid DAG names; an Exchange configuration object and an unprepared directory; an unreadable
directory costing only the directory checks; and partly supplied keys.

**Falsification.** With the suite green, five mutations, each restored from a copy and proven
identical by SHA256: collapsing Trusted Subsystem state (a) into (b) failed 2 tests; reporting an
existing DAG name as free failed 1; passing a domain-controller witness failed 1; dropping
`FirewallWmi` from the witness population failed 3; dropping `ExistingExchangeObject` from the name
evaluation failed 4. Both contexts re-ran 26 passed, 0 failed.

**Verified on the dev VM only.** The witness reader scriptblock was run directly on the dev VM under
PowerShell 7.6.6 and Windows PowerShell 5.1.26100: it read three firewall profiles, the network
categories, 32 File and Printer Sharing rules and 8 WMI rules, and two local Administrators members
each with a SID, and reported `Get-WindowsFeature` - absent on Windows 11 - as an error on its own
item without losing the others. Under Windows PowerShell 5.1, where the Pester suite cannot run, the
new code was also executed directly: both collectors returned their one `Unknown`/Info finding with
nothing supplied, the witness directory rule accepted a folder and refused a drive root, the LDAP
escape and the extracted mechanism gate returned what the mocks assume. **Not verified against a
real witness, directory or DNS** - that is P14.9 and P14.10, owned by the operator.

### Added — 2026-09-11 (phase P14.2, `DEP.NET-01`)

The second greenfield deployment control: network reachability, probed from each target server
outward. A reachability result is a statement about one source reaching one destination. A probe
from the host running the assessment answers the wrong question - whether that host reaches a
domain controller, not whether the server that will become an Exchange server does - so
`DEP.NET-01` runs every probe on the target itself, over WinRM, and every result names its source.

- **`Collectors/DEP.NET-01.TargetPortMatrix.ps1`**, registered as `DEP.NET-01`, area `Deployment`,
  no `Requires`, `Cloud = $false`, skip flag `SkipDeploymentChecks` - the existing switch, not a
  second one. Its catalog domain is `Environment`, as `DEP.TGT-01`'s is, so the `ControlDomain`
  ValidateSet is unchanged. Targets come from `Deployment.TargetServers` and nowhere else.
  Destinations are discovered where they can be: domain controllers from the directory
  (`Get-ADForest`, then `Get-ADDomainController` for each domain) - never supplied, never guessed;
  the witness and the other targets from the P13 `Deployment` section; DNS servers from the
  target's own DNS client configuration, read on the target. Each target's name is resolved first,
  then one `Invoke-Command` runs the probe there. **There is no local fallback**: a target that does
  not resolve or does not answer WinRM gets `Unknown` for every flow, naming the mechanism and the
  error. Every result records the source, the destination and the address it resolved to on the
  target, port, protocol, probe, outcome and cause, and the probe origin as measured on the target -
  the host name the target reported and the local address the connection left from. A result whose
  reported host is not the target is `Unknown`.
- Each flow is `Open` (the handshake completed, or the server answered), `Closed` (the target was
  told the port refused or is unreachable) or `Unknown` with its cause. **A timeout is `Unknown` with
  cause `timeout`, never `Closed`.** A `Closed` flow is reported, not judged: it may be right for the
  environment, and before Exchange and failover clustering are installed nothing listens on a peer's
  replication or cluster port. It makes the control `PartiallyCompliant`, never `NonCompliant`.
  Results roll up per target and per destination, and `metrics.flows` and
  `csv/deployment.target-port-flows.csv` carry every one, so a network team can work from the list.
- **`Config/PortMatrix.psd1`** - twenty flows, each with an id, source and destination role, port,
  protocol, probe, purpose, and the Microsoft Learn URL and read date (2026-09-11). Eleven go to
  every domain controller: Kerberos 88 TCP and UDP, RPC endpoint mapper 135, LDAP 389 TCP and DC
  Locator 389 UDP, SMB 445, Kerberos password 464 TCP and UDP, LDAP SSL 636, and global catalog 3268
  and 3269 to global catalogs only. Exchange Learn names no port list for Exchange-to-DC traffic - it
  requires that traffic to be unrestricted on any port, including random RPC ports - so these are the
  Windows Learn rows for Active Directory and the Kerberos Key Distribution Center. Two go to the
  witness (SMB 445; WMI), five to each other target (DAG replication 64327, cluster 3343 TCP and UDP,
  RPC endpoint mapper 135, SMB 445), and DNS 53 UDP and TCP to the target's DNS servers. **One port
  is `$null`: `WitnessWmi`.** Learn says Exchange uses WMI to create the witness directory and share
  and names no port, so the probe makes a WMI connection and records the TCP connections to the
  witness it opened, and the flow stays `Unknown`. The dynamic RPC range cannot be proven by probing
  fixed ports; it is not a flow, and the table and the remediation both say so.
- **`-PortMatrixPath`** on `New-ExchRun` and `Invoke-ExchAssess.ps1`, and `Catalog/PortMatrix.ps1`,
  mirroring `-PrereqTablePath` and `Catalog/PrereqTable.ps1`: the same path resolution, loading and
  validation, and a missing, unparseable or empty matrix is an error.
- **`PortProbe` thresholds** - `TimeoutMilliseconds` (default 5000) and `MaxConcurrent` (default 32),
  both judgement calls. A top-level key, not under `Deployment`: that is the operator's P13 contract,
  and a default there would make an unfilled contract look partly supplied.

**Changed.** `ModuleVersion` is **0.4.0**: the set of controls changed, which the PORT-PLAN rule
treats as a changed finding. With no deployment config every run now carries one more finding -
`DEP.NET-01`, `Unknown`, severity Info - which says none was supplied.

**Tests** — ten added (80 to 90), all against mocks and TestDrive. The registry row is well formed,
resolves, reuses the one deployment switch and the `DEP.TGT-01` category; no target servers gives
exactly one `Unknown` finding carrying the template path and both P13 commands, and contacts nothing;
a target WinRM cannot reach has every flow `Unknown` naming WinRM and the error with no probe origin,
a name that does not resolve is never contacted, and the reachable target is unaffected; an AST scan
of the collector finds each of six declared network primitives and every one of them inside the probe
scriptblock, finds that scriptblock reached once and only as `Invoke-ExchTargetCommand -ScriptBlock`,
and finds no scriptblock invocation or network cmdlet outside it; an empty `WitnessServer` makes the
witness flows `Unknown` naming the key while every domain controller flow is still probed; a timeout
is `Unknown` with cause `timeout` and only a refusal is `Closed`; all 20 flows, counted from the
file's text, are handed to every target and every result names its source and measured origin; a
`$null` port is `Unknown` where the same flow with its port is `Open`; a directory that cannot be read
costs only the domain controller flows; and the matrix loads and refuses a missing path like the
prerequisite table.

**Verified on the dev VM only.** Beyond the suite, the probe scriptblock was run directly on the dev
VM, under PowerShell 7.6.6 and Windows PowerShell 5.1, against listeners it opened on 127.0.0.1: an
open port read `Connected`/`Open`, a closed TCP port and a closed UDP port read `Refused`/`Closed`, the
WMI measurement ran, and a name under `.invalid` read `NameNotResolved`. That run found two things,
both fixed before the gate: the WMI measurement listed every connection to the address rather than
only the ones the WMI attempt opened, and a refused loopback connection took 2091-2211 ms to report,
which is why the default timeout is 5000 ms rather than 3000. **Not verified against a real server or
a real network path** - that is P14.8, owned by the operator.

### Added — 2026-09-11 (phase P14.1, `DEP.TGT-01`)

The first greenfield deployment control: prerequisite readiness of the member servers that will
become Exchange servers. Every collector that inspects servers so far takes its list from
`Get-ExchangeServer`, so none of them can see a server that is not an Exchange server yet.
`DEP.TGT-01` reads the servers from `Deployment.TargetServers` - the P13 contract passed with
`-ConfigPath` - and from nowhere else.

- **`Collectors/DEP.TGT-01.TargetServerReadiness.ps1`**, registered as `DEP.TGT-01`, area
  `Deployment`, no `Requires`, `Cloud = $false`, skip flag `SkipDeploymentChecks`. Each name is
  resolved first; a name that does not resolve is reported by name and nothing is sent to it, so a
  typo reads as a typo and not as a server that is down. A resolving name is read over CIM
  (operating system and edition, volumes with free space and allocation unit, page file, installed
  memory, services, domain membership and forest, last boot) and over WinRM (the .NET Framework
  Release value, both uninstall roots, Windows features, `%ProgramFiles%`, the pending-restart
  indicators). The two degrade independently, class by class and item by item: a check whose
  mechanism failed is `Unknown` naming the mechanism and the error, and the per-server record says
  which mechanisms answered. Installed software comes from the uninstall keys, never `Win32_Product`.
  A target that is a domain controller, already runs Exchange services, is not a domain member or
  is in another forest is a finding, not a failure. The control is `Compliant` only when every
  check on every server is.
- **`Config/PrereqTable.psd1`** - seventeen Exchange Server SE prerequisites, each with the Microsoft
  Learn URL it was read from and the date (2026-09-11). Five keys Learn does not state are `$null`
  and report `Unknown` - the uninstall names of the Visual C++ 2013 package and the IIS URL Rewrite
  Module, and the minimum Visual C++ 2012, Visual C++ 2013 and UCMA versions - and inside the .NET
  key the Windows Server 2019 row is `$null`, because the supportability matrix's .NET table has no
  Exchange Server SE row for it. **With the shipped table `DEP.TGT-01` cannot report `Compliant`.** That is the honest answer
  until an operator supplies verified values.
- **`-PrereqTablePath`** on `New-ExchRun` and `Invoke-ExchAssess.ps1`, and `Catalog/PrereqTable.ps1`,
  mirroring `-BuildTablePath` and `Catalog/BuildTable.ps1`: the same path resolution, the same
  loading, the same validation, and a missing or unparseable table is an error.
- **`-SkipDeploymentChecks`** on `Invoke-ExchCollection` and `Invoke-ExchAssess.ps1`.
- `Private/Deployment.ps1` gains `Get-ExchDeploymentConfigInstruction`, and the preflight warning now
  takes its template path and commands from it, so `DEP.TGT-01`'s "none supplied" rationale and the
  warning cannot drift apart. The warning text is unchanged byte for byte (SHA256 compared before and
  after).

**Changed.** `ModuleVersion` is **0.3.0**: the set of controls changed, which the PORT-PLAN rule
treats as a changed finding. With no deployment config every run now carries one more finding -
`DEP.TGT-01`, `Unknown`, severity Info - which says none was supplied.

**Tests** — twelve added (68 to 80). The registry row is well formed and its function resolves; no
target servers gives exactly one `Unknown` finding carrying the template path and both P13
commands, and contacts nothing; with only CIM answering, the 5 CIM-only checks are judged and the 12
that need WinRM are `Unknown` naming it, and the reverse for 8 and 9; a throwing mock becomes a
named `Unknown`, never a missing finding or a pass; a name that does not resolve is told apart from
one that resolves and does not answer, and is never contacted; all 17 keys, counted from the file's
text, map one to one onto checks; every value carries a Learn URL and read date; an AST scan finds
no `Win32_Product` and does find the seven CIM classes and both uninstall roots; a value nulled
through a `-PrereqTablePath` copy turns a passing check `Unknown`; a domain controller, an Exchange
server and a foreign forest are findings; and the table loads and refuses a missing path like the
build table.

**Not verified against a real server.** Every test runs against mocks. P14.7 is the first real
run, owned by the operator.

### Added — 2026-09-11 (phase P13)

The deployment config contract, and a warning that makes it hard to miss. The assessment
discovers domain controllers, domains and the forest, and finds existing Exchange servers with
`Get-ExchangeServer`. It cannot discover a server that is not an Exchange server yet, so a
greenfield Exchange Server SE deployment's target servers, file share witness and planned names
have to come from the operator. This phase defines where they go. It adds no collector: nothing
reads the section yet except preflight, and the collectors that will are PORT-PLAN P14.

- **`Config/Deployment.template.psd1`** — shipped empty. One `Deployment` key carrying
  `TargetServers`, `WitnessServer`, `DagName`, `InternalNames`, `DatabaseVolume` and
  `LogVolume`, each with a comment saying what it is, what supplying it enables and what leaving
  it empty costs. It is merged over `Config/Thresholds.psd1` through the existing `-ConfigPath`,
  and is copied out rather than edited in place.
- **`New-ExchDeploymentConfig`** — writes a byte-for-byte copy of the template to `-Path` and
  returns the resolved full path. The template is found from the module base at run time, so the
  command works from any install location. An existing file is refused, naming the file and
  `-Force`, unless `-Force` is given; `-WhatIf` is supported. Full comment-based help.
- **`Get-ExchPreflightReport -Run`** — a new optional parameter. With no usable deployment config
  it adds a warning saying that greenfield deployment controls will report `Unknown` because no
  target servers, witness or planned names were supplied, carrying the template's resolved path,
  `New-ExchDeploymentConfig -Path .\Deployment.psd1` and `-ConfigPath .\Deployment.psd1`. A partly
  filled config gets a warning naming exactly the keys that are missing or empty. The return
  shape is unchanged — one `warnings` property holding an array of strings — and a call with no
  arguments still works: it reads the shipped defaults, which carry no deployment section, so it
  warns.
- **`Invoke-ExchAssess.ps1`** — passes the run to preflight and prints the deployment config
  warning as a block between two rules of `=`. Every preflight warning is still written with
  `Write-ExchEvent`. The script already had `-ConfigPath` and passed it to `New-ExchRun`, so no
  parameter was added. The header is now comment-based help with a worked example.
- README section *Planning a new deployment*. `.gitignore` gains `Deployment.psd1`, the name the
  examples and the warning suggest; the template's own name does not match it.

**A missing deployment config is a warning, never an error.** An assessment of an existing
organisation needs none of it, and the run carries on either way.

**Not changed.** No finding, outcome, severity or rationale, so `ModuleVersion` stays 0.2.0 under
the PORT-PLAN rule. `CollectorRegistry.ps1` and `New-ExchRun`'s parameters are untouched.

**Tests** — seventeen added (51 to 68). The template parses, carries exactly the six contract
keys — counted a second time from the file's text so one key cannot pass for six — and ships
empty; the module's key list matches it; the template path resolves from the module base and
exists. `New-ExchDeploymentConfig` writes a parseable copy identical to the template, resolves a
relative path, refuses an overwrite without `-Force` and leaves the file alone, overwrites with
it, and writes nothing under `-WhatIf`. Preflight warns with the template path and both commands
when nothing is supplied, including when called with no arguments and when handed the unfilled
template; names exactly the missing keys of a partial config and no others; accepts a filled copy
merged through the real `-ConfigPath` path; and keeps its return shape when the config is
complete. Every new export has SYNOPSIS, DESCRIPTION, every PARAMETER and at least two EXAMPLE
blocks, and the entry script's help carries the worked example.

### Changed — 2026-09-02 (P12 verification pass)

`ModuleVersion` is **0.2.0**. P12 changed what several controls report, and two runs that say
different things about the same organisation must not claim to be the same version of the tool.
PORT-PLAN now carries that as a standing rule.

**Fixed — an unreadable property could still produce a verdict.** P12 replaced direct property
reads with the guarded `Get-ExchObjectValue`, which returns a caller-supplied default when the
property is absent. That stopped `Set-StrictMode` from taking a collector down, but it left the
default deciding the answer: a Receive connector that did not return `PermissionGroups` scored
`AllowsAnonymous = $false` and so could not be an open relay, a queue that did not return
`MessageCount` counted as zero messages, and a server that did not return `LastBootUpTime` passed
the uptime check. Each is a pass nothing measured.

`Test-ExchObjectProperty` and `Get-ExchMissingProperty` now separate "the property is not there"
from "the property is there and null" — a distinction that matters, because a Send connector
whose `TlsAuthLevel` is null is a finding while one that never returned the field is not. Every
control presence-checks the properties its verdict reads, and reports an object missing any of
them as not assessable, naming the property:

- **`TR.CO-01`** judges on `Enabled`, `PermissionGroups`, `AuthMechanism`, `RemoteIPRanges` and
  `RequireTLS` for a Receive connector, and `Enabled`, `AddressSpaces` and `TlsAuthLevel` for a
  Send connector. Connectors missing any are excluded from the relay and Basic-authentication
  verdicts and reported `Unknown`/SoftFail instead. `RelayAssessable` now covers this as well as
  an unreadable permission, and an access control entry that does not carry `Deny`, `IsInherited`
  or `User` makes the whole connector's answer `Unknown` — an absent `Deny` read as "allow" would
  invent a grant, and an absent `User` read as "not anonymous" would hide one. New
  `UnreadableProperties` column on both connector sections.
- **`TR.QUE-01`** judges on `Identity`, `Status`, `MessageCount` and `LastRetryTime`. Queues
  missing any are excluded from the depth, retry, suspended, poison and age checks and from the
  message total, and reported `Unknown`/SoftFail.
- **`ENV.OS-01`** separates a server that did not return `AdminDisplayVersion` from one whose
  Exchange version has no operating system row — both `Unknown`, but they are different problems
  with different remediation — and no longer passes the uptime check on a server that did not
  return `LastBootUpTime`. New `VersionRead`, `UptimeAssessable` and `UnreadableProperties`
  columns.

**Fixed — `Resolve-ExchBuild -Table` is mandatory.** It was optional, falling back to
`Get-ExchBuildTable` with no run context, so a run started with `-BuildTablePath` could have been
judged against the table shipped in the repository instead of the operator's. The `-Run`
parameter is gone with it; the caller loads the table once from the run and hands it over. A test
asserts the parameter stays mandatory.

**Dropped** — PORT-PLAN phases P6 (ignore list, alerting, scheduled runs) and P8 (packaging and
first tagged release), each with its reason recorded in that file rather than left `Planned`
indefinitely.

**Tests** — three added: a Receive connector missing a judged property is not assessable and
yields `Unknown`/SoftFail naming it; a null property value is data while an absent one is not;
and `Resolve-ExchBuild` requires `-Table`.

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

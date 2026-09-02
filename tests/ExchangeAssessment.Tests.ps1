#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:SourceRoot = Join-Path -Path $script:RepoRoot -ChildPath 'src'
    $script:ModuleName = 'ExchangeAssessment'
    $script:ToolRoot = Join-Path -Path $script:SourceRoot -ChildPath $script:ModuleName
    $script:ManifestPath = Join-Path -Path $script:ToolRoot -ChildPath "$script:ModuleName.psd1"
    $script:SettingsPath = Join-Path -Path $script:RepoRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
    $script:EntryScript = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/Invoke-ExchAssess.ps1'
    $script:CollectorRoot = Join-Path -Path $script:ToolRoot -ChildPath 'Collectors'
}

AfterAll {
    Remove-Module -Name $script:ModuleName -Force -ErrorAction SilentlyContinue
}

Describe 'ExchangeAssessment' {

    Context 'Module import' {

        It 'has a manifest that passes Test-ModuleManifest' {
            $script:ManifestPath | Should -Exist
            { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
        }

        It 'imports from the manifest path without error' {
            { Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop } | Should -Not -Throw
            Get-Module -Name $script:ModuleName | Should -Not -BeNullOrEmpty
        }

        It 'keeps the 5.1 floor for the Exchange Management Shell' {
            $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
            $manifest.PowerShellVersion | Should -Be '5.1'
            $manifest.CompatiblePSEditions | Should -Contain 'Desktop'
        }

        It 'carries a real module GUID' {
            (Import-PowerShellDataFile -Path $script:ManifestPath).GUID | Should -Not -Match '^0{8}-'
        }
    }

    Context 'Public surface' {

        BeforeAll {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop
            $script:Exported = (Import-PowerShellDataFile -Path $script:ManifestPath).FunctionsToExport
        }

        It 'exports every function named in FunctionsToExport' {
            $missing = $script:Exported | Where-Object {
                -not (Get-Command -Name $_ -Module $script:ModuleName -ErrorAction SilentlyContinue)
            }
            $missing | Should -BeNullOrEmpty -Because "the manifest promises these functions: $($missing -join ', ')"
        }

        It 'exposes Invoke-ExchCollection as the primary collection entry point' {
            $command = Get-Command -Name 'Invoke-ExchCollection' -Module $script:ModuleName -ErrorAction SilentlyContinue
            $command | Should -Not -BeNullOrEmpty
            $command.Parameters.Keys | Should -Contain 'Run'
        }

        It 'defines no function name twice across the module' {
            $defined = Get-ChildItem -Path $script:ToolRoot -Recurse -Filter '*.ps1' |
                ForEach-Object { [regex]::Matches((Get-Content -Path $_.FullName -Raw), '(?m)^\s*function\s+(?<name>[\w\-]+)') } |
                ForEach-Object { $_.Groups['name'].Value }

            $duplicates = $defined | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name
            $duplicates | Should -BeNullOrEmpty -Because "defined more than once: $($duplicates -join ', ')"
        }
    }

    Context 'Control catalog' {

        BeforeAll { Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop }

        It 'gives every control a domain New-ExchFinding will accept' {
            # The catalog and the ValidateSet drifted apart once before, which silently killed a
            # collector for the life of the release. This is the test that stops it recurring.
            $allowed = (Get-Command New-ExchFinding).Parameters['ControlDomain'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                ForEach-Object { $_.ValidValues }

            $bad = & (Get-Module $script:ModuleName) { Get-ExchControlCatalog } |
                Where-Object { $_.domain -notin $allowed }

            $bad | Should -BeNullOrEmpty -Because "these control domains are not in the ValidateSet: $(($bad | ForEach-Object { "$($_.controlId)=$($_.domain)" }) -join ', ')"
        }

        It 'gives every control at least one Microsoft reference' {
            $missing = & (Get-Module $script:ModuleName) { Get-ExchControlCatalog } |
                Where-Object { -not $_.references -or @($_.references).Count -eq 0 }

            $missing | Should -BeNullOrEmpty -Because "these controls have no reference: $(($missing | ForEach-Object { $_.controlId }) -join ', ')"
        }
    }

    Context 'Collector registry' {

        BeforeAll { Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop }

        It 'ships collector files' {
            (Get-ChildItem -Path $script:CollectorRoot -Filter '*.ps1').Count | Should -BeGreaterThan 10
        }

        It 'defines the function named by every registry entry' {
            $registry = & (Get-Module $script:ModuleName) { Get-ExchCollectorRegistry }
            $registry.Count | Should -BeGreaterThan 0

            $defined = Get-ChildItem -Path $script:CollectorRoot -Filter '*.ps1' |
                ForEach-Object { [regex]::Matches((Get-Content -Path $_.FullName -Raw), '(?m)^\s*function\s+(?<name>[\w\-]+)') } |
                ForEach-Object { $_.Groups['name'].Value }

            $missing = $registry | Where-Object { $_.Function -notin $defined } | ForEach-Object { $_.Function }
            $missing | Should -BeNullOrEmpty -Because "the registry names these collectors: $($missing -join ', ')"
        }

        It 'resolves every control id the registry references' {
            $registry = & (Get-Module $script:ModuleName) { Get-ExchCollectorRegistry }
            foreach ($entry in $registry) {
                { & (Get-Module $script:ModuleName) { param($id) Get-ExchControlById -ControlId $id } $entry.Id } |
                    Should -Not -Throw -Because "the catalog should contain $($entry.Id)"
            }
        }

        It 'orders collectors so dependencies run first and the graph is acyclic' {
            $ordered = & (Get-Module $script:ModuleName) { Get-ExchCollectorOrder }
            $seen = New-Object System.Collections.Generic.List[string]
            foreach ($entry in $ordered) {
                foreach ($requirement in @($entry.Requires)) {
                    $seen | Should -Contain $requirement -Because "$($entry.Id) requires $requirement, which must run first"
                }
                $seen.Add($entry.Id) | Out-Null
            }
            $ordered.Count | Should -Be (& (Get-Module $script:ModuleName) { Get-ExchCollectorRegistry }).Count
        }
    }

    Context 'Read-only guarantee' {

        # The assessment must never change Exchange or Active Directory. Collectors are the only
        # code that touches them, so that is where this is enforced. Everything outside this list
        # of verbs writes something somewhere; Test-Mailflow is named explicitly because it looks
        # like a read but sends live probe messages.
        It 'invokes no Exchange cmdlet that changes state' {
            $forbiddenVerbs = @('Set', 'Remove', 'Enable', 'Disable', 'Add', 'Update', 'Start', 'Stop',
                'Restart', 'Move', 'Mount', 'Dismount', 'Suspend', 'Resume', 'Install', 'Uninstall',
                'Clear', 'Reset', 'Send')
            # Set-StrictMode changes the parser's behaviour for the current scope, not the
            # environment being assessed.
            $allowed = @('Set-StrictMode')

            # Walk the AST rather than the text: a cmdlet named in a comment or a message string
            # is not a call, and this test should only ever fail on a real invocation.
            $violations = foreach ($file in Get-ChildItem -Path $script:CollectorRoot -Filter '*.ps1') {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
                $commands = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)

                foreach ($command in $commands) {
                    $name = $command.GetCommandName()
                    if (-not $name -or $name -in $allowed) { continue }
                    if ($name -eq 'Test-Mailflow') { "$($file.Name): Test-Mailflow sends live probe messages"; continue }
                    $verb = ($name -split '-')[0]
                    if ($verb -in $forbiddenVerbs) { "$($file.Name): $name" }
                }
            }

            $violations | Should -BeNullOrEmpty -Because "collectors must be read-only, but these were found: $($violations -join '; ')"
        }
    }

    Context 'Exchange Online isolation' {

        BeforeAll { Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop }

        # Exchange Online and on-premises Exchange share cmdlet names. This module usually runs
        # inside the Exchange Management Shell, where those names are bound to the on-premises
        # organisation, so a cloud collector calling Get-AcceptedDomain directly would report
        # on-premises data as tenant data. Cloud collectors must go through Invoke-ExchCloudQuery,
        # which resolves the prefixed name.
        It 'reaches tenant data only through the prefixed cloud query helper' {
            $builtIns = @(
                'ForEach-Object', 'Where-Object', 'Select-Object', 'Sort-Object', 'Group-Object',
                'Measure-Object', 'New-Object', 'Out-Null', 'Set-StrictMode', 'Get-Date',
                'Join-Path', 'Split-Path', 'Write-Verbose', 'Write-Warning', 'Get-Command'
            )

            $violations = foreach ($file in Get-ChildItem -Path $script:CollectorRoot -Filter 'CLD.*.ps1') {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
                foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                    $name = $command.GetCommandName()
                    if (-not $name) { continue }
                    if ($name -in $builtIns) { continue }
                    if ($name -match '-Exch') { continue }
                    "$($file.Name): $name"
                }
            }

            $violations | Should -BeNullOrEmpty -Because "cloud collectors must not call Exchange cmdlets directly, but found: $($violations -join '; ')"
        }

        It 'never falls back to the unprefixed cmdlet name' {
            $run = [pscustomobject]@{
                Config = @{}; Flags = @{}
                Cloud  = [pscustomobject]@{ Connected = $true; Prefix = 'ZzUnlikelyPrefix' }
            }
            # Get-Date certainly exists; Get-ZzUnlikelyPrefixDate certainly does not. Resolution
            # must return nothing rather than quietly handing back the unprefixed command.
            $resolved = & (Get-Module $script:ModuleName) { param($r) Get-ExchCloudCommand -Run $r -Name 'Get-Date' } $run
            $resolved | Should -BeNullOrEmpty
        }

        It 'starts every run with a disconnected cloud state' {
            $state = & (Get-Module $script:ModuleName) { New-ExchCloudState }
            $state.Connected | Should -BeFalse
            $state.AuthMode | Should -Be 'None'
            $state.Reason | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Credential hygiene' {

        BeforeAll { Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop }

        It 'redacts sign-in identifiers from the transcript but keeps the tenant name' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("exchassess-redact-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            try {
                $transcript = Join-Path $root 'transcript.txt'
                Set-Content -Path $transcript -Encoding UTF8 -Value @(
                    "Command: Invoke-ExchAssess.ps1 -CloudAppId 'AAAA-BBBB' -CloudCertificateThumbprint 'DEADBEEF' -CloudOrganization 'contoso.onmicrosoft.com'"
                )

                $run = [pscustomobject]@{
                    RunFolder = $root
                    TranscriptPath = $transcript
                    LogPath = (Join-Path $root 'run.jsonl')
                    CloudAuth = @{
                        AppId = 'AAAA-BBBB'
                        CertificateThumbprint = 'DEADBEEF'
                        Organization = 'contoso.onmicrosoft.com'
                        UserPrincipalName = ''
                        ManagedIdentityAccountId = ''
                    }
                }

                $count = & (Get-Module $script:ModuleName) { param($r) Protect-ExchRunTranscript -Run $r } $run
                $count | Should -BeGreaterThan 0

                $content = Get-Content -Path $transcript -Raw
                $content | Should -Not -Match 'DEADBEEF'
                $content | Should -Not -Match 'AAAA-BBBB'
                $content | Should -Match '\[redacted\]'
                # The organisation is evidence, not a secret, and the report needs it.
                $content | Should -Match 'contoso\.onmicrosoft\.com'
            }
            finally {
                Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Findings are earned, not assumed' {

        It 'requires every finding to state an outcome and a rationale' {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop
            $parameters = (Get-Command New-ExchFinding).Parameters
            foreach ($name in @('Outcome', 'Rationale')) {
                $attribute = $parameters[$name].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                    Select-Object -First 1
                $attribute.Mandatory | Should -BeTrue -Because "$name must be mandatory so no collector can report a result it did not measure"
            }
        }

        It 'hardcodes no Compliant outcome in any collector' {
            # Two collectors used to return a literal Compliant regardless of what they found.
            $violations = foreach ($file in Get-ChildItem -Path $script:CollectorRoot -Filter '*.ps1') {
                $text = Get-Content -Path $file.FullName -Raw
                if ($text -match "-Outcome\s+'Compliant'") { $file.Name }
            }
            $violations | Should -BeNullOrEmpty -Because "these collectors assign Compliant as a literal: $($violations -join ', ')"
        }
    }

    Context 'Failure logging' {

        BeforeAll { Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop }

        It 'captures the exception type, position and inner chain from an ErrorRecord' {
            $record = $null
            try { throw (New-Object System.InvalidOperationException('outer', (New-Object System.IO.FileNotFoundException('inner')))) }
            catch { $record = $_ }

            $detail = & (Get-Module $script:ModuleName) { param($r) Get-ExchErrorDetail -ErrorRecord $r } $record

            $detail.message | Should -Be 'outer'
            $detail.exceptionType | Should -Be 'System.InvalidOperationException'
            $detail.scriptStackTrace | Should -Not -BeNullOrEmpty
            $detail.lineNumber | Should -BeGreaterThan 0
            @($detail.innerExceptions).Count | Should -Be 1
            $detail.innerExceptions[0].message | Should -Be 'inner'
        }

        It 'records a failure on the run so it reaches the report, not just the log' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("exchassess-log-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            try {
                $run = [pscustomobject]@{
                    RunId = 'test'; TenantHint = 'test'; RunFolder = $root
                    LogPath = (Join-Path $root 'run.jsonl'); ConfigPath = ''
                    Config = @{}; Flags = @{}
                    Errors = (New-Object System.Collections.Generic.List[object])
                }

                $record = $null
                try { throw 'collector blew up' } catch { $record = $_ }

                $null = & (Get-Module $script:ModuleName) {
                    param($r, $e) Write-ExchError -Run $r -Context 'Get-Something' -ErrorRecord $e -ControlId 'ENV.OS-01'
                } $run $record

                # An empty List returned from a function unrolls to $null, which once silently
                # swallowed the first error of every run. Guard the behaviour, not just the count.
                $run.Errors.Count | Should -Be 1
                $run.Errors[0].controlId | Should -Be 'ENV.OS-01'
                $run.Errors[0].context | Should -Be 'Get-Something'
                $run.Errors[0].detail.message | Should -Be 'collector blew up'

                (Join-Path $root 'run.jsonl') | Should -Exist
                (Get-Content -Path (Join-Path $root 'run.jsonl') -Raw) | Should -Match 'Get-Something failed'
            }
            finally {
                Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'returns the run error list even when it is still empty' {
            $run = [pscustomobject]@{ Errors = (New-Object System.Collections.Generic.List[object]) }
            $list = & (Get-Module $script:ModuleName) { param($r) Get-ExchRunErrorList -Run $r } $run

            # Deliberately not `$list | Should -Not -BeNullOrEmpty`: piping an empty collection
            # into Should enumerates it to nothing, and -BeNullOrEmpty counts an empty collection
            # as empty, so that assertion cannot tell "returned an empty list" from "returned
            # null" - which is precisely the distinction this test exists to make.
            ($null -eq $list) | Should -BeFalse -Because 'an empty list must not unroll to $null'
            $list.GetType().Name | Should -Be 'List`1'
        }
    }

    Context 'Report writers' {

        BeforeAll {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

            $script:ReportRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("exchassess-test-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $script:ReportRoot -Force | Out-Null

            # A synthetic run. Nothing here came from a real organisation.
            $script:TestRun = [pscustomobject]@{
                RunId      = 'test-run'
                TenantHint = 'test'
                RunFolder  = $script:ReportRoot
                LogPath    = (Join-Path $script:ReportRoot 'run.jsonl')
                ConfigPath = ''
                Config     = @{ MaxRowsPerSection = 2; MaxAssessmentJsonBytes = 8388608 }
                Flags      = @{ FullInventory = $false; IncludeExchangeOnline = $false }
            }

            $script:TestSection = & (Get-Module $script:ModuleName) {
                param($run)
                New-ExchInventorySection -Run $run -Key 'test.servers' -Title 'Test Servers' -Area 'Environment' `
                    -Columns @('Name', 'Roles') `
                    -Rows @(
                        [pscustomobject]@{ Name = 'EX01'; Roles = @('Mailbox', 'ClientAccess') }
                        [pscustomobject]@{ Name = 'EX02'; Roles = @('Mailbox') }
                        [pscustomobject]@{ Name = 'EX03'; Roles = @() }
                    ) -HighCardinality
            } $script:TestRun

            $script:TestFinding = New-ExchFinding -ControlDomain 'Environment' -ControlId 'ENV.OS-01' `
                -Severity 'High' -Title 'Test' -Description 'Test control' `
                -Outcome 'NonCompliant' -Rationale 'Synthetic finding for the writer tests.' `
                -References @(@{ title = 'Docs'; url = 'https://learn.microsoft.com/exchange' })
        }

        AfterAll {
            if ($script:ReportRoot -and (Test-Path $script:ReportRoot)) {
                Remove-Item -Path $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'flattens multi-valued properties into one CSV cell' {
            $script:TestSection.allRows[0].Roles | Should -Be 'Mailbox;ClientAccess'
            $script:TestSection.allRows[2].Roles | Should -Be ''
        }

        It 'summarises a high-cardinality section for JSON but keeps every row for CSV' {
            $script:TestSection.totalRows | Should -Be 3
            $script:TestSection.truncated | Should -BeTrue
            @($script:TestSection.rows).Count | Should -Be 2
            @($script:TestSection.allRows).Count | Should -Be 3
        }

        It 'writes one CSV per section plus findings, holding every row' {
            $paths = Export-ExchCsvReport -Run $script:TestRun -Sections @($script:TestSection) -Findings @($script:TestFinding)
            @($paths).Count | Should -Be 2

            $sectionCsv = Join-Path $script:ReportRoot 'csv/test.servers.csv'
            $sectionCsv | Should -Exist
            @(Import-Csv -Path $sectionCsv).Count | Should -Be 3

            $findingsCsv = Join-Path $script:ReportRoot 'csv/findings.csv'
            $findingsCsv | Should -Exist
            (Import-Csv -Path $findingsCsv)[0].controlId | Should -Be 'ENV.OS-01'
        }

        It 'writes an assessment.json carrying inventory, findings and controls' {
            $path = New-ExchAssessmentJson -Run $script:TestRun -Sections @($script:TestSection) -Findings @($script:TestFinding)
            $path | Should -Exist

            $document = Get-Content -Path $path -Raw | ConvertFrom-Json
            $document.schemaVersion | Should -Not -BeNullOrEmpty
            $document.inventory.'test.servers'.totalRows | Should -Be 3
            $document.inventory.'test.servers'.truncated | Should -BeTrue
            $document.findings[0].controlId | Should -Be 'ENV.OS-01'
            $document.findings[0].references[0].url | Should -Match 'learn\.microsoft\.com'
            @($document.controls).Count | Should -BeGreaterThan 0
        }
    }

    Context 'Entry script' {

        It 'exists and parses without error' {
            $script:EntryScript | Should -Exist

            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($script:EntryScript, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty
        }

        It 'returns a summary object rather than writing to the host' {
            $text = Get-Content -Path $script:EntryScript -Raw
            $text | Should -Not -Match 'Write-Host'
            $text | Should -Match 'FindingsCount'
            $text | Should -Match 'AssessmentJson'
        }

        It 'generates the reports before closing the run so the hash manifest covers them' {
            $text = Get-Content -Path $script:EntryScript -Raw
            $csvAt   = $text.IndexOf('Export-ExchCsvReport')
            $jsonAt  = $text.IndexOf('New-ExchAssessmentJson')
            $closeAt = $text.IndexOf('Close-ExchRun -Run $run')

            $csvAt  | Should -BeGreaterThan 0
            $jsonAt | Should -BeGreaterThan 0
            $closeAt | Should -BeGreaterThan $csvAt
            $closeAt | Should -BeGreaterThan $jsonAt
        }
    }

    Context 'Open relay is a permission, not a shape' {

        BeforeAll {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

            # Microsoft's `Default Frontend <ServerName>` connector, as setup creates it on every
            # Mailbox server. Nothing here came from a real organisation - it is the documented
            # default, reproduced so the control can be tested against it.
            function New-TestConnector {
                param(
                    [string]$Name = 'Default Frontend EX01',
                    [string]$Server = 'EX01',
                    [bool]$Enabled = $true,
                    [string]$PermissionGroups = 'AnonymousUsers, ExchangeServers, ExchangeLegacyServers',
                    [string]$AuthMechanism = 'Tls, Integrated, BasicAuth, BasicAuthRequireTLS',
                    [string[]]$RemoteIPRanges = @('::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff', '0.0.0.0-255.255.255.255')
                )
                [pscustomobject]@{
                    Identity          = "$Server\$Name"
                    Name              = $Name
                    Server            = $Server
                    Enabled           = $Enabled
                    Bindings          = @('0.0.0.0:25')
                    RemoteIPRanges    = $RemoteIPRanges
                    PermissionGroups  = $PermissionGroups
                    AuthMechanism     = $AuthMechanism
                    Fqdn              = 'mail.contoso.com'
                    RequireTLS        = $false
                    MaxMessageSize    = '36 MB'
                    RequireEHLODomain = $false
                }
            }

            function Get-TestRelayRow {
                param($Connector, [string]$Right)
                & (Get-Module $script:ModuleName) {
                    param($c, $r)
                    New-ExchReceiveConnectorRow -Connector $c -AnonymousGroups @('AnonymousUsers') `
                        -KnownUnrestricted @('0.0.0.0-255.255.255.255', '::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff') `
                        -AnonymousRelayRight $r
                } $Connector $Right
            }

            function Get-TestRelayAssessment {
                param($Row)
                & (Get-Module $script:ModuleName) { param($r) Get-ExchRelayAssessment -Rows @($r) } $Row
            }

            function Test-TestUnrestricted {
                param([string]$Range)
                & (Get-Module $script:ModuleName) { param($r) Test-ExchUnrestrictedRange -Ranges @($r) } $Range
            }
        }

        It 'does not call the default frontend connector an open relay' {
            # AnonymousUsers plus the whole address space is the shipped default. The old logic
            # returned NonCompliant/High here, on every Exchange organisation there is.
            $row = Get-TestRelayRow -Connector (New-TestConnector) -Right 'NotGranted'

            $row.AllowsAnonymous | Should -BeTrue
            $row.UnrestrictedRange | Should -BeTrue
            $row.AnonymousRelayRight | Should -Be 'NotGranted'
            $row.OpenRelay | Should -BeFalse

            $assessment = Get-TestRelayAssessment -Row $row
            @($assessment.OpenRelays).Count | Should -Be 0
            @($assessment.Problems).Count | Should -Be 0
            $assessment.Sufficiency | Should -Be 'Pass'
        }

        It 'calls it an open relay when the relay permission is actually granted' {
            $row = Get-TestRelayRow -Connector (New-TestConnector) -Right 'Granted'
            $row.OpenRelay | Should -BeTrue

            $assessment = Get-TestRelayAssessment -Row $row
            @($assessment.OpenRelays).Count | Should -Be 1
            $assessment.Outcomes | Should -Contain 'NonCompliant'
            ($assessment.Problems -join ' ') | Should -Match 'anonymous principal'
        }

        It 'calls an externally secured ExchangeServers connector an open relay' {
            $connector = New-TestConnector -Name 'Relay' -PermissionGroups 'ExchangeServers' -AuthMechanism 'ExternalAuthoritative'
            $row = Get-TestRelayRow -Connector $connector -Right 'NotGranted'

            $row.AllowsAnonymous | Should -BeFalse
            $row.ExternallySecured | Should -BeTrue
            $row.OpenRelay | Should -BeTrue

            $assessment = Get-TestRelayAssessment -Row $row
            ($assessment.Problems -join ' ') | Should -Match 'externally secured'
        }

        It 'reports a connector whose permissions could not be read as not assessable' {
            $row = Get-TestRelayRow -Connector (New-TestConnector) -Right 'Unknown'
            $row.RelayAssessable | Should -BeFalse

            $assessment = Get-TestRelayAssessment -Row $row
            $assessment.Outcomes | Should -Contain 'Unknown'
            $assessment.Sufficiency | Should -Be 'SoftFail'
            ($assessment.Problems -join ' ') | Should -Match 'could not be ruled out'
        }

        It 'will not judge a connector that did not return a property the test reads' {
            # A default standing in for an unread property decides the verdict on its own: an
            # absent PermissionGroups would turn a real open relay into a pass, and an absent
            # RequireTLS would invent a finding nothing measured.
            $partial = New-TestConnector
            $partial.PSObject.Properties.Remove('PermissionGroups')

            $row = Get-TestRelayRow -Connector $partial -Right 'NotGranted'
            $row.UnreadableProperties | Should -Be 'PermissionGroups'
            $row.RelayAssessable | Should -BeFalse

            $assessment = Get-TestRelayAssessment -Row $row
            $assessment.Outcomes | Should -Contain 'Unknown'
            $assessment.Sufficiency | Should -Be 'SoftFail'
            ($assessment.Problems -join ' ') | Should -Match 'missing PermissionGroups'
        }

        It 'treats a null property value as data and an absent property as unreadable' {
            # TlsAuthLevel is legitimately null on a Send connector that does not require TLS,
            # and that is exactly the case this control exists to flag. Only an absent property
            # is unreadable.
            $present = New-TestConnector
            $present.RequireTLS = $null
            (Get-TestRelayRow -Connector $present -Right 'NotGranted').UnreadableProperties | Should -Be ''

            $absent = New-TestConnector
            $absent.PSObject.Properties.Remove('RequireTLS')
            (Get-TestRelayRow -Connector $absent -Right 'NotGranted').UnreadableProperties | Should -Be 'RequireTLS'
        }

        It 'does not mistake ExchangeLegacyServers for ExchangeServers' {
            $connector = New-TestConnector -PermissionGroups 'ExchangeLegacyServers' -AuthMechanism 'ExternalAuthoritative'
            $row = Get-TestRelayRow -Connector $connector -Right 'NotGranted'
            $row.ExternallySecured | Should -BeFalse
        }

        It 'matches an anonymous principal by full name and by leaf' {
            $principals = @('NT AUTHORITY\ANONYMOUS LOGON', 'ANONYMOUS LOGON')
            $match = & (Get-Module $script:ModuleName) {
                param($u, $p) Test-ExchPrincipalMatch -User $u -Principals $p
            } 'NT AUTHORITY\ANONYMOUS LOGON' $principals
            $match | Should -BeTrue

            $other = & (Get-Module $script:ModuleName) {
                param($u, $p) Test-ExchPrincipalMatch -User $u -Principals $p
            } 'CONTOSO\svc-relay' $principals
            $other | Should -BeFalse
        }

        It 'still recognises every form of an unrestricted remote range' {
            (Test-TestUnrestricted -Range '0.0.0.0-255.255.255.255') | Should -BeTrue
            (Test-TestUnrestricted -Range '0.0.0.0/0') | Should -BeTrue
            (Test-TestUnrestricted -Range '::/0') | Should -BeTrue
            (Test-TestUnrestricted -Range '::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff') | Should -BeTrue
            (Test-TestUnrestricted -Range '192.168.1.0-192.168.1.255') | Should -BeFalse
            (Test-TestUnrestricted -Range '10.0.0.7') | Should -BeFalse
        }
    }

    Context 'Reference data integrity' {

        BeforeAll {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop
            $script:BuildTable = & (Get-Module $script:ModuleName) { Get-ExchBuildTable }
            $script:Thresholds = & (Get-Module $script:ModuleName) { Import-ExchConfiguration }
        }

        It 'loads a build table whose every row parses' {
            @($script:BuildTable.Builds).Count | Should -BeGreaterThan 0
            $script:BuildTable.TableAsOf | Should -BeOfType [datetime]

            $bad = foreach ($row in $script:BuildTable.Builds) {
                if (-not ($row.Build -as [version]))      { "unparseable build: $($row.Build)" }
                if (-not $row.Product)                    { "row with no product: $($row.Build)" }
                if (-not $row.Release)                    { "row with no release: $($row.Build)" }
                if (-not ($row.Released -as [datetime]))  { "unparseable release date: $($row.Build)" }
            }
            $bad | Should -BeNullOrEmpty -Because "the build table is malformed: $($bad -join '; ')"
        }

        It 'lists no build twice' {
            $duplicates = $script:BuildTable.Builds | Group-Object -Property Build | Where-Object Count -gt 1 | ForEach-Object Name
            $duplicates | Should -BeNullOrEmpty -Because "duplicated builds: $($duplicates -join ', ')"
        }

        It 'requires the caller to hand it the table it should judge against' {
            # -Table was optional once, falling back to the table shipped in the repository. A
            # run started with -BuildTablePath would then have been judged against the wrong
            # one, silently.
            $attribute = (& (Get-Module $script:ModuleName) { (Get-Command Resolve-ExchBuild).Parameters['Table'] }).Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
            $attribute.Mandatory | Should -BeTrue -Because 'a fallback to the in-repo table would ignore -BuildTablePath'
        }

        It 'sums an empty collection to zero rather than throwing' {
            # Measure-Object returns nothing for an empty set, and .Sum on nothing is a
            # terminating error under Set-StrictMode. This took out TR.QUE-01 whenever every
            # queue was excluded as unassessable, and would have done the same to an
            # organisation whose transport servers returned no queues at all.
            $sum = & (Get-Module $script:ModuleName) { Get-ExchSum -InputObject @() -Property 'MessageCount' }
            $sum | Should -Be 0

            $rows = @([pscustomobject]@{ MessageCount = 3 }, [pscustomobject]@{ MessageCount = 4 })
            $counted = & (Get-Module $script:ModuleName) { param($r) Get-ExchSum -InputObject $r -Property 'MessageCount' } $rows
            $counted | Should -Be 7
        }

        It 'refuses a missing build table rather than falling back to an empty one' {
            $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("no-such-build-table-" + [guid]::NewGuid() + '.psd1')
            { & (Get-Module $script:ModuleName) { param($p) Get-ExchBuildTable -Path $p } $missing } |
                Should -Throw -Because 'an empty table would report every server as unverifiable and look like a clean run'
        }

        It 'names each Active Directory preparation level exactly once' {
            $levels = @($script:Thresholds.ActiveDirectory.KnownPreparationLevels)
            $levels.Count | Should -BeGreaterThan 0

            $unnamed = @($levels | Where-Object { -not $_.Name })
            $unnamed | Should -BeNullOrEmpty -Because 'a preparation level with no name cannot be reported'

            $duplicates = $levels | Group-Object -Property { "$($_.RangeUpper)/$($_.ConfigVersion)" } |
                Where-Object Count -gt 1 | ForEach-Object Name
            $duplicates | Should -BeNullOrEmpty -Because "a lower cumulative update would shadow a higher one for: $($duplicates -join ', ')"
        }

        It 'carries a preparation level matching the configured Exchange SE target' {
            $ad = $script:Thresholds.ActiveDirectory
            $match = @($ad.KnownPreparationLevels | Where-Object {
                [int]$_.RangeUpper -eq [int]$ad.TargetSchemaRangeUpper -and
                [int]$_.ConfigVersion -eq [int]$ad.TargetObjectVersionConfiguration
            })
            @($match).Count | Should -Be 1 -Because 'the level the assessment targets must be one it can name'
            [int]$ad.TargetObjectVersionDefault | Should -Be 13243
        }

        It 'claims no Windows Server 2025 functional level Microsoft has not published' {
            # Windows Server 2025 introduced FFL/DFL level 10, and it is not in the Exchange
            # supportability matrix. Asserting support Microsoft has not stated is worse than
            # reporting the level as unlisted.
            $ad = $script:Thresholds.ActiveDirectory
            foreach ($key in @('SupportedForestModes', 'RecommendedForestModes', 'SupportedDomainModes', 'RecommendedDomainModes')) {
                $offenders = @($ad[$key] | Where-Object { $_ -match 'Windows2025' })
                $offenders | Should -BeNullOrEmpty -Because "$key must not claim an unverified supportability position: $($offenders -join ', ')"
            }
        }

        It 'keys the operating system support matrix on real Exchange product families' {
            $families = @($script:Thresholds.Exchange.Families | ForEach-Object { [string]$_.Name })
            $matrix = @($script:Thresholds.OperatingSystem.SupportMatrix)
            $matrix.Count | Should -BeGreaterThan 0

            $bad = foreach ($row in $matrix) {
                if ([string]$row.Product -notin $families) { "unknown product: $($row.Product)" }
                foreach ($build in @(@($row.SupportedBuilds) + @($row.MinimumBuild) + @($row.RecommendedBuild))) {
                    if (-not ($build -as [version])) { "unparseable build '$build' for $($row.Product)" }
                }
            }
            $bad | Should -BeNullOrEmpty -Because "the operating system matrix is malformed: $($bad -join '; ')"
        }

        It 'judges the operating system against the Exchange version installed on the server' {
            $run = [pscustomobject]@{ Config = $script:Thresholds; Flags = @{} }
            $resolve = {
                param($r, $version, $product) Resolve-ExchOsSupport -Run $r -Version $version -Product $product
            }

            # Windows Server 2016 under Exchange 2016 is a correct build, and the previous global
            # floor of Windows Server 2019 reported it as unsupported.
            $ex2016 = & (Get-Module $script:ModuleName) $resolve $run '10.0.14393.1000' 'Exchange Server 2016'
            $ex2016.Supported | Should -BeTrue
            $ex2016.Matched   | Should -BeTrue

            # ...and the same operating system under Exchange Server SE is not.
            $se = & (Get-Module $script:ModuleName) $resolve $run '10.0.14393.1000' 'Exchange Server SE'
            $se.Supported | Should -BeFalse
            $se.Matched   | Should -BeTrue

            # Exchange 2016's supported set has an upper bound as well as a floor.
            $tooNew = & (Get-Module $script:ModuleName) $resolve $run '10.0.20348.1' 'Exchange Server 2016'
            $tooNew.Supported | Should -BeFalse

            # A product with no row cannot be judged, and must say so rather than guess.
            $unknown = & (Get-Module $script:ModuleName) $resolve $run '6.3.9600.1' 'Exchange Server 2013'
            $unknown.Matched   | Should -BeFalse
            $unknown.Supported | Should -BeFalse
        }
    }

    Context 'Collector scope is honest' {

        It 'reads transport queues per server rather than only the local one' {
            # Get-Queue with no -Server qualifier implies the local server, so a single call
            # reports one server's backlog under an organisation-wide rationale.
            $file = Join-Path $script:CollectorRoot 'TR.QUE-01.TransportQueue.ps1'
            $file | Should -Exist

            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
            $calls = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-Queue'
            }, $true))

            $calls.Count | Should -BeGreaterThan 0 -Because 'the collector must still read queues'

            foreach ($call in $calls) {
                $scoped = @($call.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Server'
                })
                $scoped.Count | Should -BeGreaterThan 0 -Because 'every Get-Queue call must name the server it is asking'
            }
        }
    }

    Context 'Static analysis' {

        It 'reports no PSScriptAnalyzer findings for the repository' {
            $script:SettingsPath | Should -Exist

            $findings = Invoke-ScriptAnalyzer -Path $script:RepoRoot -Recurse -Settings $script:SettingsPath
            $report = ($findings | Format-Table -AutoSize | Out-String)

            $findings.Count | Should -Be 0 -Because "PSScriptAnalyzer reported:`n$report"
        }
    }
}

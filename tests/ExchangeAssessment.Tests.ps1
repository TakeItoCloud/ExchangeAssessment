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

        It 'documents every function added with the deployment contract' {
            # Public functions from here on ship with full comment-based help. The earlier ones
            # predate that and carry a file header instead; add each new export to this list.
            $documented = @('New-ExchDeploymentConfig')

            foreach ($name in $documented) {
                $script:Exported | Should -Contain $name

                $file = Join-Path -Path $script:ToolRoot -ChildPath "Public/$name.ps1"
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
                $definition = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                }, $true)
                $definition | Should -Not -BeNullOrEmpty -Because "$file must define $name"

                $help = $definition.GetHelpContent()
                $help | Should -Not -BeNullOrEmpty -Because "$name must carry comment-based help"
                $help.Synopsis | Should -Not -BeNullOrEmpty -Because "$name needs a SYNOPSIS"
                $help.Description | Should -Not -BeNullOrEmpty -Because "$name needs a DESCRIPTION"
                $help.Parameters.Count | Should -BeGreaterThan 0 -Because "$name needs at least one PARAMETER"
                foreach ($parameter in $definition.Body.ParamBlock.Parameters) {
                    $help.Parameters.Keys | Should -Contain $parameter.Name.VariablePath.UserPath -Because "$name must document every parameter"
                }
                $help.Examples.Count | Should -BeGreaterOrEqual 2 -Because "$name needs at least two EXAMPLE blocks"
            }
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

        It 'prints the deployment config warning as a delimited block and still logs every warning' {
            # The block is keyed on the prefix Get-ExchDeploymentConfigWarning gives both of its
            # forms; the 'Deployment config contract' tests find the warning by that same prefix.
            $text = Get-Content -Path $script:EntryScript -Raw
            $text | Should -Match ([regex]::Escape('Get-ExchPreflightReport -Run $run'))
            $text | Should -Match ([regex]::Escape("`$w.StartsWith('Deployment config:')"))
            $text | Should -Match ([regex]::Escape("Write-ExchEvent -Run `$run -Level WARN -Message 'Preflight' -Data @{ warning = `$w }"))
        }

        It 'carries a worked deployment config example in its help' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:EntryScript, [ref]$null, [ref]$null)
            $help = $ast.GetHelpContent()
            $help | Should -Not -BeNullOrEmpty -Because 'the entry script must carry comment-based help'

            $worked = @($help.Examples | Where-Object { $_ -match 'New-ExchDeploymentConfig -Path' -and $_ -match '-ConfigPath' })
            $worked.Count | Should -BeGreaterThan 0 -Because 'one example must create the config and pass it back with -ConfigPath'
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

    Context 'Deployment config contract' {

        BeforeAll {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

            $script:DeploymentTemplate = Join-Path -Path $script:ToolRoot -ChildPath 'Config/Deployment.template.psd1'

            # The six keys the contract promises, written out here rather than read from the
            # module, so the template is checked against the specification and not against
            # itself.
            $script:ContractKeys = @('TargetServers', 'WitnessServer', 'DagName', 'InternalNames', 'DatabaseVolume', 'LogVolume')

            function Get-TestDeploymentWarning {
                param($Run)
                $report = Get-ExchPreflightReport -Run $Run
                @($report.warnings | Where-Object { $_.StartsWith('Deployment config:') })
            }

            # A fully filled Deployment section. Every host name sits under the reserved .test
            # top-level domain (RFC 2606) - nothing here came from a real organisation.
            function New-TestFilledDeployment {
                @{
                    TargetServers  = @('mbx01.example.test', 'mbx02.example.test')
                    WitnessServer  = 'fsw01.example.test'
                    DagName        = 'DAG01'
                    InternalNames  = @('mail.example.test', 'autodiscover.example.test')
                    DatabaseVolume = 'D:'
                    LogVolume      = 'L:'
                }
            }
        }

        It 'ships a template that parses and carries exactly the contract keys, all empty' {
            $script:DeploymentTemplate | Should -Exist

            $data = Import-PowerShellDataFile -Path $script:DeploymentTemplate
            $data.Keys | Should -Contain 'Deployment'
            $section = $data.Deployment
            $section | Should -BeOfType [hashtable]

            foreach ($key in $script:ContractKeys) {
                $section.Keys | Should -Contain $key -Because "the contract promises $key"
            }

            # Count the keys a second way, from the file's text rather than the parsed table, so
            # the count cannot agree with itself by construction and one key cannot pass for six.
            $text = Get-Content -Path $script:DeploymentTemplate -Raw
            $block = [regex]::Match($text, '(?ms)^[ \t]*Deployment[ \t]*=[ \t]*@\{(?<body>.*?)^[ \t]{4}\}')
            $block.Success | Should -BeTrue -Because 'the template must carry a Deployment = @{ ... } block'
            $counted = [regex]::Matches($block.Groups['body'].Value, '(?m)^[ \t]*[A-Za-z]\w*[ \t]*=').Count

            $section.Keys.Count | Should -Be $counted
            $counted | Should -Be $script:ContractKeys.Count

            # It ships empty. A filled template would put one client's host names in the module.
            foreach ($key in $section.Keys) {
                @($section[$key] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count |
                    Should -Be 0 -Because "$key must ship empty"
            }
        }

        It 'checks runs against the same keys the template ships' {
            $moduleKeys = & (Get-Module $script:ModuleName) { Get-ExchDeploymentKey }
            ($moduleKeys -join ',') | Should -Be ($script:ContractKeys -join ',')

            $templateKeys = @((Import-PowerShellDataFile -Path $script:DeploymentTemplate).Deployment.Keys)
            Compare-Object -ReferenceObject $script:ContractKeys -DifferenceObject $templateKeys | Should -BeNullOrEmpty
        }

        It 'resolves the template from the module base, and the file is there' {
            $resolved = & (Get-Module $script:ModuleName) { Get-ExchDeploymentTemplatePath }
            $expected = [System.IO.Path]::GetFullPath((Join-Path -Path (Get-Module $script:ModuleName).ModuleBase -ChildPath 'Config/Deployment.template.psd1'))

            [System.IO.Path]::IsPathRooted($resolved) | Should -BeTrue
            $resolved | Should -Be $expected
            $resolved | Should -Exist
        }

        It 'writes a copy of the template that parses, and returns its resolved path' {
            $target = Join-Path -Path $TestDrive -ChildPath 'Deployment.psd1'
            $returned = New-ExchDeploymentConfig -Path $target

            $returned | Should -Be (Resolve-Path -LiteralPath $target).ProviderPath
            [System.IO.Path]::IsPathRooted($returned) | Should -BeTrue
            (Import-PowerShellDataFile -Path $returned).Deployment.Keys.Count | Should -Be $script:ContractKeys.Count
            (Get-FileHash -LiteralPath $returned).Hash | Should -Be (Get-FileHash -LiteralPath $script:DeploymentTemplate).Hash
        }

        It 'resolves a relative path against the current location' {
            Push-Location -LiteralPath $TestDrive
            try { $returned = New-ExchDeploymentConfig -Path 'relative.psd1' }
            finally { Pop-Location }

            $returned | Should -Be (Resolve-Path -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'relative.psd1')).ProviderPath
        }

        It 'refuses to overwrite an existing file without -Force, and overwrites it with -Force' {
            $target = Join-Path -Path $TestDrive -ChildPath 'existing.psd1'
            Set-Content -LiteralPath $target -Value '@{ Marker = 1 }'

            { New-ExchDeploymentConfig -Path $target } | Should -Throw -ExpectedMessage '*-Force*'
            (Get-Content -LiteralPath $target -Raw) | Should -Match 'Marker' -Because 'a refused overwrite must leave the file alone'

            $returned = New-ExchDeploymentConfig -Path $target -Force
            $returned | Should -Be (Resolve-Path -LiteralPath $target).ProviderPath
            (Get-FileHash -LiteralPath $target).Hash | Should -Be (Get-FileHash -LiteralPath $script:DeploymentTemplate).Hash
        }

        It 'writes nothing under -WhatIf' {
            $target = Join-Path -Path $TestDrive -ChildPath 'whatif.psd1'
            $returned = New-ExchDeploymentConfig -Path $target -WhatIf

            $returned | Should -BeNullOrEmpty
            $target | Should -Not -Exist
        }

        It 'tells the operator to keep a filled copy out of source control' {
            $file = Join-Path -Path $script:ToolRoot -ChildPath 'Public/New-ExchDeploymentConfig.ps1'
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
            $help = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true).GetHelpContent()

            $help.Notes | Should -Match 'source control'
            $help.Outputs | Should -Match 'resolved full path'
        }

        It 'warns, without failing, when no deployment config was supplied' {
            $warning = @(Get-TestDeploymentWarning -Run ([pscustomobject]@{ Config = @{} }))
            $warning.Count | Should -Be 1

            $text = $warning[0]
            $template = [System.IO.Path]::GetFullPath((Join-Path -Path (Get-Module $script:ModuleName).ModuleBase -ChildPath 'Config/Deployment.template.psd1'))

            $text | Should -Match 'greenfield deployment controls will report Unknown'
            $text | Should -Match 'no target servers, witness or planned names were supplied'
            $text.Contains($template) | Should -BeTrue -Because "the warning must carry the resolved template path $template"
            $text | Should -Match ([regex]::Escape('New-ExchDeploymentConfig -Path '))
            $text | Should -Match ([regex]::Escape('New-ExchRun '))
            $text | Should -Match ([regex]::Escape('-ConfigPath '))
        }

        It 'warns the same way when called as existing callers call it, with no run' {
            { Get-ExchPreflightReport } | Should -Not -Throw
            @(Get-TestDeploymentWarning).Count | Should -Be 1
        }

        It 'treats the template passed back unfilled as nothing supplied' {
            $config = & (Get-Module $script:ModuleName) { param($p) Import-ExchConfiguration -ConfigPath $p } $script:DeploymentTemplate
            $warning = @(Get-TestDeploymentWarning -Run ([pscustomobject]@{ Config = $config }))

            $warning.Count | Should -Be 1
            $warning[0] | Should -Match 'none supplied'
        }

        It 'names exactly the missing keys of a partly filled config, and no others' {
            $deployment = New-TestFilledDeployment
            $deployment.WitnessServer = '   '
            $deployment.InternalNames = @('')
            $deployment.Remove('LogVolume')
            $expectedMissing = @('WitnessServer', 'InternalNames', 'LogVolume')

            $gap = & (Get-Module $script:ModuleName) { param($d) Get-ExchDeploymentConfigGap -Deployment $d } $deployment
            $gap.Supplied | Should -BeTrue
            ($gap.Missing -join ',') | Should -Be ($expectedMissing -join ',')

            $warning = @(Get-TestDeploymentWarning -Run ([pscustomobject]@{ Config = @{ Deployment = $deployment } }))
            $warning.Count | Should -Be 1
            foreach ($key in $script:ContractKeys) {
                $isMissing = $key -in $expectedMissing
                ($warning[0] -cmatch "\b$key\b") | Should -Be $isMissing -Because $(if ($isMissing) { "$key is missing and must be named" } else { "$key is filled and must not be named" })
            }
        }

        It 'accepts a filled copy of the template through the real -ConfigPath merge' {
            # The operator's path end to end: write the copy, fill it, merge it over the
            # thresholds the way New-ExchRun does, and ask preflight.
            $target = New-ExchDeploymentConfig -Path (Join-Path -Path $TestDrive -ChildPath 'filled.psd1')
            $text = Get-Content -LiteralPath $target -Raw
            $text = $text -replace "(?m)^(\s*TargetServers\s*=\s*)@\(\)", "`$1@('mbx01.example.test', 'mbx02.example.test')"
            $text = $text -replace "(?m)^(\s*WitnessServer\s*=\s*)''", "`$1'fsw01.example.test'"
            $text = $text -replace "(?m)^(\s*DagName\s*=\s*)''", "`$1'DAG01'"
            $text = $text -replace "(?m)^(\s*InternalNames\s*=\s*)@\(\)", "`$1@('mail.example.test')"
            $text = $text -replace "(?m)^(\s*DatabaseVolume\s*=\s*)''", "`$1'D:'"
            $text = $text -replace "(?m)^(\s*LogVolume\s*=\s*)''", "`$1'L:'"
            Set-Content -LiteralPath $target -Value $text

            $config = & (Get-Module $script:ModuleName) { param($p) Import-ExchConfiguration -ConfigPath $p } $target
            $config.Deployment.WitnessServer | Should -Be 'fsw01.example.test'
            $config.Certificate.ExpiryWarningDays | Should -Not -BeNullOrEmpty -Because 'the thresholds must still be there under the merged Deployment section'

            @(Get-TestDeploymentWarning -Run ([pscustomobject]@{ Config = $config })).Count | Should -Be 0
        }

        It 'returns the same shape, minus the deployment warning, when the config is complete' {
            $none = Get-ExchPreflightReport -Run ([pscustomobject]@{ Config = @{} })
            $full = Get-ExchPreflightReport -Run ([pscustomobject]@{ Config = @{ Deployment = (New-TestFilledDeployment) } })

            # One property, warnings, holding an array of strings - what Invoke-ExchAssess.ps1
            # reads.
            ($full.PSObject.Properties.Name -join ',') | Should -Be 'warnings'
            ($none.PSObject.Properties.Name -join ',') | Should -Be 'warnings'
            ($full.warnings -is [array]) | Should -BeTrue
            foreach ($w in @($full.warnings)) { $w | Should -BeOfType [string] }

            @($full.warnings | Where-Object { $_.StartsWith('Deployment config:') }).Count | Should -Be 0
            # A complete config removes the one deployment warning and touches nothing else.
            @($none.warnings).Count | Should -Be (@($full.warnings).Count + 1)
        }
    }

    Context 'Target server readiness (DEP.TGT-01)' {

        BeforeAll {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

            $script:PrereqTableFile = Join-Path -Path $script:ToolRoot -ChildPath 'Config/PrereqTable.psd1'
            $script:DepCollectorFile = Join-Path -Path $script:CollectorRoot -ChildPath 'DEP.TGT-01.TargetServerReadiness.ps1'

            # How many prerequisite keys the table declares, written here rather than read from the
            # module, so a key dropped from the file or from the checks turns this context red.
            $script:DeclaredPrereqCount = 17

            $script:PrereqData = Import-PowerShellDataFile -Path $script:PrereqTableFile
            $script:PrereqDefinitions = @{}
            foreach ($definition in @(& (Get-Module $script:ModuleName) { Get-ExchPrereqCheckDefinition })) {
                $script:PrereqDefinitions[$definition.Key] = $definition
            }

            # A synthetic run. Every host name sits under the reserved .test top-level domain
            # (RFC 2606) and every address in TEST-NET-1 (RFC 5737): nothing here is a real host.
            function New-TestDepRun {
                param([object[]]$Targets = @(), [string]$PrereqTablePath = '', [switch]$NoDeployment)
                $folder = Join-Path -Path $TestDrive -ChildPath ('run-' + [guid]::NewGuid())
                New-Item -ItemType Directory -Path (Join-Path -Path $folder -ChildPath 'evidence') -Force | Out-Null
                $config = if ($NoDeployment) { @{} } else { @{ Deployment = @{ TargetServers = $Targets } } }
                [pscustomobject]@{
                    RunId = 'test'; TenantHint = 'test'; RunFolder = $folder
                    LogPath = (Join-Path -Path $folder -ChildPath 'run.jsonl'); ConfigPath = ''
                    Config = $config; Flags = @{}; PrereqTablePath = $PrereqTablePath
                    Errors = (New-Object System.Collections.Generic.List[object])
                }
            }

            # What a server that meets every documented prerequisite returns: Windows Server build
            # 20348, Standard Server Core, 128 GB installed with a fixed 32768 MB page file, 100 GB
            # free on C:, Remote Registry automatic.
            function Get-TestCimInstance {
                param([string]$ClassName)
                if ($script:DepScenario.Cim -and $script:DepScenario.Cim.ContainsKey($ClassName)) { return $script:DepScenario.Cim[$ClassName] }
                switch ($ClassName) {
                    'Win32_OperatingSystem' { [pscustomobject]@{ Caption = 'Test Server OS'; Version = '10.0.20348'; OperatingSystemSKU = 13; SystemDrive = 'C:'; LastBootUpTime = [datetime]'2026-09-01' } }
                    'Win32_ComputerSystem'  { [pscustomobject]@{ PartOfDomain = $true; Domain = 'corp.example.test'; DomainRole = 3; AutomaticManagedPagefile = $false } }
                    'Win32_NTDomain'        { [pscustomobject]@{ DomainName = 'CORP'; DNSForestName = 'example.test' } }
                    'Win32_Volume'          { [pscustomobject]@{ Name = 'C:\'; DriveLetter = 'C:'; FileSystem = 'NTFS'; Capacity = 200GB; FreeSpace = 100GB; BlockSize = 4096 } }
                    'Win32_PageFileSetting' { [pscustomobject]@{ Name = 'C:\pagefile.sys'; InitialSize = 32768; MaximumSize = 32768 } }
                    'Win32_PhysicalMemory'  { [pscustomobject]@{ Capacity = 64GB }; [pscustomobject]@{ Capacity = 64GB } }
                    'Win32_Service'         { [pscustomobject]@{ Name = 'RemoteRegistry'; StartMode = 'Auto'; State = 'Running' } }
                    default                 { throw "Unexpected CIM class in test: $ClassName" }
                }
            }

            # What the WinRM reading of the same server returns. The display names are the ones the
            # table documents; the versions are placeholders, not real build numbers.
            function New-TestRemoteReading {
                $features = @($script:PrereqData.Prerequisites.WindowsFeatures.Value.DesktopExperience)
                $indicators = @($script:PrereqData.Prerequisites.PendingReboot.Value)
                [pscustomobject]@{
                    DotNetRelease     = 528449
                    DotNetFullKey     = $true
                    Uninstall         = @(
                        [pscustomobject]@{ Root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; DisplayName = 'Microsoft Visual C++ 2012 Redistributable (x64) - 0.0.1'; DisplayVersion = '0.0.1' }
                        [pscustomobject]@{ Root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; DisplayName = 'Microsoft Unified Communications Managed API 4.0, Runtime'; DisplayVersion = '0.0.1' }
                    )
                    UnreadableEntries = 0
                    Features          = @($features | ForEach-Object { [pscustomobject]@{ Name = $_; InstallState = 'Installed' } })
                    ProgramFiles      = 'C:\Program Files'
                    Reboot            = @($indicators | ForEach-Object { [pscustomobject]@{ Path = $_.Path; ValueName = $_.ValueName; Present = $false } })
                    Errors            = @{}
                }
            }

            function Invoke-TestDep {
                param($Run)
                & (Get-Module $script:ModuleName) { param($r) Invoke-ExchCollector_DEP_TGT_01_TargetServerReadiness -Run $r } $Run
            }

            $script:DepScenario = @{}

            # Every remote call is mocked. The collector reaches targets only through these three
            # helpers, and the assessment host's forest through the fourth.
            Mock -ModuleName $script:ModuleName Resolve-ExchTargetName {
                if ($script:DepScenario.ResolveThrows) { throw 'resolver failed (test)' }
                if (@($script:DepScenario.Unresolvable) -contains $Name) { return [pscustomobject]@{ Resolved = $false; Addresses = @(); Error = 'No such host is known (test)' } }
                [pscustomobject]@{ Resolved = $true; Addresses = @('192.0.2.10'); Error = '' }
            }
            Mock -ModuleName $script:ModuleName Get-ExchTargetCimInstance {
                if ($script:DepScenario.CimFails -or @($script:DepScenario.CimDown) -contains $ComputerName) { throw "CIM connection to $ComputerName refused (test)" }
                if ($script:DepScenario.FailingCimClass -eq $ClassName) { throw "$ClassName query failed (test)" }
                Get-TestCimInstance -ClassName $ClassName
            }
            Mock -ModuleName $script:ModuleName Invoke-ExchTargetCommand {
                if ($script:DepScenario.WinRmFails -or @($script:DepScenario.WinRmDown) -contains $ComputerName) { throw "WinRM connection to $ComputerName refused (test)" }
                New-TestRemoteReading
            }
            Mock -ModuleName $script:ModuleName Get-ExchRunForestName { 'example.test' }
        }

        BeforeEach { $script:DepScenario = @{} }

        It 'registers DEP.TGT-01 as a well-formed row whose function resolves to a real function' {
            $registry = & (Get-Module $script:ModuleName) { Get-ExchCollectorRegistry }
            $rows = @($registry | Where-Object { $_.Id -eq 'DEP.TGT-01' })
            $rows.Count | Should -Be 1

            $row = $rows[0]
            $row.Function | Should -Be 'Invoke-ExchCollector_DEP_TGT_01_TargetServerReadiness'
            $row.Area | Should -Be 'Deployment'
            @($row.Requires).Count | Should -Be 0
            $row.Cloud | Should -BeFalse
            $row.SkipFlag | Should -Be 'SkipDeploymentChecks'

            $command = & (Get-Module $script:ModuleName) { param($n) Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue } $row.Function
            $command | Should -Not -BeNullOrEmpty -Because 'the registry row must name a function the module defines'
            $command.Parameters.Keys | Should -Contain 'Run'

            # The skip flag is honoured only when Invoke-ExchCollection has a switch of that name.
            (Get-Command -Name 'Invoke-ExchCollection' -Module $script:ModuleName).Parameters.Keys | Should -Contain $row.SkipFlag
            { & (Get-Module $script:ModuleName) { Get-ExchControlById -ControlId 'DEP.TGT-01' } } | Should -Not -Throw
        }

        It 'reports exactly one Unknown finding carrying the three P13 strings when no target server was supplied' {
            $template = & (Get-Module $script:ModuleName) { Get-ExchDeploymentTemplatePath }

            foreach ($run in @((New-TestDepRun -NoDeployment), (New-TestDepRun -Targets @()), (New-TestDepRun -Targets @('', '   ')))) {
                $result = Invoke-TestDep -Run $run
                @($result.findings).Count | Should -Be 1
                @($result.sections).Count | Should -Be 0

                $finding = $result.findings[0]
                $finding.controlId | Should -Be 'DEP.TGT-01'
                $finding.result.outcome | Should -Be 'Unknown'
                $rationale = $finding.result.rationale
                $rationale | Should -Not -BeNullOrEmpty
                $rationale.Contains($template) | Should -BeTrue -Because "the rationale must carry the template path $template"
                $rationale.Contains('New-ExchDeploymentConfig -Path .\Deployment.psd1') | Should -BeTrue
                $rationale.Contains('-ConfigPath .\Deployment.psd1') | Should -BeTrue
                $rationale | Should -Match 'does not mean there are no target servers'
            }

            Should -Invoke -ModuleName $script:ModuleName -CommandName Resolve-ExchTargetName -Times 0 -Exactly
        }

        It 'judges the 5 CIM-only checks and reports the 12 checks that need WinRM as Unknown when only CIM answers' {
            $script:DepScenario = @{ WinRmFails = $true }
            $result = Invoke-TestDep -Run (New-TestDepRun -Targets @('mbx01.example.test'))
            $metrics = $result.findings[0].result.metrics

            $server = @($metrics.servers)[0]
            $server.CimState | Should -Be 'Succeeded'
            $server.WinRmState | Should -Be 'Failed'
            $server.WinRmError | Should -Match 'WinRM connection to mbx01\.example\.test refused'
            $server.Status | Should -Be 'PartiallyRead'

            $rows = @($metrics.checks)
            $rows.Count | Should -Be $script:DeclaredPrereqCount
            $cimOnly = @($rows | Where-Object { @($script:PrereqDefinitions[$_.Check].Mechanisms) -notcontains 'WinRM' })
            $needWinRm = @($rows | Where-Object { @($script:PrereqDefinitions[$_.Check].Mechanisms) -contains 'WinRM' })
            $cimOnly.Count | Should -Be 5
            $needWinRm.Count | Should -Be 12

            foreach ($row in $cimOnly) {
                $row.Outcome | Should -Be 'Compliant' -Because "$($row.Check) reads only CIM, which answered"
                $row.MechanismState | Should -Be 'CIM:Read'
            }
            foreach ($row in $needWinRm) {
                $row.Outcome | Should -Be 'Unknown' -Because "$($row.Check) needs WinRM, which failed"
                $row.Cause | Should -Match '^Not read: .*WinRM \(Invoke-Command\) to mbx01\.example\.test failed'
                $row.MechanismState | Should -Match 'WinRM:Failed'
            }
            $result.findings[0].result.outcome | Should -Not -Be 'Compliant'
        }

        It 'judges the 8 WinRM-only checks and reports the 9 checks that need CIM as Unknown when only WinRM answers' {
            $script:DepScenario = @{ CimFails = $true }
            $result = Invoke-TestDep -Run (New-TestDepRun -Targets @('mbx01.example.test'))
            $metrics = $result.findings[0].result.metrics

            $server = @($metrics.servers)[0]
            $server.CimState | Should -Be 'Failed'
            $server.CimError | Should -Match 'Win32_OperatingSystem query failed: CIM connection to mbx01\.example\.test refused'
            $server.WinRmState | Should -Be 'Succeeded'
            $server.Status | Should -Be 'PartiallyRead'

            $rows = @($metrics.checks)
            $winRmOnly = @($rows | Where-Object { @($script:PrereqDefinitions[$_.Check].Mechanisms) -notcontains 'CIM' })
            $needCim = @($rows | Where-Object { @($script:PrereqDefinitions[$_.Check].Mechanisms) -contains 'CIM' })
            $winRmOnly.Count | Should -Be 8
            $needCim.Count | Should -Be 9

            foreach ($row in $needCim) {
                $row.Outcome | Should -Be 'Unknown' -Because "$($row.Check) needs CIM, which failed"
                $row.Cause | Should -Match '^Not read: .*CIM on mbx01\.example\.test'
                $row.MechanismState | Should -Match 'CIM:Failed'
            }
            foreach ($row in $winRmOnly) {
                $row.MechanismState | Should -Be 'WinRM:Read'
                if ($row.Outcome -eq 'Unknown') {
                    $row.Cause | Should -Match '^No Learn-documented value' -Because "$($row.Check) was read, so only a missing table value may leave it Unknown"
                }
            }
            foreach ($check in @('VisualCppRedistributable2012', 'UcmaRuntime', 'PendingReboot')) {
                @($rows | Where-Object { $_.Check -eq $check })[0].Outcome | Should -Be 'Compliant'
            }
        }

        It 'turns a throwing mock into Unknown with a named cause, never a missing finding or a pass' {
            $script:DepScenario = @{ FailingCimClass = 'Win32_PageFileSetting' }
            $result = Invoke-TestDep -Run (New-TestDepRun -Targets @('mbx01.example.test'))
            @($result.findings).Count | Should -Be 1
            $result.findings[0].result.outcome | Should -Not -Be 'Compliant'

            $pageFile = @($result.findings[0].result.metrics.checks | Where-Object { $_.Check -eq 'PageFileSize' })[0]
            $pageFile.Outcome | Should -Be 'Unknown'
            $pageFile.Cause | Should -Match 'Win32_PageFileSetting query failed: Win32_PageFileSetting query failed \(test\)'
            @($result.findings[0].result.metrics.servers)[0].CimState | Should -Be 'Partial'

            $script:DepScenario = @{ ResolveThrows = $true }
            $thrown = Invoke-TestDep -Run (New-TestDepRun -Targets @('mbx02.example.test'))
            @($thrown.findings).Count | Should -Be 1
            $thrown.findings[0].result.outcome | Should -Be 'Unknown'
            $server = @($thrown.findings[0].result.metrics.servers)[0]
            $server.Status | Should -Be 'NameDoesNotResolve'
            $server.ResolveError | Should -Match 'resolver failed \(test\)'

            foreach ($row in @(@($result.findings[0].result.metrics.checks) + @($thrown.findings[0].result.metrics.checks))) {
                if ($row.Outcome -eq 'Unknown') { [string]$row.Cause | Should -Not -BeNullOrEmpty -Because "$($row.Server) $($row.Check) is Unknown and must say why" }
            }
        }

        It 'tells a name that does not resolve from one that resolves but does not answer' {
            $script:DepScenario = @{ Unresolvable = @('typo01.example.test'); CimDown = @('down01.example.test'); WinRmDown = @('down01.example.test') }
            $result = Invoke-TestDep -Run (New-TestDepRun -Targets @('typo01.example.test', 'down01.example.test'))
            $finding = $result.findings[0]
            $servers = @($finding.result.metrics.servers)

            $typo = @($servers | Where-Object { $_.Server -eq 'typo01.example.test' })[0]
            $typo.Status | Should -Be 'NameDoesNotResolve'
            $typo.Resolves | Should -Be 'False'
            $typo.CimState | Should -Be 'NotAttempted'
            $typo.WinRmState | Should -Be 'NotAttempted'

            $down = @($servers | Where-Object { $_.Server -eq 'down01.example.test' })[0]
            $down.Status | Should -Be 'Unreachable'
            $down.Resolves | Should -Be 'True'
            $down.CimState | Should -Be 'Failed'
            $down.WinRmState | Should -Be 'Failed'

            @($finding.result.metrics.unresolvedNames) | Should -Be @('typo01.example.test')
            @($finding.result.metrics.unreachableNames) | Should -Be @('down01.example.test')

            $rationale = $finding.result.rationale
            $rationale | Should -Match 'do not resolve, so nothing was sent to them.*typo01\.example\.test'
            $unreachableSentence = ($rationale -split 'answered neither CIM nor WinRM')[1]
            $unreachableSentence | Should -Match 'down01\.example\.test'
            ($unreachableSentence -split 'do not resolve')[0] | Should -Not -Match 'typo01' -Because 'a name that does not resolve must not be reported as a server that is down'

            Should -Invoke -ModuleName $script:ModuleName -CommandName Get-ExchTargetCimInstance -Times 0 -Exactly -ParameterFilter { $ComputerName -eq 'typo01.example.test' }
            Should -Invoke -ModuleName $script:ModuleName -CommandName Invoke-ExchTargetCommand -Times 0 -Exactly -ParameterFilter { $ComputerName -eq 'typo01.example.test' }
        }

        It 'exercises all 17 prerequisite keys declared in PrereqTable.psd1, one check per key per server' {
            # Counted from the file's text, not the parsed table, so the count cannot agree with
            # itself by construction.
            $text = Get-Content -LiteralPath $script:PrereqTableFile -Raw
            $block = [regex]::Match($text, '(?ms)^[ ]{4}Prerequisites[ ]*=[ ]*@\{(?<body>.*)^[ ]{4}\}')
            $block.Success | Should -BeTrue -Because 'the table must carry a Prerequisites = @{ ... } block'
            $textKeys = @([regex]::Matches($block.Groups['body'].Value, '(?m)^[ ]{8}(?<key>[A-Za-z]\w*)[ ]*=') | ForEach-Object { $_.Groups['key'].Value })

            $textKeys.Count | Should -Be $script:DeclaredPrereqCount
            Compare-Object -ReferenceObject $textKeys -DifferenceObject @($script:PrereqData.Prerequisites.Keys) | Should -BeNullOrEmpty
            Compare-Object -ReferenceObject $textKeys -DifferenceObject @($script:PrereqDefinitions.Keys) | Should -BeNullOrEmpty -Because 'every key needs a check, and every check a key'

            $result = Invoke-TestDep -Run (New-TestDepRun -Targets @('mbx01.example.test', 'mbx02.example.test'))
            $rows = @($result.findings[0].result.metrics.checks)
            $rows.Count | Should -Be (2 * $script:DeclaredPrereqCount)
            foreach ($server in @('mbx01.example.test', 'mbx02.example.test')) {
                $checked = @($rows | Where-Object { $_.Server -eq $server } | ForEach-Object { $_.Check })
                Compare-Object -ReferenceObject $textKeys -DifferenceObject $checked | Should -BeNullOrEmpty
            }
            @($rows | Where-Object { [string]$_.Cause -match 'No check is defined' }) | Should -BeNullOrEmpty

            $section = @($result.sections | Where-Object { $_.key -eq 'deployment.target-prerequisites' })[0]
            $section.totalRows | Should -Be (2 * $script:DeclaredPrereqCount)
        }

        It 'records a Learn URL and a read date next to every prerequisite value' {
            [datetime]::ParseExact([string]$script:PrereqData.TableAsOf, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) | Should -BeOfType [datetime]

            foreach ($key in $script:PrereqData.Prerequisites.Keys) {
                $entry = $script:PrereqData.Prerequisites[$key]
                $entry.Contains('Value') | Should -BeTrue -Because "$key must state a Value, even if it is `$null"
                $sources = @($entry['Source'] | Where-Object { $_ })
                $sources.Count | Should -BeGreaterThan 0 -Because "$key must name its source"
                foreach ($source in $sources) { $source | Should -Match '^https://learn\.microsoft\.com/' -Because "$key must be sourced from Microsoft Learn" }
                { [datetime]::ParseExact([string]$entry['Read'], 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) } | Should -Not -Throw -Because "$key must carry the date it was read"
                if ($null -eq $entry['Value']) { [string]$entry['Note'] | Should -Not -BeNullOrEmpty -Because "$key is `$null and must say what Learn does not document" }
            }
        }

        It 'never reads installed software through Win32_Product' {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:DepCollectorFile, [ref]$tokens, [ref]$errors)
            $errors | Should -BeNullOrEmpty

            # Prove the file was read and is the collector, not an empty parse.
            $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ExchCollector_DEP_TGT_01_TargetServerReadiness' }, $true) |
                Should -Not -BeNullOrEmpty

            $strings = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true) |
                ForEach-Object { [string]$_.Value })
            $classes = @($strings | Where-Object { $_ -like 'Win32_*' } | Sort-Object -Unique)
            $classes.Count | Should -BeGreaterOrEqual 7 -Because 'the collector reads seven CIM classes, so the scan must see them'
            @($strings | Where-Object { $_ -match 'Win32_Product' }) | Should -BeNullOrEmpty -Because 'Win32_Product triggers a Windows Installer consistency check'

            $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.Extent.Text })
            @($commands | Where-Object { $_ -match 'Win32_Product' }) | Should -BeNullOrEmpty

            # Installed software comes from both uninstall roots instead.
            $strings | Should -Contain 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            $strings | Should -Contain 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        }

        It 'reports a $null prerequisite value as Unknown where the same reading with a value passes' {
            $shipped = Invoke-TestDep -Run (New-TestDepRun -Targets @('mbx01.example.test'))
            @($shipped.findings[0].result.metrics.checks | Where-Object { $_.Check -eq 'SystemVolumeFreeSpaceMB' })[0].Outcome | Should -Be 'Compliant'

            $copy = Join-Path -Path $TestDrive -ChildPath 'PrereqTable.null.psd1'
            $text = Get-Content -LiteralPath $script:PrereqTableFile -Raw
            $nulled = [regex]::Replace($text, '(?ms)(SystemVolumeFreeSpaceMB = @\{\s*Value\s*=\s*)200', '${1}$null')
            $nulled | Should -Not -Be $text -Because 'the copy must actually null the value'
            Set-Content -LiteralPath $copy -Value $nulled

            $result = Invoke-TestDep -Run (New-TestDepRun -Targets @('mbx01.example.test') -PrereqTablePath $copy)
            $row = @($result.findings[0].result.metrics.checks | Where-Object { $_.Check -eq 'SystemVolumeFreeSpaceMB' })[0]
            $row.Outcome | Should -Be 'Unknown'
            $row.Cause | Should -Match '^No Learn-documented value'
            $row.Measured | Should -Match 'MB free' -Because 'what was found is still reported'
            $result.findings[0].result.metrics.prereqTablePath | Should -Be $copy

            # The table ships $null where Learn is silent, and those checks are Unknown too.
            @($shipped.findings[0].result.metrics.checks | Where-Object { $_.Check -eq 'VisualCppRedistributable2013' })[0].Outcome | Should -Be 'Unknown'
            $shipped.findings[0].result.outcome | Should -Not -Be 'Compliant'
        }

        It 'reports a domain controller, an existing Exchange server and a foreign forest as findings, not failures' {
            $script:DepScenario = @{ Cim = @{
                'Win32_ComputerSystem' = [pscustomobject]@{ PartOfDomain = $true; Domain = 'other.test'; DomainRole = 5; AutomaticManagedPagefile = $false }
                'Win32_NTDomain'       = [pscustomobject]@{ DomainName = 'OTHER'; DNSForestName = 'other.test' }
                'Win32_Service'        = @(
                    [pscustomobject]@{ Name = 'RemoteRegistry'; StartMode = 'Auto'; State = 'Running' }
                    [pscustomobject]@{ Name = 'MSExchangeServiceHost'; StartMode = 'Auto'; State = 'Running' }
                )
            } }

            $result = $null
            { $script:DepResult = Invoke-TestDep -Run (New-TestDepRun -Targets @('dc01.example.test')) } | Should -Not -Throw
            $result = $script:DepResult

            $server = @($result.findings[0].result.metrics.servers)[0]
            $server.IsDomainController | Should -Be 'True'
            $server.IsExchangeServer | Should -Be 'True'
            $server.SameForest | Should -Be 'False'

            $rationale = $result.findings[0].result.rationale
            $rationale | Should -Match 'are domain controllers'
            $rationale | Should -Match 'already run Exchange services'
            $rationale | Should -Match 'different forest'
            $result.findings[0].result.outcome | Should -Be 'NonCompliant'
        }

        It 'loads the prerequisite table the way the build table loads, and refuses a missing one' {
            $missing = Join-Path -Path $TestDrive -ChildPath 'no-such-prereq-table.psd1'
            { New-ExchRun -OutputRoot (Join-Path -Path $TestDrive -ChildPath 'out') -PrereqTablePath $missing } | Should -Throw -ExpectedMessage '*PrereqTablePath not found*'
            { & (Get-Module $script:ModuleName) { param($p) Get-ExchPrereqTable -Path $p } $missing } | Should -Throw -ExpectedMessage '*not found*'

            $override = & (Get-Module $script:ModuleName) { Get-ExchPrereqTablePath -Run ([pscustomobject]@{ PrereqTablePath = 'X:\override.psd1' }) }
            $override | Should -Be 'X:\override.psd1'
            $default = & (Get-Module $script:ModuleName) { Get-ExchPrereqTablePath -Run ([pscustomobject]@{ PrereqTablePath = '' }) }
            [System.IO.Path]::GetFullPath($default) | Should -Be ([System.IO.Path]::GetFullPath($script:PrereqTableFile))

            $table = & (Get-Module $script:ModuleName) { Get-ExchPrereqTable }
            $table.TableAsOf | Should -BeOfType [datetime]
            @($table.Prerequisites.Keys).Count | Should -Be $script:DeclaredPrereqCount
        }
    }

    Context 'Target port matrix (DEP.NET-01)' {

        BeforeAll {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

            $script:PortMatrixFile = Join-Path -Path $script:ToolRoot -ChildPath 'Config/PortMatrix.psd1'
            $script:NetCollectorFile = Join-Path -Path $script:CollectorRoot -ChildPath 'DEP.NET-01.TargetPortMatrix.ps1'

            # How many flows the matrix declares, written here rather than read from the module, so a
            # flow dropped from the file or from the probes turns this context red.
            $script:DeclaredFlowCount = 20

            $script:PortMatrixData = Import-PowerShellDataFile -Path $script:PortMatrixFile

            # A synthetic run. Every host name sits under the reserved .test top-level domain
            # (RFC 2606) and every address in TEST-NET-1 (RFC 5737): nothing here is a real host.
            function New-TestNetRun {
                param([object[]]$Targets = @(), [string]$Witness = 'fsw01.example.test', [string]$PortMatrixPath = '', [switch]$NoDeployment)
                $folder = Join-Path -Path $TestDrive -ChildPath ('run-' + [guid]::NewGuid())
                New-Item -ItemType Directory -Path (Join-Path -Path $folder -ChildPath 'evidence') -Force | Out-Null
                $config = if ($NoDeployment) { @{} } else { @{ Deployment = @{ TargetServers = $Targets; WitnessServer = $Witness } } }
                [pscustomobject]@{
                    RunId = 'test'; TenantHint = 'test'; RunFolder = $folder
                    LogPath = (Join-Path -Path $folder -ChildPath 'run.jsonl'); ConfigPath = ''
                    Config = $config; Flags = @{}; PortMatrixPath = $PortMatrixPath
                    Errors = (New-Object System.Collections.Generic.List[object])
                }
            }

            # What the probe returns when it runs on a target, built from the requests that target
            # was handed. Every flow succeeds unless the scenario says otherwise, the target reports its
            # own host name, and every DNS flow goes to the DNS server the target reports.
            function New-TestProbeReading {
                param([string]$ComputerName, [object[]]$Requests)
                $origin = if ($script:NetScenario.ContainsKey('Origin')) { $script:NetScenario.Origin } else { ($ComputerName -split '\.')[0].ToUpperInvariant() }
                $dns = @('192.0.2.53')
                $results = foreach ($request in @($Requests)) {
                    $destinations = if ($request['DestinationRole'] -eq 'DnsServer') { $dns } else { @($request['Destination']) }
                    foreach ($destination in $destinations) {
                        $status = switch ($request['Probe']) { 'WmiConnect' { 'Measured' } 'TcpConnect' { 'Connected' } default { 'Answered' } }
                        if ($script:NetScenario.ContainsKey('Status') -and $script:NetScenario.Status.ContainsKey($request['FlowId'])) { $status = $script:NetScenario.Status[$request['FlowId']] }
                        [pscustomobject]@{
                            Key = $request['Key']; Destination = $destination; DestinationAddress = '192.0.2.20'; Status = $status
                            Detail = 'test'; LocalAddress = '192.0.2.10:50000'; ElapsedMs = 1; ObservedRemotePorts = 'remote ports 135'
                        }
                    }
                }
                [pscustomobject]@{ OriginHost = $origin; DnsServers = $dns; DnsError = ''; TimeoutMilliseconds = 3000; Results = @($results) }
            }

            function Invoke-TestNet {
                param($Run)
                & (Get-Module $script:ModuleName) { param($r) Invoke-ExchCollector_DEP_NET_01_TargetPortMatrix -Run $r } $Run
            }

            $script:NetScenario = @{}
            $script:NetRequests = @{}

            # Every remote call is mocked: the target's name, the WinRM call that runs the probe on the
            # target, and the directory the domain controllers come from.
            Mock -ModuleName $script:ModuleName Resolve-ExchTargetName {
                if (@($script:NetScenario.Unresolvable) -contains $Name) { return [pscustomobject]@{ Resolved = $false; Addresses = @(); Error = 'No such host is known (test)' } }
                [pscustomobject]@{ Resolved = $true; Addresses = @('192.0.2.10'); Error = '' }
            }
            Mock -ModuleName $script:ModuleName Invoke-ExchTargetCommand {
                if (@($script:NetScenario.WinRmDown) -contains $ComputerName) { throw "WinRM connection to $ComputerName refused (test)" }
                $requests = @($ArgumentList[0])
                $script:NetRequests[$ComputerName] = $requests
                New-TestProbeReading -ComputerName $ComputerName -Requests $requests
            }
            Mock -ModuleName $script:ModuleName Get-ExchDirectoryDomainController {
                if ($script:NetScenario.DirectoryFails) { throw 'the directory could not be read (test)' }
                [pscustomobject]@{
                    Controllers = @(
                        [pscustomobject]@{ HostName = 'dc01.example.test'; Domain = 'example.test'; Site = 'Site1'; IsGlobalCatalog = $true }
                        [pscustomobject]@{ HostName = 'dc02.example.test'; Domain = 'example.test'; Site = 'Site2'; IsGlobalCatalog = $false }
                    )
                    Errors = @()
                }
            }
        }

        BeforeEach {
            $script:NetScenario = @{}
            $script:NetRequests = @{}
        }

        It 'registers DEP.NET-01 as a well-formed row whose function resolves, under the existing switch and category' {
            $registry = & (Get-Module $script:ModuleName) { Get-ExchCollectorRegistry }
            $rows = @($registry | Where-Object { $_.Id -eq 'DEP.NET-01' })
            $rows.Count | Should -Be 1

            $row = $rows[0]
            $row.Function | Should -Be 'Invoke-ExchCollector_DEP_NET_01_TargetPortMatrix'
            $row.Area | Should -Be 'Deployment'
            @($row.Requires).Count | Should -Be 0
            $row.Cloud | Should -BeFalse
            $row.SkipFlag | Should -Be 'SkipDeploymentChecks'

            $command = & (Get-Module $script:ModuleName) { param($n) Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue } $row.Function
            $command | Should -Not -BeNullOrEmpty -Because 'the registry row must name a function the module defines'
            $command.Parameters.Keys | Should -Contain 'Run'

            # The existing switch is reused, not a second one added.
            $switches = @((Get-Command -Name 'Invoke-ExchCollection' -Module $script:ModuleName).Parameters.Keys | Where-Object { $_ -like 'Skip*' })
            $switches | Should -Contain $row.SkipFlag
            @($switches | Where-Object { $_ -like '*Deployment*' }).Count | Should -Be 1

            # The report category is the one DEP.TGT-01 uses, so the ValidateSet did not grow.
            $control = & (Get-Module $script:ModuleName) { Get-ExchControlById -ControlId 'DEP.NET-01' }
            $existing = & (Get-Module $script:ModuleName) { Get-ExchControlById -ControlId 'DEP.TGT-01' }
            $control.domain | Should -Be $existing.domain
        }

        It 'reports exactly one Unknown finding carrying the three P13 strings when no target server was supplied, and contacts nothing' {
            $template = & (Get-Module $script:ModuleName) { Get-ExchDeploymentTemplatePath }

            foreach ($run in @((New-TestNetRun -NoDeployment), (New-TestNetRun -Targets @()), (New-TestNetRun -Targets @('', '   ')))) {
                $result = Invoke-TestNet -Run $run
                @($result.findings).Count | Should -Be 1
                @($result.sections).Count | Should -Be 0

                $finding = $result.findings[0]
                $finding.controlId | Should -Be 'DEP.NET-01'
                $finding.result.outcome | Should -Be 'Unknown'
                $rationale = $finding.result.rationale
                $rationale.Contains($template) | Should -BeTrue -Because "the rationale must carry the template path $template"
                $rationale.Contains('New-ExchDeploymentConfig -Path .\Deployment.psd1') | Should -BeTrue
                $rationale.Contains('-ConfigPath .\Deployment.psd1') | Should -BeTrue
            }

            Should -Invoke -ModuleName $script:ModuleName -CommandName Resolve-ExchTargetName -Times 0 -Exactly
            Should -Invoke -ModuleName $script:ModuleName -CommandName Invoke-ExchTargetCommand -Times 0 -Exactly
            Should -Invoke -ModuleName $script:ModuleName -CommandName Get-ExchDirectoryDomainController -Times 0 -Exactly
        }

        It 'reports every flow of a target WinRM cannot reach as Unknown naming the mechanism and the error, and leaves the other target alone' {
            $script:NetScenario = @{ WinRmDown = @('mbx02.example.test'); Unresolvable = @('typo01.example.test') }
            $result = Invoke-TestNet -Run (New-TestNetRun -Targets @('mbx01.example.test', 'mbx02.example.test', 'typo01.example.test'))
            $metrics = $result.findings[0].result.metrics
            $rows = @($metrics.flows)

            $down = @($rows | Where-Object { $_.Source -eq 'mbx02.example.test' })
            $down.Count | Should -BeGreaterOrEqual $script:DeclaredFlowCount
            foreach ($row in $down) {
                $row.Outcome | Should -Be 'Unknown' -Because "$($row.FlowId) was never probed from mbx02"
                $row.Cause | Should -Match 'WinRM \(Invoke-Command\) to mbx02\.example\.test failed: WinRM connection to mbx02\.example\.test refused \(test\)'
                $row.ProbeOrigin | Should -BeNullOrEmpty -Because 'no probe ran, so there is no origin to report'
            }

            $typo = @($rows | Where-Object { $_.Source -eq 'typo01.example.test' })
            $typo.Count | Should -BeGreaterOrEqual $script:DeclaredFlowCount
            foreach ($row in $typo) {
                $row.Outcome | Should -Be 'Unknown'
                $row.Cause | Should -Match 'typo01\.example\.test does not resolve'
            }

            $up = @($rows | Where-Object { $_.Source -eq 'mbx01.example.test' })
            foreach ($row in @($up | Where-Object { $_.Probe -ne 'WmiConnect' })) {
                $row.Outcome | Should -Be 'Open' -Because "mbx01 answered WinRM and $($row.FlowId) succeeded there"
            }

            # The target is the only probe path: two targets were asked, the one that does not resolve
            # was not, and nothing else was.
            Should -Invoke -ModuleName $script:ModuleName -CommandName Invoke-ExchTargetCommand -Times 2 -Exactly
            Should -Invoke -ModuleName $script:ModuleName -CommandName Invoke-ExchTargetCommand -Times 0 -Exactly -ParameterFilter { $ComputerName -eq 'typo01.example.test' }

            @($metrics.perTarget | Where-Object { $_.Server -eq 'mbx02.example.test' })[0].Status | Should -Be 'WinRmFailed'
            $result.findings[0].result.rationale | Should -Match 'did not answer WinRM'
            $result.findings[0].result.outcome | Should -Not -Be 'Compliant'
        }

        It 'has no local-probe fallback: every network primitive sits inside the probe, and only Invoke-ExchTargetCommand receives it' {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:NetCollectorFile, [ref]$tokens, [ref]$errors)
            $errors | Should -BeNullOrEmpty

            $probeFunction = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ExchPortProbeScript' }, $true)
            $probeFunction | Should -Not -BeNullOrEmpty
            $probe = $probeFunction.Body.Find({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
            $probe | Should -Not -BeNullOrEmpty
            $start = $probe.Extent.StartOffset
            $end = $probe.Extent.EndOffset

            # The declared population: the network primitives a probe is made of. Each one must be
            # found - so the scan is known to have read the probe - and every occurrence must be inside it.
            $population = @('System.Net.Sockets.TcpClient', 'System.Net.Sockets.UdpClient', 'System.Management.ManagementScope',
                'System.Net.Dns', 'Get-NetTCPConnection', 'Get-DnsClientServerAddress')
            $nodes = @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $n -is [System.Management.Automation.Language.TypeExpressionAst] -or
                $n -is [System.Management.Automation.Language.CommandAst] }, $true))
            foreach ($primitive in $population) {
                $hits = @($nodes | Where-Object {
                    ($_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -eq $primitive) -or
                    ($_ -is [System.Management.Automation.Language.TypeExpressionAst] -and $_.TypeName.FullName -eq $primitive) -or
                    ($_ -is [System.Management.Automation.Language.CommandAst] -and $_.GetCommandName() -eq $primitive) })
                $hits.Count | Should -BeGreaterThan 0 -Because "the scan must find $primitive, or it has not read the probe"
                foreach ($hit in $hits) {
                    ($hit.Extent.StartOffset -ge $start -and $hit.Extent.EndOffset -le $end) | Should -BeTrue -Because "$primitive at line $($hit.Extent.StartLineNumber) is outside the probe that runs on the target"
                }
            }

            # The probe is reached once, as the -ScriptBlock of Invoke-ExchTargetCommand.
            $references = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-ExchPortProbeScript' }, $true))
            $references.Count | Should -Be 1
            $invoke = $references[0].Parent
            while ($null -ne $invoke -and -not ($invoke -is [System.Management.Automation.Language.CommandAst])) { $invoke = $invoke.Parent }
            $invoke.GetCommandName() | Should -Be 'Invoke-ExchTargetCommand'
            $elements = @($invoke.CommandElements)
            $position = @(0..($elements.Count - 1) | Where-Object { $elements[$_].Extent.StartOffset -le $references[0].Extent.StartOffset -and $elements[$_].Extent.EndOffset -ge $references[0].Extent.EndOffset })[0]
            $elements[$position - 1].ParameterName | Should -Be 'ScriptBlock'

            # Outside the probe nothing runs a scriptblock, and nothing tests the network by itself.
            $invocations = @($ast.FindAll({ param($n)
                ($n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Unknown) -or
                ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and @('Invoke', 'InvokeReturnAsIs', 'BeginInvoke') -contains $n.Member.Extent.Text) }, $true) |
                Where-Object { -not ($_.Extent.StartOffset -ge $start -and $_.Extent.EndOffset -le $end) } | ForEach-Object { $_.Extent.Text })
            $invocations | Should -BeNullOrEmpty -Because 'a scriptblock run on the assessment host would be a probe from the wrong source'

            $forbidden = @('Invoke-Command', 'Test-NetConnection', 'Test-Connection', 'Resolve-DnsName', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Get-CimInstance', 'New-CimSession', 'Get-WmiObject')
            $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                Where-Object { $forbidden -contains $_.GetCommandName() } | ForEach-Object { $_.Extent.Text })
            $calls | Should -BeNullOrEmpty -Because 'remote calls go through the wrappers the tests replace'
        }

        It 'reports the witness flows Unknown naming Deployment.WitnessServer when it is empty, and still probes every domain controller flow' {
            $targets = @('mbx01.example.test', 'mbx02.example.test')
            $result = Invoke-TestNet -Run (New-TestNetRun -Targets $targets -Witness '')
            $rows = @($result.findings[0].result.metrics.flows)

            $witnessFlows = @($script:PortMatrixData.Flows | Where-Object { $_.DestinationRole -eq 'WitnessServer' })
            $witnessFlows.Count | Should -BeGreaterThan 0
            $witnessRows = @($rows | Where-Object { $_.DestinationRole -eq 'WitnessServer' })
            $witnessRows.Count | Should -Be ($witnessFlows.Count * $targets.Count)
            foreach ($row in $witnessRows) {
                $row.Outcome | Should -Be 'Unknown'
                $row.Cause | Should -Match 'Deployment\.WitnessServer is empty'
                $row.ProbeOrigin | Should -BeNullOrEmpty
            }
            foreach ($target in $targets) {
                @($script:NetRequests[$target] | Where-Object { $_['DestinationRole'] -eq 'WitnessServer' }).Count | Should -Be 0 -Because 'there was no witness to send'
            }

            $dcFlowIds = @($script:PortMatrixData.Flows | Where-Object { $_.DestinationRole -eq 'DomainController' } | ForEach-Object { $_.Id })
            $dcRows = @($rows | Where-Object { $_.DestinationRole -eq 'DomainController' })
            Compare-Object -ReferenceObject $dcFlowIds -DifferenceObject @($dcRows | ForEach-Object { $_.FlowId } | Sort-Object -Unique) | Should -BeNullOrEmpty
            foreach ($row in $dcRows) {
                $row.Outcome | Should -Be 'Open' -Because 'a missing witness must not suppress the domain controller flows'
                $row.ProbeOrigin | Should -Not -BeNullOrEmpty
            }
            $result.findings[0].result.rationale | Should -Match 'Deployment\.WitnessServer is empty'
        }

        It 'reports a timeout as Unknown with cause timeout, never Closed, and only a refusal as Closed' {
            $script:NetScenario = @{ Status = @{ DcLdapTcp = 'Timeout'; DcKerberosUdp = 'Timeout'; DcSmb = 'Refused' } }
            $result = Invoke-TestNet -Run (New-TestNetRun -Targets @('mbx01.example.test', 'mbx02.example.test'))
            $finding = $result.findings[0]
            $rows = @($finding.result.metrics.flows)

            foreach ($flowId in @('DcLdapTcp', 'DcKerberosUdp')) {
                $timedOut = @($rows | Where-Object { $_.FlowId -eq $flowId })
                $timedOut.Count | Should -BeGreaterThan 0
                foreach ($row in $timedOut) {
                    $row.Outcome | Should -Be 'Unknown' -Because 'a timeout is not a refusal'
                    $row.Cause | Should -Match '^timeout'
                }
            }

            $refused = @($rows | Where-Object { $_.FlowId -eq 'DcSmb' })
            $refused.Count | Should -BeGreaterThan 0
            foreach ($row in $refused) { $row.Outcome | Should -Be 'Closed' }
            @($rows | Where-Object { $_.Outcome -eq 'Closed' }).Count | Should -Be $refused.Count -Because 'nothing but the refusal is Closed'

            $finding.result.rationale | Should -Match 'reported, not judged'
            $finding.result.rationale | Should -Not -Match 'misconfigur'
        }

        It 'hands all 20 flows declared in PortMatrix.psd1 to every target, and every result names its source and the origin measured on the target' {
            # Counted from the file's text, not the parsed table, so the count cannot agree with itself.
            $text = Get-Content -LiteralPath $script:PortMatrixFile -Raw
            $block = [regex]::Match($text, '(?ms)^[ ]{4}Flows[ ]*=[ ]*@\((?<body>.*)^[ ]{4}\)')
            $block.Success | Should -BeTrue -Because 'the matrix must carry a Flows = @( ... ) block'
            $textIds = @([regex]::Matches($block.Groups['body'].Value, "(?m)^[ ]{12}Id[ ]*=[ ]*'(?<id>[^']+)'") | ForEach-Object { $_.Groups['id'].Value })

            $textIds.Count | Should -Be $script:DeclaredFlowCount
            @($textIds | Sort-Object -Unique).Count | Should -Be $textIds.Count -Because 'every flow id is unique'
            Compare-Object -ReferenceObject $textIds -DifferenceObject @($script:PortMatrixData.Flows | ForEach-Object { $_.Id }) | Should -BeNullOrEmpty

            $targets = @('mbx01.example.test', 'mbx02.example.test')
            $result = Invoke-TestNet -Run (New-TestNetRun -Targets $targets)
            $metrics = $result.findings[0].result.metrics

            foreach ($target in $targets) {
                $sent = @($script:NetRequests[$target] | ForEach-Object { $_['FlowId'] } | Sort-Object -Unique)
                $sent.Count | Should -Be $textIds.Count -Because "every flow must be handed to $target, not only some"
                Compare-Object -ReferenceObject $textIds -DifferenceObject $sent | Should -BeNullOrEmpty
            }
            @($metrics.probedFlowIds).Count | Should -Be $textIds.Count
            $metrics.flowsInMatrix | Should -Be $script:DeclaredFlowCount

            $rows = @($metrics.flows)
            Compare-Object -ReferenceObject $textIds -DifferenceObject @($rows | ForEach-Object { $_.FlowId } | Sort-Object -Unique) | Should -BeNullOrEmpty
            foreach ($row in $rows) {
                $row.Source | Should -BeIn $targets -Because 'every result names the target it was sent to'
                $row.ProbeOrigin | Should -Be (($row.Source -split '\.')[0].ToUpperInvariant()) -Because 'the origin is what the target reported while the probe ran'
                $row.ProbeOriginAddress | Should -Be '192.0.2.10:50000'
                $row.Destination | Should -Not -BeNullOrEmpty
                $row.Protocol | Should -Not -BeNullOrEmpty
                $row.Outcome | Should -BeIn @('Open', 'Closed', 'Unknown')
            }

            # Domain controllers are the directory's, global catalog ports go only to global catalogs,
            # peers are the other target, and DNS servers are the ones the target itself reported.
            @($rows | Where-Object { $_.DestinationRole -eq 'DomainController' } | ForEach-Object { $_.Destination } | Sort-Object -Unique) | Should -Be @('dc01.example.test', 'dc02.example.test')
            @($rows | Where-Object { $_.FlowId -like 'DcGlobalCatalog*' -and $_.Destination -eq 'dc02.example.test' }).Count | Should -Be 0
            @($rows | Where-Object { $_.Source -eq 'mbx01.example.test' -and $_.DestinationRole -eq 'PeerTarget' } | ForEach-Object { $_.Destination } | Sort-Object -Unique) | Should -Be @('mbx02.example.test')
            @($rows | Where-Object { $_.DestinationRole -eq 'DnsServer' } | ForEach-Object { $_.Destination } | Sort-Object -Unique) | Should -Be @('192.0.2.53')

            $section = @($result.sections | Where-Object { $_.key -eq 'deployment.target-port-flows' })[0]
            $section.totalRows | Should -Be $rows.Count
        }

        It 'reports a $null port as Unknown, never a pass, where the same flow with its port is Open' {
            $shipped = Invoke-TestNet -Run (New-TestNetRun -Targets @('mbx01.example.test'))
            $shippedRows = @($shipped.findings[0].result.metrics.flows)
            foreach ($row in @($shippedRows | Where-Object { $_.FlowId -eq 'DcLdapSsl' })) { $row.Outcome | Should -Be 'Open' }

            # The shipped table's one $null port is the WMI witness flow. It is measured, and stays Unknown.
            @($script:PortMatrixData.Flows | Where-Object { $null -eq $_.Port } | ForEach-Object { $_.Id }) | Should -Be @('WitnessWmi')
            $wmi = @($shippedRows | Where-Object { $_.FlowId -eq 'WitnessWmi' })
            $wmi.Count | Should -Be 1
            $wmi[0].Outcome | Should -Be 'Unknown'
            $wmi[0].Cause | Should -Match '^No Learn-documented port'
            $wmi[0].Measured | Should -Match 'remote ports 135' -Because 'what the target measured is still reported'

            $copy = Join-Path -Path $TestDrive -ChildPath 'PortMatrix.null.psd1'
            $text = Get-Content -LiteralPath $script:PortMatrixFile -Raw
            $nulled = [regex]::Replace($text, "(?ms)(Id\s*=\s*'DcLdapSsl'.*?Port\s*=\s*)636", '${1}$null')
            $nulled | Should -Not -Be $text -Because 'the copy must actually null the port'
            Set-Content -LiteralPath $copy -Value $nulled

            $result = Invoke-TestNet -Run (New-TestNetRun -Targets @('mbx01.example.test') -PortMatrixPath $copy)
            $rows = @($result.findings[0].result.metrics.flows | Where-Object { $_.FlowId -eq 'DcLdapSsl' })
            $rows.Count | Should -BeGreaterThan 0
            foreach ($row in $rows) {
                $row.Outcome | Should -Be 'Unknown'
                $row.Cause | Should -Match '^No Learn-documented port'
            }
            $result.findings[0].result.metrics.portMatrixPath | Should -Be $copy
            $result.findings[0].result.outcome | Should -Not -Be 'Compliant'
        }

        It 'takes domain controllers only from the directory, and a directory it cannot read costs only their flows' {
            $script:NetScenario = @{ DirectoryFails = $true }
            $result = Invoke-TestNet -Run (New-TestNetRun -Targets @('mbx01.example.test', 'mbx02.example.test'))
            $rows = @($result.findings[0].result.metrics.flows)

            $dcRows = @($rows | Where-Object { $_.DestinationRole -eq 'DomainController' })
            $dcRows.Count | Should -BeGreaterThan 0
            foreach ($row in $dcRows) {
                $row.Outcome | Should -Be 'Unknown'
                $row.Cause | Should -Match 'the directory could not be read \(test\)'
            }
            foreach ($row in @($rows | Where-Object { $_.DestinationRole -ne 'DomainController' -and $_.Probe -ne 'WmiConnect' })) {
                $row.Outcome | Should -Be 'Open' -Because "$($row.FlowId) does not depend on the directory"
            }
            Should -Invoke -ModuleName $script:ModuleName -CommandName Get-ExchDirectoryDomainController -Times 1 -Exactly
            $result.findings[0].result.rationale | Should -Match 'never supplied or guessed'
        }

        It 'records a Learn URL and a read date for every flow, and loads the matrix the way the prerequisite table loads' {
            [datetime]::ParseExact([string]$script:PortMatrixData.TableAsOf, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) | Should -BeOfType [datetime]

            foreach ($flow in $script:PortMatrixData.Flows) {
                foreach ($key in @('Id', 'SourceRole', 'DestinationRole', 'Port', 'Protocol', 'Probe', 'Purpose', 'Source', 'Read')) {
                    $flow.Contains($key) | Should -BeTrue -Because "$($flow.Id) must state $key, even if it is `$null"
                }
                $flow.SourceRole | Should -Be 'TargetServer'
                $flow.DestinationRole | Should -BeIn @('DomainController', 'WitnessServer', 'PeerTarget', 'DnsServer')
                $flow.Protocol | Should -BeIn @('TCP', 'UDP')
                $sources = @($flow.Source | Where-Object { $_ })
                $sources.Count | Should -BeGreaterThan 0 -Because "$($flow.Id) must name its source"
                foreach ($source in $sources) { $source | Should -Match '^https://learn\.microsoft\.com/' -Because "$($flow.Id) must be sourced from Microsoft Learn" }
                { [datetime]::ParseExact([string]$flow.Read, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) } | Should -Not -Throw -Because "$($flow.Id) must carry the date it was read"
                if ($null -eq $flow.Port) { [string]$flow.Note | Should -Not -BeNullOrEmpty -Because "$($flow.Id) has no port and must say why" }
            }

            $missing = Join-Path -Path $TestDrive -ChildPath 'no-such-port-matrix.psd1'
            { New-ExchRun -OutputRoot (Join-Path -Path $TestDrive -ChildPath 'out') -PortMatrixPath $missing } | Should -Throw -ExpectedMessage '*PortMatrixPath not found*'
            { & (Get-Module $script:ModuleName) { param($p) Get-ExchPortMatrix -Path $p } $missing } | Should -Throw -ExpectedMessage '*not found*'

            $override = & (Get-Module $script:ModuleName) { Get-ExchPortMatrixPath -Run ([pscustomobject]@{ PortMatrixPath = 'X:\override.psd1' }) }
            $override | Should -Be 'X:\override.psd1'
            $default = & (Get-Module $script:ModuleName) { Get-ExchPortMatrixPath -Run ([pscustomobject]@{ PortMatrixPath = '' }) }
            [System.IO.Path]::GetFullPath($default) | Should -Be ([System.IO.Path]::GetFullPath($script:PortMatrixFile))

            $matrix = & (Get-Module $script:ModuleName) { Get-ExchPortMatrix }
            $matrix.TableAsOf | Should -BeOfType [datetime]
            @($matrix.Flows).Count | Should -Be $script:DeclaredFlowCount
        }
    }

    Context 'Witness readiness (DEP.WIT-01)' {

        BeforeAll {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

            $script:WitCollectorFile = Join-Path -Path $script:CollectorRoot -ChildPath 'DEP.WIT-01.WitnessReadiness.ps1'
            $script:WitThresholds = & (Get-Module $script:ModuleName) { Import-ExchConfiguration }

            # How many checks the collector declares, written here rather than read from the module,
            # so a check dropped from the definitions or from the evaluation turns this context red.
            $script:DeclaredWitnessCheckCount = 13

            # A fictional SID for the Exchange Trusted Subsystem group. Every host name sits under the
            # reserved .test top-level domain (RFC 2606) and every address in TEST-NET-1 (RFC 5737).
            $script:TestEtsSid = 'S-1-5-21-1111111111-2222222222-3333333333-1117'

            function New-TestWitRun {
                param([string]$Witness = 'fsw01.example.test', [object[]]$Targets = @('mbx01.example.test', 'mbx02.example.test'), [string]$Directory = '', [switch]$NoDeployment)
                $folder = Join-Path -Path $TestDrive -ChildPath ('run-' + [guid]::NewGuid())
                New-Item -ItemType Directory -Path (Join-Path -Path $folder -ChildPath 'evidence') -Force | Out-Null
                $config = @{}
                foreach ($key in $script:WitThresholds.Keys) { $config[$key] = $script:WitThresholds[$key] }
                if (-not $NoDeployment) {
                    $config['Deployment'] = @{ TargetServers = $Targets; WitnessServer = $Witness }
                    if ($Directory) { $config['Deployment']['WitnessDirectory'] = $Directory }
                }
                [pscustomobject]@{
                    RunId = 'test'; TenantHint = 'test'; RunFolder = $folder
                    LogPath = (Join-Path -Path $folder -ChildPath 'run.jsonl'); ConfigPath = ''
                    Config = $config; Flags = @{}
                    Errors = (New-Object System.Collections.Generic.List[object])
                }
            }

            # What a witness that meets every prerequisite returns over CIM: a member server, Windows
            # Server build 20348, in the assessment's forest, running no Exchange service.
            function Get-TestWitCim {
                param([string]$ClassName)
                if ($script:WitScenario.Cim -and $script:WitScenario.Cim.ContainsKey($ClassName)) { return $script:WitScenario.Cim[$ClassName] }
                switch ($ClassName) {
                    'Win32_OperatingSystem' { [pscustomobject]@{ Caption = 'Test Server OS'; Version = '10.0.20348'; ProductType = 3; LastBootUpTime = [datetime]'2026-09-01' } }
                    'Win32_ComputerSystem'  { [pscustomobject]@{ PartOfDomain = $true; Domain = 'corp.example.test'; DomainRole = 3 } }
                    'Win32_NTDomain'        { [pscustomobject]@{ DomainName = 'CORP'; DNSForestName = 'example.test' } }
                    'Win32_Service'         { @() }
                    default                 { throw "Unexpected CIM class in test: $ClassName" }
                }
            }

            # ...and over WinRM: the File Server role installed, the firewall on for the domain profile
            # with both groups' inbound rules enabled, and the group in the local Administrators group.
            function New-TestWitReading {
                $admins = @([pscustomobject]@{ Sid = 'S-1-5-21-1000000000-2000000000-3000000000-500'; Path = 'WinNT://FSW01/Administrator' })
                if (-not $script:WitScenario.ContainsKey('EtsMember') -or $script:WitScenario.EtsMember) {
                    $admins += [pscustomobject]@{ Sid = $script:TestEtsSid; Path = 'WinNT://EXAMPLE/Exchange Trusted Subsystem' }
                }
                $reading = [pscustomobject]@{
                    FileServer          = [pscustomobject]@{ Name = 'FS-FileServer'; InstallState = 'Installed' }
                    FirewallProfiles    = @(
                        [pscustomobject]@{ Name = 'Domain'; Enabled = 'True' }
                        [pscustomobject]@{ Name = 'Private'; Enabled = 'True' }
                        [pscustomobject]@{ Name = 'Public'; Enabled = 'True' }
                    )
                    NetworkCategories   = @('DomainAuthenticated')
                    FirewallFileSharing = @([pscustomobject]@{ DisplayName = 'File and Printer Sharing (SMB-In)'; Enabled = 'True'; Direction = 'Inbound'; Profile = 'Domain' })
                    FirewallWmi         = @([pscustomobject]@{ DisplayName = 'Windows Management Instrumentation (WMI-In)'; Enabled = 'True'; Direction = 'Inbound'; Profile = 'Domain' })
                    Administrators      = $admins
                    Errors              = @{}
                }
                if ($script:WitScenario.ContainsKey('Reading')) { & $script:WitScenario.Reading $reading }
                $reading
            }

            function Invoke-TestWit {
                param($Run)
                & (Get-Module $script:ModuleName) { param($r) Invoke-ExchCollector_DEP_WIT_01_WitnessReadiness -Run $r } $Run
            }

            function Get-TestWitRow {
                param($Result, [string]$Check)
                @($Result.findings[0].result.metrics.checks | Where-Object { $_.Check -eq $Check })[0]
            }

            $script:WitScenario = @{}

            # Every remote and directory call is mocked: the name, CIM, WinRM, the assessment host's
            # forest and the directory search for the group.
            Mock -ModuleName $script:ModuleName Resolve-ExchTargetName {
                if (@($script:WitScenario.Unresolvable) -contains $Name) { return [pscustomobject]@{ Resolved = $false; Addresses = @(); Error = 'No such host is known (test)' } }
                $address = switch -Wildcard ($Name) { 'fsw01*' { '192.0.2.30' } 'mbx01*' { '192.0.2.11' } 'mbx02*' { '192.0.2.12' } default { '192.0.2.99' } }
                if ($script:WitScenario.Addresses -and $script:WitScenario.Addresses.ContainsKey($Name)) { $address = $script:WitScenario.Addresses[$Name] }
                [pscustomobject]@{ Resolved = $true; Addresses = @($address); Error = '' }
            }
            Mock -ModuleName $script:ModuleName Get-ExchTargetCimInstance {
                if (@($script:WitScenario.CimDown) -contains $ComputerName) { throw "CIM connection to $ComputerName refused (test)" }
                Get-TestWitCim -ClassName $ClassName
            }
            Mock -ModuleName $script:ModuleName Invoke-ExchTargetCommand {
                if (@($script:WitScenario.WinRmDown) -contains $ComputerName) { throw "WinRM connection to $ComputerName refused (test)" }
                New-TestWitReading
            }
            Mock -ModuleName $script:ModuleName Get-ExchRunForestName { 'example.test' }
            Mock -ModuleName $script:ModuleName Find-ExchDirectoryGroup {
                $scope = 'the global catalog gc01.example.test:3268 (test)'
                if ($script:WitScenario.Group -eq 'Throw') { throw 'the directory could not be read (test)' }
                if ($script:WitScenario.Group -eq 'Missing') { return [pscustomobject]@{ Scope = $scope; Groups = @() } }
                [pscustomobject]@{ Scope = $scope; Groups = @([pscustomobject]@{
                    Name = 'Exchange Trusted Subsystem'; Sid = $script:TestEtsSid
                    DistinguishedName = 'CN=Exchange Trusted Subsystem,OU=Microsoft Exchange Security Groups,DC=example,DC=test'
                }) }
            }
        }

        BeforeEach { $script:WitScenario = @{} }

        It 'registers DEP.WIT-01 as a well-formed row whose function resolves, under the existing switch and category' {
            $registry = & (Get-Module $script:ModuleName) { Get-ExchCollectorRegistry }
            $rows = @($registry | Where-Object { $_.Id -eq 'DEP.WIT-01' })
            $rows.Count | Should -Be 1

            $row = $rows[0]
            $row.Function | Should -Be 'Invoke-ExchCollector_DEP_WIT_01_WitnessReadiness'
            $row.Area | Should -Be 'Deployment'
            @($row.Requires).Count | Should -Be 0
            $row.Cloud | Should -BeFalse
            $row.SkipFlag | Should -Be 'SkipDeploymentChecks'

            $command = & (Get-Module $script:ModuleName) { param($n) Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue } $row.Function
            $command | Should -Not -BeNullOrEmpty
            $command.Parameters.Keys | Should -Contain 'Run'

            $switches = @((Get-Command -Name 'Invoke-ExchCollection' -Module $script:ModuleName).Parameters.Keys | Where-Object { $_ -like '*Deployment*' })
            @($switches) | Should -Be @('SkipDeploymentChecks') -Because 'the existing switch is reused, not a second one added'
            (& (Get-Module $script:ModuleName) { Get-ExchControlById -ControlId 'DEP.WIT-01' }).domain |
                Should -Be (& (Get-Module $script:ModuleName) { Get-ExchControlById -ControlId 'DEP.TGT-01' }).domain
        }

        It 'reports exactly one Unknown finding carrying the three P13 strings when Deployment.WitnessServer is empty - the expected state today - and contacts nothing' {
            # The shipped template carries an empty WitnessServer, so this is the path a run takes today.
            (Import-PowerShellDataFile -Path (Join-Path -Path $script:ToolRoot -ChildPath 'Config/Deployment.template.psd1')).Deployment.WitnessServer | Should -Be ''
            $template = & (Get-Module $script:ModuleName) { Get-ExchDeploymentTemplatePath }

            foreach ($run in @((New-TestWitRun -NoDeployment), (New-TestWitRun -Witness ''), (New-TestWitRun -Witness '   '))) {
                $result = Invoke-TestWit -Run $run
                @($result.findings).Count | Should -Be 1
                @($result.sections).Count | Should -Be 0
                $finding = $result.findings[0]
                $finding.controlId | Should -Be 'DEP.WIT-01'
                $finding.result.outcome | Should -Be 'Unknown'
                $finding.severity | Should -Be 'Info'
                $rationale = $finding.result.rationale
                $rationale.Contains($template) | Should -BeTrue -Because "the rationale must carry the template path $template"
                $rationale.Contains('New-ExchDeploymentConfig -Path .\Deployment.psd1') | Should -BeTrue
                $rationale.Contains('-ConfigPath .\Deployment.psd1') | Should -BeTrue
                $rationale | Should -Match 'expected state'
                $rationale | Should -Match 'not an error'
            }

            Should -Invoke -ModuleName $script:ModuleName -CommandName Resolve-ExchTargetName -Times 0 -Exactly
            Should -Invoke -ModuleName $script:ModuleName -CommandName Get-ExchTargetCimInstance -Times 0 -Exactly
            Should -Invoke -ModuleName $script:ModuleName -CommandName Invoke-ExchTargetCommand -Times 0 -Exactly
            Should -Invoke -ModuleName $script:ModuleName -CommandName Find-ExchDirectoryGroup -Times 0 -Exactly
        }

        It 'reports Trusted Subsystem state (a), the group not yet in the directory, as Unknown with the /PrepareAD cause - never as a failure' {
            $script:WitScenario = @{ Group = 'Missing' }
            $result = Invoke-TestWit -Run (New-TestWitRun)
            $row = Get-TestWitRow -Result $result -Check 'TrustedSubsystemGrant'

            $row.Outcome | Should -Be 'Unknown'
            $row.Measured | Should -Match '^state \(a\)'
            $row.Cause | Should -Match 'does not exist in the directory yet'
            $row.Cause | Should -Match '/PrepareAD'
            $row.Cause | Should -Match 'expected before Active Directory has been prepared'
            $row.Cause | Should -Match 'becomes checkable'
            $result.findings[0].result.metrics.trustedSubsystemState | Should -Be 'NotFound'
            $result.findings[0].result.outcome | Should -Be 'Unknown' -Because 'every other check passes, and a group that does not exist yet is not a failed prerequisite'
        }

        It 'reports Trusted Subsystem state (b), the group present but not a local Administrator, as NonCompliant' {
            $script:WitScenario = @{ EtsMember = $false }
            $result = Invoke-TestWit -Run (New-TestWitRun)
            $row = Get-TestWitRow -Result $result -Check 'TrustedSubsystemGrant'

            $row.Outcome | Should -Be 'NonCompliant'
            $row.Measured | Should -Match '^state \(b\)'
            $row.Measured | Should -Match ([regex]::Escape($script:TestEtsSid))
            $row.Cause | Should -Match 'nested group was not evaluated'
            $result.findings[0].result.metrics.trustedSubsystemState | Should -Be 'Found'
            $result.findings[0].result.outcome | Should -Be 'NonCompliant'
        }

        It 'reports Trusted Subsystem state (c), the group present and a local Administrator, as Compliant' {
            $result = Invoke-TestWit -Run (New-TestWitRun)
            $row = Get-TestWitRow -Result $result -Check 'TrustedSubsystemGrant'

            $row.Outcome | Should -Be 'Compliant'
            $row.Measured | Should -Match '^state \(c\)'
            $row.MechanismState | Should -Be 'Directory:Read WinRM:Read'
        }

        It 'gives the three Trusted Subsystem states three distinct outcomes, and a directory it cannot read a fourth cause, not one of them' {
            $outcomes = foreach ($scenario in @(@{ Group = 'Missing' }, @{ EtsMember = $false }, @{})) {
                $script:WitScenario = $scenario
                (Get-TestWitRow -Result (Invoke-TestWit -Run (New-TestWitRun)) -Check 'TrustedSubsystemGrant').Outcome
            }
            @($outcomes | Sort-Object -Unique).Count | Should -Be 3

            $script:WitScenario = @{ Group = 'Throw' }
            $row = Get-TestWitRow -Result (Invoke-TestWit -Run (New-TestWitRun)) -Check 'TrustedSubsystemGrant'
            $row.Outcome | Should -Be 'Unknown'
            $row.Cause | Should -Match 'could not be searched'
            $row.Measured | Should -Not -Match 'state \(a\)' -Because 'an unread directory is not evidence that the group is missing'
        }

        It 'reports a witness that is a domain controller as a finding, carrying the consequence Learn states' {
            $script:WitScenario = @{ Cim = @{ 'Win32_ComputerSystem' = [pscustomobject]@{ PartOfDomain = $true; Domain = 'corp.example.test'; DomainRole = 5 } } }
            $result = Invoke-TestWit -Run (New-TestWitRun -Witness 'dc01.example.test')
            $row = Get-TestWitRow -Result $result -Check 'NotDomainController'

            $row.Outcome | Should -Be 'NonCompliant'
            $row.Measured | Should -Be 'DomainRole 5'
            $row.Cause | Should -Match 'Builtin\\Administrators'
            $row.Cause | Should -Match 'unnecessary elevation of privileges'
            $result.findings[0].result.outcome | Should -Be 'NonCompliant'
            $result.findings[0].result.metrics.server.IsDomainController | Should -Be 'True'
        }

        It 'tells a witness that resolves but does not answer from one whose name does not resolve' {
            $script:WitScenario = @{ Unresolvable = @('typo01.example.test') }
            $typo = Invoke-TestWit -Run (New-TestWitRun -Witness 'typo01.example.test')
            $script:WitScenario = @{ CimDown = @('fsw01.example.test'); WinRmDown = @('fsw01.example.test') }
            $down = Invoke-TestWit -Run (New-TestWitRun)

            $typo.findings[0].result.metrics.status | Should -Be 'NameDoesNotResolve'
            $typo.findings[0].result.metrics.server.CimState | Should -Be 'NotAttempted'
            $typo.findings[0].result.rationale | Should -Match 'does not resolve on the assessment host'
            $typo.findings[0].result.rationale | Should -Not -Match 'answered neither'
            (Get-TestWitRow -Result $typo -Check 'NameResolves').Outcome | Should -Be 'Unknown'

            $down.findings[0].result.metrics.status | Should -Be 'Unreachable'
            $down.findings[0].result.metrics.server.Resolves | Should -Be 'True'
            $down.findings[0].result.rationale | Should -Match 'resolves \(192\.0\.2\.30\) but answered neither CIM nor WinRM'
            (Get-TestWitRow -Result $down -Check 'NameResolves').Outcome | Should -Be 'Compliant'
            $reachable = Get-TestWitRow -Result $down -Check 'Reachable'
            $reachable.Outcome | Should -Be 'Unknown'
            $reachable.Cause | Should -Match 'CIM: .*refused \(test\).*WinRM: .*refused \(test\)'

            Should -Invoke -ModuleName $script:ModuleName -CommandName Get-ExchTargetCimInstance -Times 0 -Exactly -ParameterFilter { $ComputerName -eq 'typo01.example.test' }
            Should -Invoke -ModuleName $script:ModuleName -CommandName Invoke-ExchTargetCommand -Times 0 -Exactly -ParameterFilter { $ComputerName -eq 'typo01.example.test' }
        }

        It 'degrades per mechanism: CIM checks stand when WinRM fails, and WinRM checks stand when CIM fails' {
            $cimChecks = @('DomainMember', 'SameForest', 'OperatingSystem', 'NotDomainController', 'NotExchangeServer')
            $winRmChecks = @('FileServerRole', 'FirewallFileAndPrinterSharing', 'FirewallWmi')

            $script:WitScenario = @{ WinRmDown = @('fsw01.example.test') }
            $result = Invoke-TestWit -Run (New-TestWitRun)
            foreach ($check in $cimChecks) { (Get-TestWitRow -Result $result -Check $check).Outcome | Should -Be 'Compliant' -Because "$check reads only CIM, which answered" }
            foreach ($check in $winRmChecks) {
                $row = Get-TestWitRow -Result $result -Check $check
                $row.Outcome | Should -Be 'Unknown'
                $row.Cause | Should -Match '^Not read: WinRM \(Invoke-Command\) to fsw01\.example\.test failed'
            }
            (Get-TestWitRow -Result $result -Check 'TrustedSubsystemGrant').Cause | Should -Match 'Administrators group was not read'

            $script:WitScenario = @{ CimDown = @('fsw01.example.test') }
            $result = Invoke-TestWit -Run (New-TestWitRun)
            foreach ($check in $cimChecks) { (Get-TestWitRow -Result $result -Check $check).Cause | Should -Match '^Not read: CIM on fsw01\.example\.test' }
            foreach ($check in $winRmChecks) { (Get-TestWitRow -Result $result -Check $check).Outcome | Should -Be 'Compliant' -Because "$check reads only WinRM, which answered" }
            $result.findings[0].result.metrics.status | Should -Be 'PartiallyRead'
        }

        It 'evaluates all 13 declared witness checks, one row each, counted from the collector file''s text' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WitCollectorFile, [ref]$null, [ref]$null)
            $definition = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ExchWitnessCheckDefinition' }, $true)
            $definition | Should -Not -BeNullOrEmpty
            $textKeys = @([regex]::Matches($definition.Extent.Text, "Key = '(?<key>\w+)'") | ForEach-Object { $_.Groups['key'].Value })
            $textKeys.Count | Should -Be $script:DeclaredWitnessCheckCount

            $result = Invoke-TestWit -Run (New-TestWitRun -Directory 'D:\DAGWitness')
            $rows = @($result.findings[0].result.metrics.checks)
            $rows.Count | Should -Be $script:DeclaredWitnessCheckCount
            Compare-Object -ReferenceObject $textKeys -DifferenceObject @($rows | ForEach-Object { $_.Check }) | Should -BeNullOrEmpty
            foreach ($row in $rows) { $row.Outcome | Should -Be 'Compliant' -Because "$($row.Check) passes on a witness that meets every prerequisite" }
            $result.findings[0].result.outcome | Should -Be 'Compliant'
            @($result.sections | Where-Object { $_.key -eq 'deployment.witness-checks' })[0].totalRows | Should -Be $script:DeclaredWitnessCheckCount
        }

        It 'reports a witness that is one of the target servers, by name or by address, as a DAG member' {
            $byName = Invoke-TestWit -Run (New-TestWitRun -Witness 'mbx02.example.test')
            (Get-TestWitRow -Result $byName -Check 'NotDagMember').Outcome | Should -Be 'NonCompliant'
            (Get-TestWitRow -Result $byName -Check 'NotDagMember').Measured | Should -Match 'mbx02\.example\.test \(same name\)'

            $script:WitScenario = @{ Addresses = @{ 'fsw01.example.test' = '192.0.2.12' } }
            $byAddress = Invoke-TestWit -Run (New-TestWitRun)
            $row = Get-TestWitRow -Result $byAddress -Check 'NotDagMember'
            $row.Outcome | Should -Be 'NonCompliant'
            $row.Measured | Should -Match 'mbx02\.example\.test \(same address 192\.0\.2\.12\)'
            $row.Cause | Should -Match 'can''t be a member of the DAG'
        }

        It 'reports an Exchange server witness for the reader, not as a failure, because Learn recommends one' {
            $script:WitScenario = @{ Cim = @{ 'Win32_Service' = @([pscustomobject]@{ Name = 'MSExchangeServiceHost'; StartMode = 'Auto'; State = 'Running' }) } }
            $result = Invoke-TestWit -Run (New-TestWitRun)
            $row = Get-TestWitRow -Result $result -Check 'NotExchangeServer'
            $row.Outcome | Should -Be 'PartiallyCompliant'
            $row.Cause | Should -Match 'recommends an Exchange server'
            $result.findings[0].result.outcome | Should -Be 'PartiallyCompliant'
        }

        It 'judges the firewall exceptions per profile in use: off is met, on with the group disabled fails, no rule of the group is Unknown' {
            $script:WitScenario = @{ Reading = { param($r) $r.FirewallProfiles = @([pscustomobject]@{ Name = 'Domain'; Enabled = 'False' }); $r.FirewallWmi = @() } }
            $off = Invoke-TestWit -Run (New-TestWitRun)
            (Get-TestWitRow -Result $off -Check 'FirewallWmi').Outcome | Should -Be 'Compliant'
            (Get-TestWitRow -Result $off -Check 'FirewallWmi').Measured | Should -Be 'Domain: Windows Firewall off'

            $script:WitScenario = @{ Reading = { param($r) $r.FirewallFileSharing[0].Enabled = 'False'; $r.FirewallWmi = @() } }
            $on = Invoke-TestWit -Run (New-TestWitRun)
            (Get-TestWitRow -Result $on -Check 'FirewallFileAndPrinterSharing').Outcome | Should -Be 'NonCompliant'
            (Get-TestWitRow -Result $on -Check 'FirewallWmi').Outcome | Should -Be 'Unknown'
            (Get-TestWitRow -Result $on -Check 'FirewallWmi').Cause | Should -Match 'may differ on the witness'
        }

        It 'checks a supplied witness directory as a local non-root full path, and reports it not applicable when none is supplied' {
            $test = { param($p) & (Get-Module $script:ModuleName) { param($x) Test-ExchWitnessDirectoryPath -Path $x } $p }
            (& $test 'D:\DAGWitness\DAG01').Valid | Should -BeTrue
            (& $test 'D:\').Reason | Should -Match 'root'
            (& $test '\\fs01.example.test\witness').Reason | Should -Match 'UNC'
            (& $test 'DAGWitness').Reason | Should -Match 'drive letter'
            (& $test 'D:\DAG|Witness').Valid | Should -BeFalse

            $none = Get-TestWitRow -Result (Invoke-TestWit -Run (New-TestWitRun)) -Check 'WitnessDirectory'
            $none.Outcome | Should -Be 'NotApplicable'
            $none.Cause | Should -Match 'DAGFileShareWitnesses'
            (Get-TestWitRow -Result (Invoke-TestWit -Run (New-TestWitRun -Directory 'D:\')) -Check 'WitnessDirectory').Outcome | Should -Be 'NonCompliant'
        }

        It 'records a Learn URL and read date for every witness and planned-name value, and says which values were measured' {
            foreach ($section in @('WitnessPrerequisites', 'PlannedNames')) {
                $entries = $script:WitThresholds[$section]
                $entries.Keys.Count | Should -BeGreaterThan 0
                foreach ($key in $entries.Keys) {
                    $entry = $entries[$key]
                    $entry.Contains('Value') | Should -BeTrue -Because "$section.$key must state a Value"
                    $sources = @($entry['Source'] | Where-Object { $_ })
                    $sources.Count | Should -BeGreaterThan 0 -Because "$section.$key must name its source"
                    foreach ($source in $sources) { $source | Should -Match '^https://learn\.microsoft\.com/' }
                    { [datetime]::ParseExact([string]$entry['Read'], 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) } | Should -Not -Throw
                    [string]$entry['Note'] | Should -Not -BeNullOrEmpty
                }
            }
            # The firewall group ids are not on Learn; the entries say where they were measured.
            foreach ($key in @('FileAndPrinterSharingFirewallGroup', 'WmiFirewallGroup')) {
                [string]$script:WitThresholds.WitnessPrerequisites[$key]['Measured'] | Should -Match 'dev VM'
            }
        }
    }

    Context 'Name availability (DEP.NAME-01)' {

        BeforeAll {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

            $script:NameCollectorFile = Join-Path -Path $script:CollectorRoot -ChildPath 'DEP.NAME-01.NameAvailability.ps1'
            $script:NameThresholds = & (Get-Module $script:ModuleName) { Import-ExchConfiguration }

            # How many checks the collector declares, written here rather than read from the module.
            $script:DeclaredNameCheckCount = 7

            function New-TestNameRun {
                param([object[]]$Targets = @('mbx01.example.test', 'mbx02.example.test'), [string]$Witness = 'fsw01.example.test',
                    [string]$DagName = 'DAG01', [object[]]$InternalNames = @('mail.example.test', 'autodiscover.example.test'), [switch]$NoDeployment)
                $folder = Join-Path -Path $TestDrive -ChildPath ('run-' + [guid]::NewGuid())
                New-Item -ItemType Directory -Path (Join-Path -Path $folder -ChildPath 'evidence') -Force | Out-Null
                $config = @{}
                foreach ($key in $script:NameThresholds.Keys) { $config[$key] = $script:NameThresholds[$key] }
                if (-not $NoDeployment) { $config['Deployment'] = @{ TargetServers = $Targets; WitnessServer = $Witness; DagName = $DagName; InternalNames = $InternalNames } }
                [pscustomobject]@{
                    RunId = 'test'; TenantHint = 'test'; RunFolder = $folder
                    LogPath = (Join-Path -Path $folder -ChildPath 'run.jsonl'); ConfigPath = ''
                    Config = $config; Flags = @{}
                    Errors = (New-Object System.Collections.Generic.List[object])
                }
            }

            function New-TestComputer {
                param([string]$Name, [string]$DnsHostName, [string]$Ou = 'Servers')
                [pscustomobject]@{ Name = $Name; SamAccountName = "$Name`$"; DNSHostName = $DnsHostName; DistinguishedName = "CN=$Name,OU=$Ou,DC=example,DC=test" }
            }

            function Invoke-TestName {
                param($Run)
                & (Get-Module $script:ModuleName) { param($r) Invoke-ExchCollector_DEP_NAME_01_NameAvailability -Run $r } $Run
            }

            function Get-TestNameRow {
                param($Result, [string]$Role, [string]$Check, [string]$Name = '')
                @($Result.findings[0].result.metrics.checks | Where-Object { $_.Role -eq $Role -and $_.Check -eq $Check -and (-not $Name -or $_.Name -eq $Name) })[0]
            }

            $script:NameScenario = @{}

            # Every directory and DNS call is mocked. By default a server name is held by its own
            # computer account, the DAG name by nothing, and no internal name exists in DNS.
            Mock -ModuleName $script:ModuleName Find-ExchDirectoryComputer {
                if ($script:NameScenario.DirectoryFails) { throw 'the directory could not be read (test)' }
                $scope = 'the global catalog gc01.example.test:3268 (test)'
                if ($script:NameScenario.Computers -and $script:NameScenario.Computers.ContainsKey($Name)) { return [pscustomobject]@{ Scope = $scope; Computers = @($script:NameScenario.Computers[$Name]) } }
                if ($Fqdn) { return [pscustomobject]@{ Scope = $scope; Computers = @(New-TestComputer -Name $Name.ToUpperInvariant() -DnsHostName $Fqdn) } }
                [pscustomobject]@{ Scope = $scope; Computers = @() }
            }
            Mock -ModuleName $script:ModuleName Find-ExchDirectoryExchangeObject {
                if ($script:NameScenario.DirectoryFails) { throw 'the directory could not be read (test)' }
                $scope = 'CN=Microsoft Exchange,CN=Services,CN=Configuration,DC=example,DC=test'
                if ($script:NameScenario.NoExchangeOrganization) { return [pscustomobject]@{ Scope = $scope; ContainerExists = $false; Objects = @() } }
                $objects = @()
                if ($script:NameScenario.ExchangeObjects -and $script:NameScenario.ExchangeObjects.ContainsKey($Name)) { $objects = @($script:NameScenario.ExchangeObjects[$Name]) }
                [pscustomobject]@{ Scope = $scope; ContainerExists = $true; Objects = $objects }
            }
            Mock -ModuleName $script:ModuleName Resolve-ExchPlannedDnsName {
                if ($script:NameScenario.Dns -and $script:NameScenario.Dns.ContainsKey($Name)) { return $script:NameScenario.Dns[$Name] }
                [pscustomobject]@{ Status = 'NameDoesNotExist'; Records = @(); Error = '' }
            }
        }

        BeforeEach { $script:NameScenario = @{} }

        It 'registers DEP.NAME-01 as a well-formed row whose function resolves, under the existing switch and category' {
            $rows = @(& (Get-Module $script:ModuleName) { Get-ExchCollectorRegistry } | Where-Object { $_.Id -eq 'DEP.NAME-01' })
            $rows.Count | Should -Be 1
            $rows[0].Function | Should -Be 'Invoke-ExchCollector_DEP_NAME_01_NameAvailability'
            $rows[0].Area | Should -Be 'Deployment'
            @($rows[0].Requires).Count | Should -Be 0
            $rows[0].Cloud | Should -BeFalse
            $rows[0].SkipFlag | Should -Be 'SkipDeploymentChecks'
            (& (Get-Module $script:ModuleName) { param($n) Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue } $rows[0].Function).Parameters.Keys | Should -Contain 'Run'
            (& (Get-Module $script:ModuleName) { Get-ExchControlById -ControlId 'DEP.NAME-01' }).domain |
                Should -Be (& (Get-Module $script:ModuleName) { Get-ExchControlById -ControlId 'DEP.TGT-01' }).domain
        }

        It 'reports exactly one Unknown finding carrying the three P13 strings when no planned name was supplied, and contacts nothing' {
            $template = & (Get-Module $script:ModuleName) { Get-ExchDeploymentTemplatePath }
            foreach ($run in @((New-TestNameRun -NoDeployment), (New-TestNameRun -Targets @() -Witness '' -DagName '' -InternalNames @()), (New-TestNameRun -Targets @('  ') -Witness ' ' -DagName '' -InternalNames @('')))) {
                $result = Invoke-TestName -Run $run
                @($result.findings).Count | Should -Be 1
                @($result.sections).Count | Should -Be 0
                $finding = $result.findings[0]
                $finding.controlId | Should -Be 'DEP.NAME-01'
                $finding.result.outcome | Should -Be 'Unknown'
                $finding.result.rationale.Contains($template) | Should -BeTrue
                $finding.result.rationale.Contains('New-ExchDeploymentConfig -Path .\Deployment.psd1') | Should -BeTrue
                $finding.result.rationale.Contains('-ConfigPath .\Deployment.psd1') | Should -BeTrue
                $finding.result.rationale | Should -Match 'does not mean the names are free'
            }
            Should -Invoke -ModuleName $script:ModuleName -CommandName Find-ExchDirectoryComputer -Times 0 -Exactly
            Should -Invoke -ModuleName $script:ModuleName -CommandName Find-ExchDirectoryExchangeObject -Times 0 -Exactly
            Should -Invoke -ModuleName $script:ModuleName -CommandName Resolve-ExchPlannedDnsName -Times 0 -Exactly
        }

        It 'reports a DAG name already held by a computer object as in use, naming what holds it' {
            $script:NameScenario = @{ Computers = @{ 'DAG01' = @(New-TestComputer -Name 'DAG01' -DnsHostName '' -Ou 'Clusters') } }
            $result = Invoke-TestName -Run (New-TestNameRun)
            $row = Get-TestNameRow -Result $result -Role 'DagName' -Check 'ComputerObject'

            $row.Outcome | Should -Be 'NonCompliant'
            $row.Status | Should -Be 'InUse'
            $row.HeldBy | Should -Match 'CN=DAG01,OU=Clusters,DC=example,DC=test'
            $result.findings[0].result.outcome | Should -Be 'NonCompliant'
            $result.findings[0].result.rationale | Should -Match 'already in use.*CN=DAG01,OU=Clusters'
        }

        It 'reports an internal name that already resolves as in use, naming the records, and not as an error' {
            $script:NameScenario = @{ Dns = @{ 'mail.example.test' = [pscustomobject]@{ Status = 'Resolves'; Records = @('A mail.example.test 192.0.2.80'); Error = '' } } }
            $result = Invoke-TestName -Run (New-TestNameRun)
            $row = Get-TestNameRow -Result $result -Role 'InternalName' -Check 'DnsRecord' -Name 'mail.example.test'

            $row.Outcome | Should -Be 'PartiallyCompliant'
            $row.Status | Should -Be 'InUse'
            $row.HeldBy | Should -Be 'A mail.example.test 192.0.2.80'
            (Get-TestNameRow -Result $result -Role 'InternalName' -Check 'DnsRecord' -Name 'autodiscover.example.test').Outcome | Should -Be 'Compliant'
            $result.findings[0].result.outcome | Should -Be 'PartiallyCompliant'
            $result.findings[0].result.rationale | Should -Match '192\.0\.2\.80'
        }

        It 'treats a server name held by its own computer account as free, and one held by another computer or twice as in use' {
            $own = Invoke-TestName -Run (New-TestNameRun)
            foreach ($name in @('mbx01.example.test', 'mbx02.example.test')) {
                $row = Get-TestNameRow -Result $own -Role 'TargetServer' -Check 'ComputerObject' -Name $name
                $row.Outcome | Should -Be 'Compliant'
                $row.Status | Should -Be 'OwnAccount'
            }

            $script:NameScenario = @{ Computers = @{
                'mbx02' = @(New-TestComputer -Name 'MBX02' -DnsHostName 'mbx02.other.test')
                'fsw01' = @((New-TestComputer -Name 'FSW01' -DnsHostName 'fsw01.example.test'), (New-TestComputer -Name 'FSW01' -DnsHostName 'fsw01.child.example.test' -Ou 'Old'))
            } }
            $held = Invoke-TestName -Run (New-TestNameRun)
            $another = Get-TestNameRow -Result $held -Role 'TargetServer' -Check 'ComputerObject' -Name 'mbx02.example.test'
            $another.Outcome | Should -Be 'NonCompliant'
            $another.Status | Should -Be 'HeldByAnother'
            $another.Cause | Should -Match 'mbx02\.other\.test'
            $twice = Get-TestNameRow -Result $held -Role 'WitnessServer' -Check 'ComputerObject'
            $twice.Outcome | Should -Be 'NonCompliant'
            $twice.Status | Should -Be 'Duplicate'
        }

        It 'evaluates all 7 declared name checks - 1 per target server, 1 for the witness, 4 for the DAG name and 1 per internal name' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:NameCollectorFile, [ref]$null, [ref]$null)
            $definition = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ExchNameCheckDefinition' }, $true)
            $declared = @([regex]::Matches($definition.Extent.Text, "Role = '(?<role>\w+)';\s+Check = '(?<check>\w+)'") | ForEach-Object { [pscustomobject]@{ Role = $_.Groups['role'].Value; Check = $_.Groups['check'].Value } })
            $declared.Count | Should -Be $script:DeclaredNameCheckCount
            $perRole = @{}
            foreach ($group in ($declared | Group-Object -Property Role)) { $perRole[$group.Name] = $group.Count }
            $perRole['TargetServer'] | Should -Be 1
            $perRole['WitnessServer'] | Should -Be 1
            $perRole['DagName'] | Should -Be 4
            $perRole['InternalName'] | Should -Be 1

            $targets = @('mbx01.example.test', 'mbx02.example.test')
            $internal = @('mail.example.test', 'autodiscover.example.test', 'owa.example.test')
            $result = Invoke-TestName -Run (New-TestNameRun -Targets $targets -InternalNames $internal)
            $rows = @($result.findings[0].result.metrics.checks)
            $expected = ($targets.Count * $perRole['TargetServer']) + $perRole['WitnessServer'] + $perRole['DagName'] + ($internal.Count * $perRole['InternalName'])
            $rows.Count | Should -Be $expected
            foreach ($item in $declared) {
                $names = switch ($item.Role) { 'TargetServer' { $targets } 'WitnessServer' { @('fsw01.example.test') } 'DagName' { @('DAG01') } 'InternalName' { $internal } }
                foreach ($name in $names) {
                    @($rows | Where-Object { $_.Role -eq $item.Role -and $_.Check -eq $item.Check -and $_.Name -eq $name }).Count | Should -Be 1 -Because "$($item.Role) $name needs its $($item.Check) check"
                }
            }
            foreach ($row in $rows) { $row.Outcome | Should -Be 'Compliant' -Because "$($row.Role) $($row.Name) $($row.Check) is free in the mocks" }
        }

        It 'states what the instruments cannot see, even when every name is free, so an absence is not read as proof' {
            $result = Invoke-TestName -Run (New-TestNameRun)
            $result.findings[0].result.outcome | Should -Be 'Compliant'
            $rationale = $result.findings[0].result.rationale
            $rationale | Should -Match 'cannot see'
            $rationale | Should -Match 'another forest'
            $rationale | Should -Match 'resolver that was not queried'
            $rationale | Should -Match 'not proof that a name is free'
            $rationale | Should -Match 'gc01\.example\.test:3268'
        }

        It 'reports a DAG name that is too long, holds a disallowed character or only numerals as invalid' {
            $long = Invoke-TestName -Run (New-TestNameRun -DagName 'DAG-NAME-TOO-LONG')
            (Get-TestNameRow -Result $long -Role 'DagName' -Check 'NameLength').Outcome | Should -Be 'NonCompliant'
            (Get-TestNameRow -Result $long -Role 'DagName' -Check 'NameCharacters').Outcome | Should -Be 'Compliant'

            $underscore = Invoke-TestName -Run (New-TestNameRun -DagName 'DAG_01')
            (Get-TestNameRow -Result $underscore -Role 'DagName' -Check 'NameCharacters').Outcome | Should -Be 'NonCompliant'
            (Get-TestNameRow -Result $underscore -Role 'DagName' -Check 'NameLength').Outcome | Should -Be 'Compliant'

            (Get-TestNameRow -Result (Invoke-TestName -Run (New-TestNameRun -DagName '12345')) -Role 'DagName' -Check 'NameCharacters').Cause | Should -Match 'only numerals'
        }

        It 'reports a DAG name held by an Exchange configuration object as in use, and an unprepared directory as nothing holding it' {
            $script:NameScenario = @{ ExchangeObjects = @{ 'DAG01' = @([pscustomobject]@{ DistinguishedName = 'CN=DAG01,CN=Database Availability Groups,CN=Test,CN=Microsoft Exchange,CN=Services,CN=Configuration,DC=example,DC=test'; ObjectClass = 'msExchMDBAvailabilityGroup' }) } }
            $taken = Get-TestNameRow -Result (Invoke-TestName -Run (New-TestNameRun)) -Role 'DagName' -Check 'ExistingExchangeObject'
            $taken.Outcome | Should -Be 'NonCompliant'
            $taken.HeldBy | Should -Match 'CN=Database Availability Groups'

            $script:NameScenario = @{ NoExchangeOrganization = $true }
            $unprepared = Get-TestNameRow -Result (Invoke-TestName -Run (New-TestNameRun)) -Role 'DagName' -Check 'ExistingExchangeObject'
            $unprepared.Outcome | Should -Be 'Compliant'
            $unprepared.Status | Should -Be 'NoExchangeOrganization'
        }

        It 'reports the directory checks Unknown when the directory cannot be read, and still checks DNS' {
            $script:NameScenario = @{ DirectoryFails = $true }
            $result = Invoke-TestName -Run (New-TestNameRun)
            $directoryRows = @($result.findings[0].result.metrics.checks | Where-Object { $_.Instrument -eq 'Directory' })
            $directoryRows.Count | Should -Be 5
            foreach ($row in $directoryRows) {
                $row.Outcome | Should -Be 'Unknown'
                $row.Cause | Should -Match 'the directory could not be read \(test\)'
            }
            foreach ($row in @($result.findings[0].result.metrics.checks | Where-Object { $_.Instrument -eq 'DNS' })) { $row.Outcome | Should -Be 'Compliant' }
            $result.findings[0].result.outcome | Should -Be 'Unknown'
        }

        It 'checks the names that were supplied and names each key that was not' {
            $result = Invoke-TestName -Run (New-TestNameRun -Targets @() -Witness '' -InternalNames @())
            $rows = @($result.findings[0].result.metrics.checks)
            @($rows | Where-Object { $_.Role -eq 'DagName' }).Count | Should -Be 4
            @($rows | Where-Object { $_.Status -eq 'NotSupplied' } | ForEach-Object { $_.Role }) | Should -Be @('TargetServers', 'WitnessServer', 'InternalNames')
            $result.findings[0].result.outcome | Should -Be 'Unknown'
            $result.findings[0].result.rationale | Should -Match 'Deployment\.TargetServers, Deployment\.WitnessServer, Deployment\.InternalNames were not supplied'
            $result.findings[0].result.rationale | Should -Match ([regex]::Escape('New-ExchDeploymentConfig -Path .\Deployment.psd1'))
        }
    }

    Context 'Volume readiness (DEP.VOL-01)' {

        BeforeAll {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

            $script:VolCollectorFile = Join-Path -Path $script:CollectorRoot -ChildPath 'DEP.VOL-01.VolumeReadiness.ps1'
            $script:VolThresholds = & (Get-Module $script:ModuleName) { Import-ExchConfiguration }

            # How many checks the collector declares, written here rather than read from the module:
            # four on each supplied volume, and one per target comparing the two volumes.
            $script:DeclaredVolumeChecksPerVolume = 4
            $script:DeclaredVolumeChecksPerTarget = 1

            # A synthetic run. Host names sit under the reserved .test top-level domain (RFC 2606),
            # addresses in TEST-NET-1 (RFC 5737), and the volume GUIDs are fictional. The free-space
            # minimums are supplied through the real -ConfigPath merge, overriding Value alone;
            # -ShippedThresholds keeps the shipped $null.
            function New-TestVolRun {
                param([object[]]$Targets = @('mbx01.example.test', 'mbx02.example.test'), [string]$DatabaseVolume = 'D:', [string]$LogVolume = 'E:',
                    [object]$DatabaseMinimumFreeGB = 100, [object]$LogMinimumFreeGB = 20, [switch]$ShippedThresholds, [switch]$NoDeployment)
                $folder = Join-Path -Path $TestDrive -ChildPath ('run-' + [guid]::NewGuid())
                New-Item -ItemType Directory -Path (Join-Path -Path $folder -ChildPath 'evidence') -Force | Out-Null
                $config = @{}
                foreach ($key in $script:VolThresholds.Keys) { $config[$key] = $script:VolThresholds[$key] }
                if (-not $ShippedThresholds) {
                    $override = @{ DeploymentVolumes = @{ DatabaseVolumeMinimumFreeGB = @{ Value = $DatabaseMinimumFreeGB }; LogVolumeMinimumFreeGB = @{ Value = $LogMinimumFreeGB } } }
                    $config = & (Get-Module $script:ModuleName) { param($b, $o) Merge-ExchConfigTable -Base $b -Override $o } $config $override
                }
                if (-not $NoDeployment) { $config['Deployment'] = @{ TargetServers = $Targets; DatabaseVolume = $DatabaseVolume; LogVolume = $LogVolume; DagName = 'DAG01' } }
                [pscustomobject]@{
                    RunId = 'test'; TenantHint = 'test'; RunFolder = $folder
                    LogPath = (Join-Path -Path $folder -ChildPath 'run.jsonl'); ConfigPath = ''
                    Config = $config; Flags = @{}
                    Errors = (New-Object System.Collections.Generic.List[object])
                }
            }

            # What a target returns from Win32_Volume by default: the system volume, a 1 TB NTFS
            # database volume and a 256 GB ReFS log volume, both formatted with 64 KB units.
            function Get-TestVolume {
                if ($script:VolScenario.ContainsKey('Volumes')) { return $script:VolScenario.Volumes }
                [pscustomobject]@{ Name = 'C:\'; DeviceID = '\\?\Volume{00000000-0000-0000-0000-00000000000c}\'; DriveLetter = 'C:'; FileSystem = 'NTFS'; Capacity = 200GB; FreeSpace = 100GB; BlockSize = 4096 }
                [pscustomobject]@{ Name = 'D:\'; DeviceID = '\\?\Volume{00000000-0000-0000-0000-00000000000d}\'; DriveLetter = 'D:'; FileSystem = 'NTFS'; Capacity = 1024GB; FreeSpace = 900GB; BlockSize = 65536 }
                [pscustomobject]@{ Name = 'E:\'; DeviceID = '\\?\Volume{00000000-0000-0000-0000-00000000000e}\'; DriveLetter = 'E:'; FileSystem = 'ReFS'; Capacity = 256GB; FreeSpace = 200GB; BlockSize = 65536 }
            }

            function Invoke-TestVol {
                param($Run)
                & (Get-Module $script:ModuleName) { param($r) Invoke-ExchCollector_DEP_VOL_01_VolumeReadiness -Run $r } $Run
            }

            function Get-TestVolRow {
                param($Result, [string]$Server = 'mbx01.example.test', [string]$Role, [string]$Check)
                @($Result.findings[0].result.metrics.checks | Where-Object { $_.Server -eq $Server -and $_.Role -eq $Role -and $_.Check -eq $Check })[0]
            }

            $script:VolScenario = @{}

            # Every remote call is mocked. The collector reaches a target only through name resolution
            # and CIM; WinRM throws, so any use of it would surface.
            Mock -ModuleName $script:ModuleName Resolve-ExchTargetName {
                if (@($script:VolScenario.Unresolvable) -contains $Name) { return [pscustomobject]@{ Resolved = $false; Addresses = @(); Error = 'No such host is known (test)' } }
                [pscustomobject]@{ Resolved = $true; Addresses = @('192.0.2.10'); Error = '' }
            }
            Mock -ModuleName $script:ModuleName Get-ExchTargetCimInstance {
                if (@($script:VolScenario.CimDown) -contains $ComputerName) { throw "CIM connection to $ComputerName refused (test)" }
                if ($ClassName -ne 'Win32_Volume') { throw "Unexpected CIM class in test: $ClassName" }
                Get-TestVolume
            }
            Mock -ModuleName $script:ModuleName Invoke-ExchTargetCommand { throw 'DEP.VOL-01 must not use WinRM (test)' }
        }

        BeforeEach { $script:VolScenario = @{} }

        It 'registers DEP.VOL-01 as a well-formed row whose function resolves, under the existing switch and category' {
            $rows = @(& (Get-Module $script:ModuleName) { Get-ExchCollectorRegistry } | Where-Object { $_.Id -eq 'DEP.VOL-01' })
            $rows.Count | Should -Be 1
            $rows[0].Function | Should -Be 'Invoke-ExchCollector_DEP_VOL_01_VolumeReadiness'
            $rows[0].Area | Should -Be 'Deployment'
            @($rows[0].Requires).Count | Should -Be 0
            $rows[0].Cloud | Should -BeFalse
            $rows[0].SkipFlag | Should -Be 'SkipDeploymentChecks'
            (& (Get-Module $script:ModuleName) { param($n) Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue } $rows[0].Function).Parameters.Keys | Should -Contain 'Run'
            (& (Get-Module $script:ModuleName) { Get-ExchControlById -ControlId 'DEP.VOL-01' }).domain |
                Should -Be (& (Get-Module $script:ModuleName) { Get-ExchControlById -ControlId 'DEP.TGT-01' }).domain
        }

        It 'reports exactly one Unknown finding naming the missing keys and carrying the three P13 strings when neither volume was supplied, and contacts nothing' {
            $template = & (Get-Module $script:ModuleName) { Get-ExchDeploymentTemplatePath }
            foreach ($run in @((New-TestVolRun -NoDeployment), (New-TestVolRun -DatabaseVolume '' -LogVolume ''), (New-TestVolRun -DatabaseVolume '   ' -LogVolume ''))) {
                $result = Invoke-TestVol -Run $run
                @($result.findings).Count | Should -Be 1
                @($result.sections).Count | Should -Be 0
                $finding = $result.findings[0]
                $finding.controlId | Should -Be 'DEP.VOL-01'
                $finding.result.outcome | Should -Be 'Unknown'
                $finding.severity | Should -Be 'Info'
                $rationale = $finding.result.rationale
                $rationale | Should -Match 'Deployment\.DatabaseVolume, Deployment\.LogVolume are empty or absent'
                $rationale.Contains($template) | Should -BeTrue -Because "the rationale must carry the template path $template"
                $rationale.Contains('New-ExchDeploymentConfig -Path .\Deployment.psd1') | Should -BeTrue
                $rationale.Contains('-ConfigPath .\Deployment.psd1') | Should -BeTrue
                $rationale | Should -Match 'does not mean the volumes are ready'
            }

            $noTargets = (Invoke-TestVol -Run (New-TestVolRun -Targets @())).findings[0].result.rationale
            $noTargets | Should -Match 'Deployment\.TargetServers is empty or absent'
            $noTargets | Should -Not -Match 'Deployment\.DatabaseVolume'

            Should -Invoke -ModuleName $script:ModuleName -CommandName Resolve-ExchTargetName -Times 0 -Exactly
            Should -Invoke -ModuleName $script:ModuleName -CommandName Get-ExchTargetCimInstance -Times 0 -Exactly
            Should -Invoke -ModuleName $script:ModuleName -CommandName Invoke-ExchTargetCommand -Times 0 -Exactly
        }

        It 'checks the volume that was supplied and names the key that was not, never comparing against a volume nobody named' {
            $result = Invoke-TestVol -Run (New-TestVolRun -Targets @('mbx01.example.test') -LogVolume '')
            $rows = @($result.findings[0].result.metrics.checks)
            $databaseRows = @($rows | Where-Object { $_.Role -eq 'DatabaseVolume' })
            $databaseRows.Count | Should -Be $script:DeclaredVolumeChecksPerVolume
            foreach ($row in $databaseRows) { $row.Outcome | Should -Be 'Compliant' -Because "$($row.Check) on D: is met in the mocks" }
            @($rows | Where-Object { $_.Role -eq 'LogVolume' }).Count | Should -Be 0

            $compare = Get-TestVolRow -Result $result -Role 'DatabaseVolume+LogVolume' -Check 'DistinctVolumes'
            $compare.Outcome | Should -Be 'Unknown'
            $compare.Cause | Should -Match 'Deployment\.LogVolume was not supplied'
            $result.findings[0].result.outcome | Should -Be 'Unknown'
            $result.findings[0].result.rationale | Should -Match 'Deployment\.LogVolume was not supplied'
            $result.findings[0].result.rationale.Contains('New-ExchDeploymentConfig -Path .\Deployment.psd1') | Should -BeTrue
        }

        It 'reports a named volume that is not mounted as absent, names the volume a folder path would fall on, and judges nothing in its place' {
            $result = Invoke-TestVol -Run (New-TestVolRun -Targets @('mbx01.example.test') -DatabaseVolume 'D:\ExchangeDatabases' -LogVolume 'L:')

            $database = Get-TestVolRow -Result $result -Role 'DatabaseVolume' -Check 'VolumeExists'
            $database.Outcome | Should -Be 'NonCompliant'
            $database.Measured | Should -Match 'falls on D:\\$'
            $database.Cause | Should -Match 'not the volume Deployment\.DatabaseVolume names'
            $log = Get-TestVolRow -Result $result -Role 'LogVolume' -Check 'VolumeExists'
            $log.Outcome | Should -Be 'NonCompliant'
            $log.Cause | Should -Match 'No volume is mounted at L:\\ on mbx01\.example\.test'

            foreach ($role in @('DatabaseVolume', 'LogVolume')) {
                foreach ($check in @('FreeSpace', 'FileSystem', 'AllocationUnitSize')) {
                    $row = Get-TestVolRow -Result $result -Role $role -Check $check
                    $row.Outcome | Should -Be 'Unknown' -Because "$role $check has no volume to measure, and D: must not be judged in its place"
                    $row.Cause | Should -Match '^Not measured: no volume is mounted'
                }
            }
            (Get-TestVolRow -Result $result -Role 'DatabaseVolume+LogVolume' -Check 'DistinctVolumes').Cause | Should -Match '^Not compared'
            $result.findings[0].result.outcome | Should -Be 'NonCompliant'
            $result.findings[0].result.rationale | Should -Match '2 volume checks failed'
        }

        It 'reports free space below the operator''s minimum as failed, and the shipped $null minimum as Unknown naming the key - never as a pass' {
            $below = Invoke-TestVol -Run (New-TestVolRun -Targets @('mbx01.example.test') -DatabaseMinimumFreeGB 1000)
            $row = Get-TestVolRow -Result $below -Role 'DatabaseVolume' -Check 'FreeSpace'
            $row.Outcome | Should -Be 'NonCompliant'
            $row.Measured | Should -Be '900 GB free'
            $row.Required | Should -Match '^>= 1000 GB free'
            (Get-TestVolRow -Result $below -Role 'LogVolume' -Check 'FreeSpace').Outcome | Should -Be 'Compliant'
            $below.findings[0].result.outcome | Should -Be 'NonCompliant'

            $shipped = Invoke-TestVol -Run (New-TestVolRun -Targets @('mbx01.example.test') -ShippedThresholds)
            foreach ($role in @('DatabaseVolume', 'LogVolume')) {
                $row = Get-TestVolRow -Result $shipped -Role $role -Check 'FreeSpace'
                $row.Outcome | Should -Be 'Unknown'
                $row.Cause | Should -Match ('^No value: DeploymentVolumes\.{0}MinimumFreeGB' -f $role)
                $row.Measured | Should -Match 'GB free$' -Because 'what was measured is still reported'
            }
            $shipped.findings[0].result.outcome | Should -Be 'Unknown'
        }

        It 'reports database and log on the same volume as the same volume, quoting what Learn states for each architecture, and does not fail it' {
            foreach ($pair in @(@('D:', 'd:\'), @('D:\', 'D:'))) {
                $result = Invoke-TestVol -Run (New-TestVolRun -Targets @('mbx01.example.test') -DatabaseVolume $pair[0] -LogVolume $pair[1])
                $row = Get-TestVolRow -Result $result -Role 'DatabaseVolume+LogVolume' -Check 'DistinctVolumes'
                $row.Outcome | Should -Be 'PartiallyCompliant'
                $row.Measured | Should -Match '^same volume'
                $row.Cause | Should -Match 'Learn states no requirement either way'
                $row.Cause | Should -Match 'different volumes backed by different physical disks'
                $row.Cause | Should -Match "Isolation of logs and databases isn't required"
                $row.Cause | Should -Match 'Reported for the reader to judge, not failed'
                @($result.findings[0].result.metrics.sameVolumeServers) | Should -Be @('mbx01.example.test')
                $result.findings[0].result.outcome | Should -Be 'PartiallyCompliant'
            }

            # Two different paths that Win32_Volume reports as one DeviceID are one volume.
            $script:VolScenario = @{ Volumes = @(
                [pscustomobject]@{ Name = 'D:\'; DeviceID = '\\?\Volume{00000000-0000-0000-0000-00000000000d}\'; FileSystem = 'NTFS'; FreeSpace = 900GB; BlockSize = 65536 }
                [pscustomobject]@{ Name = 'C:\Mounts\Logs\'; DeviceID = '\\?\Volume{00000000-0000-0000-0000-00000000000d}\'; FileSystem = 'NTFS'; FreeSpace = 900GB; BlockSize = 65536 }
            ) }
            $byDevice = Invoke-TestVol -Run (New-TestVolRun -Targets @('mbx01.example.test') -LogVolume 'C:\Mounts\Logs')
            (Get-TestVolRow -Result $byDevice -Role 'DatabaseVolume+LogVolume' -Check 'DistinctVolumes').Measured | Should -Match '^same volume'
            $script:VolScenario = @{}

            $distinct = Invoke-TestVol -Run (New-TestVolRun -Targets @('mbx01.example.test'))
            $row = Get-TestVolRow -Result $distinct -Role 'DatabaseVolume+LogVolume' -Check 'DistinctVolumes'
            $row.Outcome | Should -Be 'Compliant'
            $row.Measured | Should -Match '^distinct: databases on D:\\'
            @($distinct.findings[0].result.metrics.sameVolumeServers).Count | Should -Be 0
        }

        It 'reports every check on a target that does not answer CIM as Unknown naming the error, never contacts a name that does not resolve, never uses WinRM, and leaves the other target alone' {
            $script:VolScenario = @{ CimDown = @('mbx02.example.test'); Unresolvable = @('mbx03.example.test') }
            $result = Invoke-TestVol -Run (New-TestVolRun -Targets @('mbx01.example.test', 'mbx02.example.test', 'mbx03.example.test'))
            $rows = @($result.findings[0].result.metrics.checks)
            $perTarget = (2 * $script:DeclaredVolumeChecksPerVolume) + $script:DeclaredVolumeChecksPerTarget

            $down = @($rows | Where-Object { $_.Server -eq 'mbx02.example.test' })
            $down.Count | Should -Be $perTarget
            foreach ($row in $down) {
                $row.Outcome | Should -Be 'Unknown'
                $row.Cause | Should -Match 'CIM connection to mbx02\.example\.test refused \(test\)'
            }
            $unresolved = @($rows | Where-Object { $_.Server -eq 'mbx03.example.test' })
            $unresolved.Count | Should -Be $perTarget
            foreach ($row in $unresolved) {
                $row.Outcome | Should -Be 'Unknown'
                $row.Cause | Should -Match 'did not resolve'
            }
            foreach ($row in @($rows | Where-Object { $_.Server -eq 'mbx01.example.test' })) {
                $row.Outcome | Should -Be 'Compliant' -Because "$($row.Role) $($row.Check) is met on the target that answered"
            }

            $servers = @($result.findings[0].result.metrics.servers)
            @($servers | Where-Object { $_.Server -eq 'mbx02.example.test' })[0].Status | Should -Be 'Unreachable'
            @($servers | Where-Object { $_.Server -eq 'mbx03.example.test' })[0].Status | Should -Be 'NameDoesNotResolve'
            $result.findings[0].result.outcome | Should -Be 'Unknown'
            $result.findings[0].result.rationale | Should -Match 'did not answer CIM'
            $result.findings[0].result.rationale | Should -Match 'do not resolve'
            Should -Invoke -ModuleName $script:ModuleName -CommandName Get-ExchTargetCimInstance -ParameterFilter { $ComputerName -eq 'mbx03.example.test' } -Times 0 -Exactly
            Should -Invoke -ModuleName $script:ModuleName -CommandName Invoke-ExchTargetCommand -Times 0 -Exactly
        }

        It 'evaluates all 9 declared checks per target with both volumes supplied - 4 on each volume and 1 comparing them - counted from the collector file''s text' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:VolCollectorFile, [ref]$null, [ref]$null)
            $definition = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ExchVolumeCheckDefinition' }, $true)
            $declared = @([regex]::Matches($definition.Extent.Text, "Check = '(?<check>\w+)';\s+Scope = '(?<scope>\w+)'") | ForEach-Object { [pscustomobject]@{ Check = $_.Groups['check'].Value; Scope = $_.Groups['scope'].Value } })
            @($declared | Where-Object { $_.Scope -eq 'PerVolume' }).Count | Should -Be $script:DeclaredVolumeChecksPerVolume
            @($declared | Where-Object { $_.Scope -eq 'PerTarget' }).Count | Should -Be $script:DeclaredVolumeChecksPerTarget
            $declared.Count | Should -Be ($script:DeclaredVolumeChecksPerVolume + $script:DeclaredVolumeChecksPerTarget)

            $targets = @('mbx01.example.test', 'mbx02.example.test')
            $result = Invoke-TestVol -Run (New-TestVolRun -Targets $targets)
            $rows = @($result.findings[0].result.metrics.checks)
            $rows.Count | Should -Be ($targets.Count * ((2 * $script:DeclaredVolumeChecksPerVolume) + $script:DeclaredVolumeChecksPerTarget))
            foreach ($target in $targets) {
                foreach ($item in $declared) {
                    $roles = if ($item.Scope -eq 'PerVolume') { @('DatabaseVolume', 'LogVolume') } else { @('DatabaseVolume+LogVolume') }
                    foreach ($role in $roles) {
                        @($rows | Where-Object { $_.Server -eq $target -and $_.Role -eq $role -and $_.Check -eq $item.Check }).Count | Should -Be 1 -Because "$target $role needs its $($item.Check) check"
                    }
                }
            }
            foreach ($row in $rows) { $row.Outcome | Should -Be 'Compliant' -Because "$($row.Server) $($row.Role) $($row.Check) is met in the mocks" }
            $result.findings[0].result.outcome | Should -Be 'Compliant'
            $result.findings[0].result.rationale | Should -Match 'Not read: whether two distinct volumes sit on different physical disks'
        }

        It 'judges file system and allocation unit size as Learn states them: NTFS and ReFS supported and anything else failed, a size other than 64 KB reported and not failed' {
            $script:VolScenario = @{ Volumes = @(
                [pscustomobject]@{ Name = 'D:\'; DeviceID = '\\?\Volume{00000000-0000-0000-0000-00000000000d}\'; FileSystem = 'FAT32'; FreeSpace = 900GB; BlockSize = 65536 }
                [pscustomobject]@{ Name = 'E:\'; DeviceID = '\\?\Volume{00000000-0000-0000-0000-00000000000e}\'; FileSystem = 'NTFS'; FreeSpace = 200GB; BlockSize = 4096 }
            ) }
            $result = Invoke-TestVol -Run (New-TestVolRun -Targets @('mbx01.example.test'))

            $fat = Get-TestVolRow -Result $result -Role 'DatabaseVolume' -Check 'FileSystem'
            $fat.Outcome | Should -Be 'NonCompliant'
            $fat.Cause | Should -Match 'Supported: NTFS and ReFS'
            (Get-TestVolRow -Result $result -Role 'LogVolume' -Check 'FileSystem').Outcome | Should -Be 'Compliant'

            $unit = Get-TestVolRow -Result $result -Role 'LogVolume' -Check 'AllocationUnitSize'
            $unit.Outcome | Should -Be 'PartiallyCompliant'
            $unit.Measured | Should -Be '4096 bytes'
            $unit.Cause | Should -Match 'Supported: All allocation unit sizes'
            $unit.Cause | Should -Match 'not failed'
            (Get-TestVolRow -Result $result -Role 'DatabaseVolume' -Check 'AllocationUnitSize').Outcome | Should -Be 'Compliant'
            $result.findings[0].result.outcome | Should -Be 'NonCompliant'
        }

        It 'records a Learn URL and read date next to every volume value, and ships the free-space minimums $null because Learn states no absolute figure' {
            $table = (Import-PowerShellDataFile -Path (Join-Path -Path $script:ToolRoot -ChildPath 'Config/Thresholds.psd1')).DeploymentVolumes
            @($table.Keys).Count | Should -Be 4
            foreach ($key in $table.Keys) {
                $entry = $table[$key]
                $entry.Contains('Value') | Should -BeTrue -Because "$key must carry a Value, even a null one"
                foreach ($source in @($entry.Source)) { $source | Should -Match '^https://learn\.microsoft\.com/' }
                $entry.Read | Should -Match '^\d{4}-\d{2}-\d{2}$'
                $entry.Note | Should -Not -BeNullOrEmpty
            }
            @($table.FileSystems.Value) | Should -Be @('NTFS', 'ReFS')
            $table.AllocationUnitBytes.Value | Should -Be 65536
            $table.DatabaseVolumeMinimumFreeGB.Value | Should -BeNullOrEmpty
            $table.DatabaseVolumeMinimumFreeGB.Note | Should -Match '120 percent'
            $table.LogVolumeMinimumFreeGB.Value | Should -BeNullOrEmpty
            $table.LogVolumeMinimumFreeGB.Note | Should -Match 'three days'
        }
    }

    Context 'Deployment readiness roll-up (DEP-01)' {

        BeforeAll {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop

            $script:RollupCollectorFile = Join-Path -Path $script:CollectorRoot -ChildPath 'DEP-01.DeploymentReadiness.ps1'

            # The population DEP-01 rolls up, written here rather than read from the module: the
            # directory control and every greenfield DEP.* control.
            $script:DeclaredRollupPopulation = @('ENV.VERS-01', 'DEP.TGT-01', 'DEP.NET-01', 'DEP.WIT-01', 'DEP.NAME-01', 'DEP.VOL-01')
            $script:DeclaredRollupCount = 6

            function New-TestRollupRun {
                param([switch]$NoDeployment)
                $folder = Join-Path -Path $TestDrive -ChildPath ('run-' + [guid]::NewGuid())
                New-Item -ItemType Directory -Path (Join-Path -Path $folder -ChildPath 'evidence') -Force | Out-Null
                $config = if ($NoDeployment) { @{} } else { @{ Deployment = @{
                    TargetServers = @('mbx01.example.test'); WitnessServer = 'fsw01.example.test'; DagName = 'DAG01'
                    InternalNames = @('mail.example.test'); DatabaseVolume = 'D:'; LogVolume = 'E:'
                } } }
                [pscustomobject]@{
                    RunId = 'test'; TenantHint = 'test'; RunFolder = $folder
                    LogPath = (Join-Path -Path $folder -ChildPath 'run.jsonl'); ConfigPath = ''
                    Config = $config; Flags = @{}
                    Errors = (New-Object System.Collections.Generic.List[object])
                }
            }

            # One upstream collector result, in the shape Invoke-ExchCollection hands to -Upstream.
            function New-TestUpstreamResult {
                param([string]$ControlId, [string]$Outcome = 'Compliant', [string]$Sufficiency = 'Pass', [string]$Rationale = '')
                if (-not $Rationale) { $Rationale = "$ControlId measured everything it checks (test)." }
                [pscustomobject]@{ sections = @(); findings = @([pscustomobject]@{
                    controlId = $ControlId; severity = 'Low'
                    result    = [pscustomobject]@{ outcome = $Outcome; sufficiency = $Sufficiency; rationale = $Rationale; metrics = @{} }
                }) }
            }

            # Every declared upstream reporting Compliant, unless overridden or left out.
            function New-TestUpstream {
                param([hashtable]$Override = @{}, [string[]]$Omit = @())
                $upstream = @{}
                foreach ($id in $script:DeclaredRollupPopulation) {
                    if ($Omit -contains $id) { continue }
                    $upstream[$id] = if ($Override.ContainsKey($id)) { $Override[$id] } else { New-TestUpstreamResult -ControlId $id }
                }
                $upstream
            }

            function Invoke-TestRollup {
                param($Run, [hashtable]$Upstream)
                & (Get-Module $script:ModuleName) { param($r, $u) Invoke-ExchCollector_DEP_01_DeploymentReadiness -Run $r -Upstream $u } $Run $Upstream
            }

            function Get-TestRollupRow {
                param($Result, [string]$ControlId)
                @($Result.findings[0].result.metrics.rows | Where-Object { $_.ControlId -eq $ControlId })[0]
            }
        }

        It 'registers DEP-01 as a well-formed row whose function resolves, under the existing switch and category, and does not require EX.CH-01 or ENV.OS-01' {
            $rows = @(& (Get-Module $script:ModuleName) { Get-ExchCollectorRegistry } | Where-Object { $_.Id -eq 'DEP-01' })
            $rows.Count | Should -Be 1
            $row = $rows[0]
            $row.Function | Should -Be 'Invoke-ExchCollector_DEP_01_DeploymentReadiness'
            $row.Area | Should -Be 'Deployment'
            $row.Cloud | Should -BeFalse
            $row.SkipFlag | Should -Be 'SkipDeploymentChecks'
            $command = & (Get-Module $script:ModuleName) { param($n) Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue } $row.Function
            $command.Parameters.Keys | Should -Contain 'Run'
            $command.Parameters.Keys | Should -Contain 'Upstream'
            (& (Get-Module $script:ModuleName) { Get-ExchControlById -ControlId 'DEP-01' }).domain |
                Should -Be (& (Get-Module $script:ModuleName) { Get-ExchControlById -ControlId 'DEP.TGT-01' }).domain

            # Both read the servers Get-ExchangeServer returns, and a greenfield deployment has none.
            @($row.Requires) | Should -Not -Contain 'EX.CH-01'
            @($row.Requires) | Should -Not -Contain 'ENV.OS-01'
            # ...and the header says so, so the asymmetry with UPG-01 is not later "fixed".
            $text = Get-Content -LiteralPath $script:RollupCollectorFile -Raw
            $header = $text.Substring(0, $text.IndexOf('Set-StrictMode'))
            $header | Should -Match 'EX\.CH-01 and ENV\.OS-01'
            $header | Should -Match 'existing Exchange organisation'
            $header | Should -Match 'do not "fix" it'

            # It measures nothing itself: no directory, CIM, WinRM, DNS or Exchange call in the file.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RollupCollectorFile, [ref]$null, [ref]$null)
            $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
            @($calls | Where-Object { $_ -match '^(Get-AD|Get-Cim|Invoke-Command|Resolve-DnsName|Get-ExchangeServer|Get-ExchTargetState|Invoke-ExchTargetCommand|Resolve-ExchTargetName|Find-ExchDirectory)' }) | Should -BeNullOrEmpty
        }

        It 'requires exactly the 6 controls ENV.VERS-01, DEP.TGT-01, DEP.NET-01, DEP.WIT-01, DEP.NAME-01 and DEP.VOL-01 - every DEP.* control in the registry plus ENV.VERS-01 - and reads exactly those' {
            $registry = @(& (Get-Module $script:ModuleName) { Get-ExchCollectorRegistry })
            $requires = @(@($registry | Where-Object { $_.Id -eq 'DEP-01' })[0].Requires)
            $requires.Count | Should -Be $script:DeclaredRollupCount
            @($requires | Sort-Object) | Should -Be @($script:DeclaredRollupPopulation | Sort-Object)

            # Derived a second way, from the registry itself: the directory control and every DEP.* control.
            $derived = @(@('ENV.VERS-01') + @($registry | Where-Object { $_.Id -like 'DEP.*' } | ForEach-Object { $_.Id }))
            $derived.Count | Should -Be $script:DeclaredRollupCount
            @($derived | Sort-Object) | Should -Be @($requires | Sort-Object)

            # ...and a third, from the collector's text: the controls it reads are the ones it requires.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RollupCollectorFile, [ref]$null, [ref]$null)
            $definition = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ExchDeploymentReadinessPrerequisite' }, $true)
            $read = @([regex]::Matches($definition.Extent.Text, "Key = '(?<id>[\w.\-]+)'") | ForEach-Object { $_.Groups['id'].Value })
            @($read | Sort-Object) | Should -Be @($requires | Sort-Object)

            # The dispatcher runs every one of them first.
            $ordered = @(& (Get-Module $script:ModuleName) { Get-ExchCollectorOrder } | ForEach-Object { $_.Id })
            foreach ($id in $requires) { [array]::IndexOf($ordered, $id) | Should -BeLessThan ([array]::IndexOf($ordered, 'DEP-01')) -Because "$id must run before DEP-01" }
        }

        It 'reports Compliant when every one of the 6 upstream controls reported Compliant with sufficiency Pass, and says what Compliant does not mean' {
            $result = Invoke-TestRollup -Run (New-TestRollupRun) -Upstream (New-TestUpstream)
            @($result.findings).Count | Should -Be 1
            $finding = $result.findings[0]
            $finding.controlId | Should -Be 'DEP-01'
            $finding.result.outcome | Should -Be 'Compliant'
            $finding.severity | Should -Be 'Low'
            $finding.result.sufficiency | Should -Be 'Pass'
            @($finding.result.metrics.passed).Count | Should -Be $script:DeclaredRollupCount
            $finding.result.rationale | Should -Match 'Measured and passed \(6\): '
            $finding.result.rationale | Should -Match 'does not mean Exchange Setup will succeed'
        }

        It 'reports Unknown when any one upstream control reported Unknown, naming that control and its reason - a Compliant never outvotes it' {
            foreach ($id in $script:DeclaredRollupPopulation) {
                $upstream = New-TestUpstream -Override @{ $id = (New-TestUpstreamResult -ControlId $id -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale "$id could not read its source (test).") }
                $result = Invoke-TestRollup -Run (New-TestRollupRun) -Upstream $upstream
                $finding = $result.findings[0]
                $finding.result.outcome | Should -Be 'Unknown' -Because "$id reported Unknown and the other five Compliant"

                $row = Get-TestRollupRow -Result $result -ControlId $id
                $row.Status | Should -Be 'Reported'
                $row.Group | Should -Be 'NotAssessed'
                $row.Cause | Should -Be "ran and reported Unknown: $id could not read its source (test)"
                @($finding.result.metrics.reportedUnknown) | Should -Be @($id)
                @($finding.result.metrics.notRun).Count | Should -Be 0
                $finding.result.rationale | Should -Match ('Could not be assessed \(1\): {0} ' -f [regex]::Escape($id))
                $finding.result.rationale | Should -Match ('{0} could not read its source \(test\)' -f [regex]::Escape($id))
            }
        }

        It 'reports Unknown when an upstream control did not run at all, and says so differently from one that ran and reported Unknown' {
            foreach ($id in $script:DeclaredRollupPopulation) {
                $missing = Invoke-TestRollup -Run (New-TestRollupRun) -Upstream (New-TestUpstream -Omit @($id))
                $unknown = Invoke-TestRollup -Run (New-TestRollupRun) -Upstream (New-TestUpstream -Override @{ $id = (New-TestUpstreamResult -ControlId $id -Outcome 'Unknown' -Sufficiency 'HardFail') })

                $missing.findings[0].result.outcome | Should -Be 'Unknown' -Because "$id did not run, and an absence is not a pass"
                $notRun = Get-TestRollupRow -Result $missing -ControlId $id
                $notRun.Status | Should -Be 'DidNotRun'
                $notRun.Outcome | Should -Be ''
                $notRun.Group | Should -Be 'NotAssessed'
                $notRun.Cause | Should -Match '^did not run: no result from it reached DEP-01'
                @($missing.findings[0].result.metrics.notRun) | Should -Be @($id)
                @($missing.findings[0].result.metrics.reportedUnknown).Count | Should -Be 0

                $reported = Get-TestRollupRow -Result $unknown -ControlId $id
                $reported.Status | Should -Be 'Reported'
                $reported.Cause | Should -Match '^ran and reported Unknown'
                $reported.Status | Should -Not -Be $notRun.Status
                $reported.Cause | Should -Not -Be $notRun.Cause
                @($unknown.findings[0].result.metrics.notRun).Count | Should -Be 0
            }

            # A result that carries no finding under its own control id is a third cause, not a pass.
            $noFinding = Invoke-TestRollup -Run (New-TestRollupRun) -Upstream (New-TestUpstream -Override @{ 'DEP.VOL-01' = [pscustomobject]@{ sections = @(); findings = @() } })
            (Get-TestRollupRow -Result $noFinding -ControlId 'DEP.VOL-01').Status | Should -Be 'NoFinding'
            $noFinding.findings[0].result.outcome | Should -Be 'Unknown'
        }

        It 'writes all three groups - passed, did not pass, could not be assessed - even when one is empty, an empty group as a measured zero' {
            $groups = @('Measured and passed', 'Measured and did not pass', 'Could not be assessed')

            $allPassed = (Invoke-TestRollup -Run (New-TestRollupRun) -Upstream (New-TestUpstream)).findings[0]
            $noneRan   = (Invoke-TestRollup -Run (New-TestRollupRun) -Upstream @{}).findings[0]
            $mixed     = (Invoke-TestRollup -Run (New-TestRollupRun) -Upstream (New-TestUpstream -Omit @('DEP.VOL-01') -Override @{
                'DEP.TGT-01' = (New-TestUpstreamResult -ControlId 'DEP.TGT-01' -Outcome 'NonCompliant' -Rationale 'mbx01 lacks a prerequisite (test).')
                'DEP.NET-01' = (New-TestUpstreamResult -ControlId 'DEP.NET-01' -Outcome 'Unknown' -Sufficiency 'SoftFail' -Rationale 'a flow timed out (test).')
            })).findings[0]

            foreach ($finding in @($allPassed, $noneRan, $mixed)) {
                foreach ($group in $groups) { $finding.result.rationale | Should -Match ('{0} \(\d+\): ' -f $group) -Because "the '$group' group is always written" }
            }
            $allPassed.result.rationale | Should -Match 'Measured and did not pass \(0\): none'
            $allPassed.result.rationale | Should -Match 'Could not be assessed \(0\): none'

            $noneRan.result.rationale | Should -Match 'Measured and passed \(0\): none'
            $noneRan.result.rationale | Should -Match 'Measured and did not pass \(0\): none'
            $noneRan.result.rationale | Should -Match 'Could not be assessed \(6\): '
            $noneRan.result.outcome | Should -Be 'Unknown'
            $noneRan.result.sufficiency | Should -Be 'HardFail'

            $mixed.result.rationale | Should -Match 'Measured and passed \(3\): '
            $mixed.result.rationale | Should -Match 'Measured and did not pass \(1\): DEP\.TGT-01 .*mbx01 lacks a prerequisite \(test\)'
            $mixed.result.rationale | Should -Match 'Could not be assessed \(2\): '
            $mixed.result.rationale | Should -Match 'DEP\.NET-01 \([^)]*\) - ran and reported Unknown: a flow timed out \(test\)'
            $mixed.result.rationale | Should -Match 'DEP\.VOL-01 \([^)]*\) - did not run'
            # Anything not assessed makes the verdict Unknown even beside a known failure; the
            # failure keeps the severity and stays listed.
            $mixed.result.outcome | Should -Be 'Unknown'
            $mixed.severity | Should -Be 'High'
        }

        It 'does not count a Compliant the upstream control marked as not fully assessed as passed' {
            $upstream = New-TestUpstream -Override @{ 'ENV.VERS-01' = (New-TestUpstreamResult -ControlId 'ENV.VERS-01' -Outcome 'Compliant' -Sufficiency 'SoftFail' `
                -Rationale 'Exchange preparation values could not all be read: No Exchange organisation container found in the configuration naming context (test).') }
            $result = Invoke-TestRollup -Run (New-TestRollupRun) -Upstream $upstream
            $row = Get-TestRollupRow -Result $result -ControlId 'ENV.VERS-01'
            $row.Group | Should -Be 'NotAssessed'
            $row.Cause | Should -Match "^ran and reported Compliant, but with sufficiency 'SoftFail'"
            $result.findings[0].result.outcome | Should -Be 'Unknown'
            @($result.findings[0].result.metrics.passed) | Should -Not -Contain 'ENV.VERS-01'
        }

        It 'reports Info severity with the P13 instructions when no deployment config was supplied, as every DEP.* control does' {
            $template = & (Get-Module $script:ModuleName) { Get-ExchDeploymentTemplatePath }
            $upstream = @{}
            foreach ($id in $script:DeclaredRollupPopulation) { $upstream[$id] = New-TestUpstreamResult -ControlId $id -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale "$id reported that nothing was supplied (test)." }
            $finding = (Invoke-TestRollup -Run (New-TestRollupRun -NoDeployment) -Upstream $upstream).findings[0]
            $finding.result.outcome | Should -Be 'Unknown'
            $finding.severity | Should -Be 'Info'
            $finding.result.rationale | Should -Match 'No deployment config was supplied'
            $finding.result.rationale.Contains($template) | Should -BeTrue
            $finding.result.rationale.Contains('New-ExchDeploymentConfig -Path .\Deployment.psd1') | Should -BeTrue
            $finding.result.rationale.Contains('-ConfigPath .\Deployment.psd1') | Should -BeTrue
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

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
            $list | Should -Not -BeNullOrEmpty -Because 'an empty list must not unroll to $null'
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

    Context 'Static analysis' {

        It 'reports no PSScriptAnalyzer findings for the repository' {
            $script:SettingsPath | Should -Exist

            $findings = Invoke-ScriptAnalyzer -Path $script:RepoRoot -Recurse -Settings $script:SettingsPath
            $report = ($findings | Format-Table -AutoSize | Out-String)

            $findings.Count | Should -Be 0 -Because "PSScriptAnalyzer reported:`n$report"
        }
    }
}

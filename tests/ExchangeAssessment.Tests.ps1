#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:SourceRoot = Join-Path -Path $script:RepoRoot -ChildPath 'src'
    $script:ModuleName = 'ExchangeAssessment'
    $script:ToolRoot = Join-Path -Path $script:SourceRoot -ChildPath $script:ModuleName
    $script:ManifestPath = Join-Path -Path $script:ToolRoot -ChildPath "$script:ModuleName.psd1"
    $script:SettingsPath = Join-Path -Path $script:RepoRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
    $script:EntryScript = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/Invoke-ExchAssess.ps1'
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

    Context 'Collectors' {

        BeforeAll {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop
            $script:CollectorRoot = Join-Path -Path $script:ToolRoot -ChildPath 'Collectors'
        }

        It 'ships collector files' {
            (Get-ChildItem -Path $script:CollectorRoot -Filter '*.ps1').Count | Should -BeGreaterThan 10
        }

        It 'defines every collector function the dispatcher calls' {
            $dispatcher = Join-Path -Path $script:ToolRoot -ChildPath 'Public/Invoke-ExchCollection.ps1'
            $called = [regex]::Matches(
                (Get-Content -Path $dispatcher -Raw),
                "(?<name>Invoke-ExchCollector_[\w]+)"
            ) | ForEach-Object { $_.Groups['name'].Value } | Sort-Object -Unique

            $called.Count | Should -BeGreaterThan 0

            $defined = Get-ChildItem -Path $script:CollectorRoot -Filter '*.ps1' |
                ForEach-Object { [regex]::Matches((Get-Content -Path $_.FullName -Raw), '(?m)^\s*function\s+(?<name>[\w\-]+)') } |
                ForEach-Object { $_.Groups['name'].Value }

            $missing = $called | Where-Object { $_ -notin $defined }
            $missing | Should -BeNullOrEmpty -Because "the dispatcher calls these collectors: $($missing -join ', ')"
        }

        It 'resolves every control id a collector asks the catalog for' {
            $catalog = Get-Content -Path (Join-Path -Path $script:ToolRoot -ChildPath 'Catalog/ControlCatalog.ps1') -Raw

            $requested = Get-ChildItem -Path $script:CollectorRoot -Filter '*.ps1' |
                ForEach-Object { [regex]::Matches((Get-Content -Path $_.FullName -Raw), "Get-ExchControlById\s+-ControlId\s+'(?<id>[^']+)'") } |
                ForEach-Object { $_.Groups['id'].Value } | Sort-Object -Unique

            $requested.Count | Should -BeGreaterThan 0

            $missing = $requested | Where-Object { $catalog -notmatch [regex]::Escape($_) }
            $missing | Should -BeNullOrEmpty -Because "the catalog has no entry for: $($missing -join ', ')"
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
        }
    }

    Context 'Word report helper' {

        It 'ships Generate-WordReport.py inside the module folder' {
            Join-Path -Path $script:ToolRoot -ChildPath 'Scripts/Generate-WordReport.py' | Should -Exist
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

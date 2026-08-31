<#
Threshold configuration.

Config/Thresholds.psd1 holds every value the tool judges against. A caller may supply their own
.psd1 with -ConfigPath; its keys are merged over the defaults, so a client baseline only has to
state what differs. The merged result rides on the run context, and collectors read it through
Get-ExchThreshold rather than holding numbers of their own.
#>

Set-StrictMode -Version Latest

function Get-ExchDefaultConfigPath {
    [CmdletBinding()]
    param()
    return (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Config/Thresholds.psd1')
}

function Merge-ExchConfigTable {
    <#
    Deep-merges $Override onto $Base. Nested hashtables merge key by key; every other value,
    arrays included, is replaced outright - a caller who lists three AV process tokens means
    those three, not those three appended to the defaults.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Base,
        [Parameter(Mandatory)][hashtable]$Override
    )

    $merged = @{}
    foreach ($key in $Base.Keys) { $merged[$key] = $Base[$key] }

    foreach ($key in $Override.Keys) {
        if ($merged.ContainsKey($key) -and $merged[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $merged[$key] = Merge-ExchConfigTable -Base $merged[$key] -Override $Override[$key]
        }
        else {
            $merged[$key] = $Override[$key]
        }
    }

    return $merged
}

function Import-ExchConfiguration {
    [CmdletBinding()]
    param([Parameter()][string]$ConfigPath)

    $defaultPath = Get-ExchDefaultConfigPath
    if (-not (Test-Path -LiteralPath $defaultPath)) {
        throw "Threshold configuration not found at $defaultPath."
    }

    $config = Import-PowerShellDataFile -Path $defaultPath

    if ($ConfigPath) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            throw "ConfigPath not found: $ConfigPath"
        }
        $override = Import-PowerShellDataFile -Path $ConfigPath
        $config = Merge-ExchConfigTable -Base $config -Override $override
    }

    return $config
}

function Get-ExchThreshold {
    <#
    Reads a threshold off the run's merged configuration by dotted path, e.g.
    'Certificate.ExpiryWarningDays'. Returns -Default when the path is absent, so a collector
    written against a newer default still runs against an older override file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter()]$Default = $null
    )

    $config = $null
    $prop = $Run.PSObject.Properties.Match('Config') | Select-Object -First 1
    if ($prop) { $config = $prop.Value }
    if ($null -eq $config) { return $Default }

    $cursor = $config
    foreach ($segment in $Name.Split('.')) {
        if ($null -eq $cursor) { return $Default }
        if ($cursor -is [System.Collections.IDictionary]) {
            if (-not $cursor.Contains($segment)) { return $Default }
            $cursor = $cursor[$segment]
        }
        else {
            $p = $cursor.PSObject.Properties.Match($segment) | Select-Object -First 1
            if (-not $p) { return $Default }
            $cursor = $p.Value
        }
    }

    if ($null -eq $cursor) { return $Default }
    return $cursor
}

function Get-ExchRunFlag {
    <#
    Reads a boolean switch recorded on the run context (FullInventory, IncludeExchangeOnline).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )

    $flags = $null
    $prop = $Run.PSObject.Properties.Match('Flags') | Select-Object -First 1
    if ($prop) { $flags = $prop.Value }
    if ($null -eq $flags) { return $false }

    if ($flags -is [System.Collections.IDictionary]) {
        if (-not $flags.Contains($Name)) { return $false }
        return [bool]$flags[$Name]
    }

    $f = $flags.PSObject.Properties.Match($Name) | Select-Object -First 1
    if (-not $f) { return $false }
    return [bool]$f.Value
}

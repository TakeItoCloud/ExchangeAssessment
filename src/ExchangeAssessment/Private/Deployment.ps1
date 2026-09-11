<#
The deployment config contract.

A greenfield Exchange Server SE deployment needs three things the directory cannot supply: the
member servers that will become Exchange servers, the file share witness, and the planned names.
They arrive as a Deployment section in the file passed with -ConfigPath, shaped like
Config/Deployment.template.psd1, and ride on the run's merged configuration.

What lives here is the contract itself - its keys, where the template is, what a given
configuration is missing, and the instructions for supplying it - so the preflight check and the
DEP.* collectors say, by name and in the same words, what the operator has not supplied.
DEP.TGT-01 and DEP.NET-01 read TargetServers, DEP.WIT-01 reads WitnessServer, and DEP.NAME-01
reads TargetServers, WitnessServer, DagName and InternalNames.
#>

Set-StrictMode -Version Latest

function Get-ExchDeploymentTemplatePath {
    <#
    The shipped template, resolved from the module base at run time so it is found wherever the
    module is installed.
    #>
    [CmdletBinding()]
    param()

    $moduleBase = Split-Path -Path $PSScriptRoot -Parent
    return [System.IO.Path]::GetFullPath((Join-Path -Path $moduleBase -ChildPath 'Config/Deployment.template.psd1'))
}

function Get-ExchDeploymentKey {
    <#
    The contract keys, in the order the template lists them. A test holds the template and this
    list to the same set, so neither can gain or lose a key on its own.
    #>
    [CmdletBinding()]
    param()

    return @('TargetServers', 'WitnessServer', 'DagName', 'InternalNames', 'DatabaseVolume', 'LogVolume')
}

function Get-ExchDeploymentConfigGap {
    <#
    Compares a Deployment section against the contract. A key is missing when it is absent or
    its value is empty: an empty string, an empty array, or an array of empty strings.

    Supplied is false when nothing at all was supplied - no section, a section that is not a
    table, or a table with every key empty. That is the normal state for an assessment of an
    existing organisation, and it is reported differently from a plan that is half filled in.
    #>
    [CmdletBinding()]
    param([Parameter()]$Deployment)

    $keys = @(Get-ExchDeploymentKey)
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($key in $keys) {
        $filled = $false
        if ($Deployment -is [System.Collections.IDictionary] -and $Deployment.Contains($key)) {
            $values = @($Deployment[$key] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $filled = $values.Count -gt 0
        }
        if (-not $filled) { $missing.Add($key) | Out-Null }
    }

    [pscustomobject]@{
        Supplied = ($missing.Count -lt $keys.Count)
        Missing  = $missing.ToArray()
    }
}

function Get-ExchDeploymentConfigInstruction {
    <#
    Where the template is and the commands that supply a deployment config. The preflight warning
    and every DEP.* collector that reports a missing value take their wording from here, so the
    two can never tell the operator different things.
    #>
    [CmdletBinding()]
    param()

    $template = Get-ExchDeploymentTemplatePath
    if (-not (Test-Path -LiteralPath $template -PathType Leaf)) {
        $template = "$template (not found - the module installation is incomplete)"
    }

    [pscustomobject]@{
        Template       = $template
        CreateCommand  = 'New-ExchDeploymentConfig -Path .\Deployment.psd1'
        PassBackRun    = 'New-ExchRun -OutputRoot <folder> -ConfigPath .\Deployment.psd1'
        PassBackScript = '.\scripts\Invoke-ExchAssess.ps1 -TenantHint <name> -ConfigPath .\Deployment.psd1'
    }
}

function Get-ExchDeploymentSupplyInstruction {
    <#
    The sentence that tells the operator how to supply the named keys: the template, the command
    that copies it, and both ways of passing it back. Every DEP.* collector that reports a key as
    not supplied ends its rationale with this, so none of them words it differently.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Keys)

    $instruction = Get-ExchDeploymentConfigInstruction
    return ("Template: {0}. Create a copy: {1}. Fill in {4}, then pass it back: {2} (or {3})." -f `
        $instruction.Template, $instruction.CreateCommand, $instruction.PassBackScript, $instruction.PassBackRun, ($Keys -join ', '))
}

function Get-ExchDeploymentValue {
    <#
    The values of one Deployment key: trimmed, blanks dropped, and a value listed twice kept once,
    in its first spelling. A single string and an array read the same way.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key
    )

    $seen = @{}
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Get-ExchThreshold -Run $Run -Name ('Deployment.{0}' -f $Key) -Default @())) {
        $text = ([string]$item).Trim()
        if (-not $text) { continue }
        $folded = $text.ToLowerInvariant()
        if ($seen.ContainsKey($folded)) { continue }
        $seen[$folded] = $true
        $values.Add($text) | Out-Null
    }
    return $values.ToArray()
}

function Get-ExchDeploymentWitnessServer {
    <#
    Deployment.WitnessServer, trimmed, or '' when it was not supplied.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    return [string](@(Get-ExchDeploymentValue -Run $Run -Key 'WitnessServer') | Select-Object -First 1)
}

function Get-ExchDeploymentConfigWarning {
    <#
    The preflight warning for a Deployment section, or $null when every contract key is filled.
    Two forms: nothing supplied, which says what that costs and how to supply it; and partly
    supplied, which names exactly the keys still missing.

    Both begin 'Deployment config:'. Invoke-ExchAssess.ps1 prints a warning that starts that way
    as a delimited block, and a test holds the two to the same prefix.
    #>
    [CmdletBinding()]
    param([Parameter()]$Deployment)

    $gap = Get-ExchDeploymentConfigGap -Deployment $Deployment
    if (@($gap.Missing).Count -eq 0) { return $null }

    $instruction = Get-ExchDeploymentConfigInstruction
    $template = $instruction.Template

    if (-not $gap.Supplied) {
        $lines = @(
            'Deployment config: none supplied. Greenfield deployment controls will report Unknown because no target servers, witness or planned names were supplied.'
            'This is expected when assessing an existing organisation, and the rest of the assessment is unaffected.'
            "  Template:      $template"
            "  Create a copy: $($instruction.CreateCommand)"
            "  Pass it back:  $($instruction.PassBackRun)"
            "             or: $($instruction.PassBackScript)"
            '  A run takes one -ConfigPath: if it already carries threshold overrides, add the Deployment section to that file.'
        )
    }
    else {
        $lines = @(
            ('Deployment config: incomplete. Missing or empty: {0}. Greenfield deployment controls that depend on them will report Unknown.' -f ($gap.Missing -join ', '))
            "  Fill them in the file passed with -ConfigPath. Template: $template"
        )
    }

    return ($lines -join [Environment]::NewLine)
}

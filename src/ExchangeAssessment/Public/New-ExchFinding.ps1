<#
Creates a standard finding object for the Exchange Assessment.
#>

function New-ExchFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Environment','Exchange','Mailbox','Transport','Certificate','Hybrid','Identity','Upgrade','Security','Other')][string]$ControlDomain,
        # Accept IDs with or without a dot segment (e.g., EX.CH-01 or UPG-01)
        [Parameter(Mandatory)][ValidatePattern('^[A-Z]{2,4}(?:\.[A-Z]{2,5})?-\d{2}$')][string]$ControlId,
        [Parameter(Mandatory)][ValidateSet('Info','Low','Medium','High','Critical')][string]$Severity,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Description,
        [Parameter()][object[]]$Evidence = @(),
        [Parameter()][string]$Remediation = '',
        [Parameter()][hashtable[]]$FrameworkMappings = @(),
        [Parameter()][ValidateSet('Compliant','PartiallyCompliant','NonCompliant','Unknown')][string]$Outcome = 'Unknown',
        [Parameter()][ValidateSet('Pass','SoftFail','HardFail')][string]$Sufficiency = 'Pass',
        [Parameter()][string]$Rationale = '',
        [Parameter()][hashtable]$Metrics = @{},
        [Parameter()][hashtable]$Meta = @{}
    )

    [pscustomobject]@{
        controlDomain     = $ControlDomain
        controlId         = $ControlId
        severity          = $Severity
        title             = $Title
        description       = $Description
        evidence          = @($Evidence) | Where-Object { $_ -ne $null }
        remediation       = $Remediation
        frameworkMappings = @($FrameworkMappings) | Where-Object { $_ -ne $null }
        result            = [pscustomobject]@{
            outcome     = $Outcome
            sufficiency = $Sufficiency
            rationale   = $Rationale
            metrics     = $Metrics
        }
        meta              = $Meta
        detectedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
    }
}

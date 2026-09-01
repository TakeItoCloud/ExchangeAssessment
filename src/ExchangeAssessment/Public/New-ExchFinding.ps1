<#
Creates a standard finding object for the Exchange Assessment.

A finding is a judgement, and a judgement has to be earned: -Outcome and -Rationale are
mandatory, so no collector can report a pass it did not measure. A collector that could not
reach its data source reports Outcome 'Unknown' with Sufficiency 'HardFail' and says why.
#>

function New-ExchFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Environment','Exchange','Mailbox','Transport','Certificate','Hybrid','Identity','Upgrade','Security','Monitoring','Compliance','Client','Network','Cloud','Other')][string]$ControlDomain,
        # Accept IDs with or without a dot segment (e.g., EX.CH-01 or UPG-01)
        [Parameter(Mandatory)][ValidatePattern('^[A-Z]{2,4}(?:\.[A-Z]{2,5})?-\d{2}$')][string]$ControlId,
        [Parameter(Mandatory)][ValidateSet('Info','Low','Medium','High','Critical')][string]$Severity,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][ValidateSet('Compliant','PartiallyCompliant','NonCompliant','Unknown')][string]$Outcome,
        # Why this outcome, in the collector's own words, naming the values it measured.
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Rationale,
        [Parameter()][object[]]$Evidence = @(),
        [Parameter()][string]$Remediation = '',
        [Parameter()][hashtable[]]$FrameworkMappings = @(),
        # Authoritative Microsoft articles for the control, as @{ title = ''; url = '' }.
        [Parameter()][hashtable[]]$References = @(),
        [Parameter()][ValidateSet('Pass','SoftFail','HardFail')][string]$Sufficiency = 'Pass',
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
        references        = @($References) | Where-Object { $_ -ne $null }
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

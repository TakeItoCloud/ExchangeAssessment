<#
Logging for Exchange Assessment runs.

Two rules shape this file. A log write must never take down a run - an assessment that dies
because it could not write a log line is worse than one that loses a line. And a failure must
be recorded in enough detail to diagnose it without re-running: the exception type, where it
was thrown, what was being attempted, and the whole inner-exception chain.
#>

Set-StrictMode -Version Latest

function Write-ExchLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][hashtable]$Data,
        [Parameter(Mandatory)][string]$LogPath
    )

    $entry = [ordered]@{
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        level         = $Level
        message       = $Message
        data          = $Data
    }

    $line = $null
    try { $line = $entry | ConvertTo-Json -Depth 10 -Compress }
    catch {
        # Something in $Data would not serialise. Keep the line rather than lose the event.
        $line = ([ordered]@{
            timestamp_utc = $entry.timestamp_utc
            level         = $Level
            message       = $Message
            data          = @{ serialisationError = $_.Exception.Message; raw = [string]$Data }
        } | ConvertTo-Json -Depth 5 -Compress)
    }

    # The log file can be held briefly by the transcript or an antivirus scanner. Retry a few
    # times, then give up quietly - losing a log line must not fail the assessment.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq 3) {
                Write-Warning ("Could not write to the run log ({0}): {1}" -f $LogPath, $_.Exception.Message)
                return
            }
            Start-Sleep -Milliseconds (50 * $attempt)
        }
    }
}

function Get-ExchErrorDetail {
    <#
    Flattens an ErrorRecord into everything worth keeping: the exception type and message, the
    fully qualified error id, the category, the target, where in the script it was thrown, and
    every inner exception. This is the difference between "the collector failed" and knowing
    which cmdlet threw what against which object.
    #>
    [CmdletBinding()]
    param([Parameter()]$ErrorRecord)

    if ($null -eq $ErrorRecord) { return $null }

    $detail = [ordered]@{
        message              = ''
        exceptionType        = ''
        fullyQualifiedErrorId= ''
        category             = ''
        targetObject         = ''
        invokedCommand       = ''
        scriptName           = ''
        lineNumber           = 0
        line                 = ''
        scriptStackTrace     = ''
        innerExceptions      = @()
    }

    try {
        $exception = $ErrorRecord.Exception
        if ($exception) {
            $detail.message = [string]$exception.Message
            $detail.exceptionType = $exception.GetType().FullName

            $chain = New-Object System.Collections.Generic.List[object]
            $inner = $exception.InnerException
            $guard = 0
            while ($inner -and $guard -lt 10) {
                $chain.Add([ordered]@{ type = $inner.GetType().FullName; message = [string]$inner.Message }) | Out-Null
                $inner = $inner.InnerException
                $guard++
            }
            $detail.innerExceptions = @($chain.ToArray())
        }

        $detail.fullyQualifiedErrorId = [string]$ErrorRecord.FullyQualifiedErrorId
        $detail.scriptStackTrace = [string]$ErrorRecord.ScriptStackTrace

        if ($ErrorRecord.CategoryInfo) {
            $detail.category = [string]$ErrorRecord.CategoryInfo.Category
            $detail.invokedCommand = [string]$ErrorRecord.CategoryInfo.Activity
        }

        if ($null -ne $ErrorRecord.TargetObject) {
            $detail.targetObject = [string]$ErrorRecord.TargetObject
        }

        if ($ErrorRecord.InvocationInfo) {
            $detail.scriptName = [string]$ErrorRecord.InvocationInfo.ScriptName
            $detail.lineNumber = [int]$ErrorRecord.InvocationInfo.ScriptLineNumber
            $detail.line = ([string]$ErrorRecord.InvocationInfo.Line).Trim()
        }
    }
    catch {
        # Reading an ErrorRecord should never itself throw, but if it does, keep what we have.
        $detail.message = [string]$ErrorRecord
    }

    return $detail
}

function Write-ExchError {
    <#
    Records a failure: a detailed line in the run log, and an entry on the run's error list so
    it reaches the report as well. A failure that only exists in a log file is a failure the
    person reading the assessment will never see.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        # What was being attempted, in words: 'Get-MailboxDatabase', 'Test-ServiceHealth on EX02'.
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Context,
        [Parameter()]$ErrorRecord,
        [Parameter()][string]$ControlId = '',
        [Parameter()][ValidateSet('Warning','Error')][string]$Severity = 'Error',
        [Parameter()][hashtable]$Data = @{}
    )

    $detail = Get-ExchErrorDetail -ErrorRecord $ErrorRecord

    $record = [ordered]@{
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        controlId    = $ControlId
        context      = $Context
        severity     = $Severity
        detail       = $detail
        data         = $Data
    }

    $list = Get-ExchRunErrorList -Run $Run
    if ($null -ne $list) { $list.Add([pscustomobject]$record) | Out-Null }

    try {
        Write-ExchLog -Level $(if ($Severity -eq 'Warning') { 'WARN' } else { 'ERROR' }) `
            -Message ("{0} failed" -f $Context) `
            -Data @{ controlId = $ControlId; context = $Context; error = $detail; data = $Data } `
            -LogPath $Run.LogPath
    }
    catch {
        Write-Warning ("Could not log the failure of {0}: {1}" -f $Context, $_.Exception.Message)
    }

    return [pscustomobject]$record
}

function Get-ExchRunErrorList {
    <#
    The run's error list, or $null when the run context predates it (a hand-built run in a test).

    The comma is load-bearing. PowerShell unrolls a collection on return, so returning an empty
    List yields $null - which made the caller think there was no list, skip the Add, and leave
    the list empty for the rest of the run. Returning a single-element array of the list
    prevents the unroll.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $property = $Run.PSObject.Properties.Match('Errors') | Select-Object -First 1
    if (-not $property) { return $null }
    return , $property.Value
}

function Get-ExchFileHashManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FolderPath
    )

    $files = Get-ChildItem -Path $FolderPath -File -Recurse -ErrorAction Stop
    foreach ($f in $files) {
        $h = Get-FileHash -Path $f.FullName -Algorithm SHA256
        [pscustomobject]@{
            path   = $f.FullName.Substring($FolderPath.Length).TrimStart([char[]]"\/")
            sha256 = $h.Hash
            bytes  = $f.Length
        }
    }
}

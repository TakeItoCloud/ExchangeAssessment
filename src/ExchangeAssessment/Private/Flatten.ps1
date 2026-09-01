<#
Value flattening helpers.

Exchange objects carry multi-valued and enum-flag properties that a CSV cell cannot hold.
Flattening happens once, when an inventory section is built, so that the CSV and the JSON
never disagree about what a value was.
#>

Set-StrictMode -Version Latest

function ConvertTo-ExchEnumName {
    <#
    Translates an enum value - or an int/string that represents one - into its name.
    Falls back to the original value when the type cannot be resolved.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]$Value,
        [Parameter(Mandatory)][string]$EnumType
    )

    if ($null -eq $Value) { return '' }

    $type = $null
    try { $type = [type]$EnumType }
    catch { return (ConvertTo-ExchFlatValue -Value $Value) }
    if ($null -eq $type) { return (ConvertTo-ExchFlatValue -Value $Value) }

    if ($Value -is [System.Array]) {
        return (@($Value | ForEach-Object { ConvertTo-ExchEnumName -Value $_ -EnumType $EnumType }) -join ';')
    }

    $v = $Value
    if ($v -is [string] -and ($v -as [int])) { $v = [int]$v }

    try { return ([enum]::ToObject($type, $v)).ToString() }
    catch { return (ConvertTo-ExchFlatValue -Value $Value) }
}

function ConvertTo-ExchFlatValue {
    <#
    Reduces any Exchange property value to a single CSV-safe scalar.

    Arrays and multi-valued properties join with ';'. Dates render round-trip so they sort
    lexically. Everything else uses its string form. $null becomes '' rather than the string
    'null', so an empty cell reads as empty in Excel.
    #>
    [CmdletBinding()]
    param([Parameter()]$Value)

    if ($null -eq $Value) { return '' }

    if ($Value -is [string])   { return $Value }
    if ($Value -is [bool])     { return $Value }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }

    if ($Value -is [System.Collections.IDictionary]) {
        return (@($Value.Keys | ForEach-Object { '{0}={1}' -f $_, (ConvertTo-ExchFlatValue -Value $Value[$_]) }) -join ';')
    }

    if ($Value -is [System.Array] -or ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string]))) {
        $parts = @()
        foreach ($item in $Value) { $parts += (ConvertTo-ExchFlatValue -Value $item) }
        return ($parts -join ';')
    }

    return $Value.ToString()
}

function ConvertTo-ExchFlatRow {
    <#
    Projects an object onto an ordered set of columns, flattening every value.

    Missing properties yield '' rather than throwing, so one odd server in an organisation
    cannot take a whole section down.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Columns,
        [Parameter()]$InputObject
    )

    $row = [ordered]@{}
    foreach ($col in $Columns) {
        $value = $null
        if ($null -ne $InputObject) {
            if ($InputObject -is [System.Collections.IDictionary]) {
                if ($InputObject.Contains($col)) { $value = $InputObject[$col] }
            }
            else {
                $prop = $InputObject.PSObject.Properties.Match($col) | Select-Object -First 1
                if ($prop) { $value = $prop.Value }
            }
        }
        $row[$col] = ConvertTo-ExchFlatValue -Value $value
    }

    return [pscustomobject]$row
}

function Get-ExchObjectValue {
    <#
    Reads one property off an object that may not carry it.

    Set-StrictMode -Version Latest turns a missing property into a terminating error, and
    Exchange object shapes vary by version and by role - a guarded read is the difference
    between a control reporting a value it did not find and a control taking the whole
    collector down.

    Intended for scalar properties. A collection-valued property unrolls on return, so read
    those through PSObject.Properties directly.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]$InputObject,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter()]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if (-not $InputObject.Contains($Name)) { return $Default }
        $value = $InputObject[$Name]
    }
    else {
        $property = $InputObject.PSObject.Properties.Match($Name) | Select-Object -First 1
        if (-not $property) { return $Default }
        $value = $property.Value
    }

    if ($null -eq $value) { return $Default }
    return $value
}

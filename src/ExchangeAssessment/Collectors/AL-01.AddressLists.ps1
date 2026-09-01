<#
AL-01 - Address lists and offline address book.

Mostly inventory. The one thing that genuinely breaks clients is an offline address book with no
generating mailbox, which leaves Outlook downloading a stale address book or none at all.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_AL_01_AddressLists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'AL-01'

    $errors = New-Object System.Collections.Generic.List[string]

    $addressLists = @(Invoke-ExchQuery -Label 'Get-AddressList'       -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-AddressList -ErrorAction Stop })
    $globalLists  = @(Invoke-ExchQuery -Label 'Get-GlobalAddressList' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-GlobalAddressList -ErrorAction Stop })
    $oabs         = @(Invoke-ExchQuery -Label 'Get-OfflineAddressBook' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-OfflineAddressBook -ErrorAction Stop })
    $abPolicies   = @(Invoke-ExchQuery -Label 'Get-AddressBookPolicy' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-AddressBookPolicy -ErrorAction Stop })

    $listRows = foreach ($l in $addressLists) {
        [pscustomobject]@{
            Name            = [string]$l.Name
            DisplayName     = [string]$l.DisplayName
            RecipientFilter = (Get-ExchTruncatedText -Text ([string]$l.RecipientFilter) -Length 200)
            Container       = [string]$l.Container
            LastUpdatedRecipientFilter = [string]$l.LastUpdatedRecipientFilter
        }
    }

    $galRows = foreach ($g in $globalLists) {
        [pscustomobject]@{
            Name            = [string]$g.Name
            IsDefaultGlobalAddressList = (ConvertTo-ExchFlatValue -Value $g.IsDefaultGlobalAddressList)
            RecipientFilter = (Get-ExchTruncatedText -Text ([string]$g.RecipientFilter) -Length 200)
        }
    }

    $oabRows = foreach ($o in $oabs) {
        $generatingMailbox = ''
        foreach ($property in @('GeneratingMailbox', 'Server')) {
            $p = $o.PSObject.Properties.Match($property) | Select-Object -First 1
            if ($p -and $p.Value) { $generatingMailbox = [string]$p.Value; break }
        }
        [pscustomobject]@{
            Name              = [string]$o.Name
            IsDefault         = (ConvertTo-ExchFlatValue -Value $o.IsDefault)
            GeneratingMailbox = $generatingMailbox
            AddressLists      = (ConvertTo-ExchFlatValue -Value $o.AddressLists)
            GlobalWebDistributionEnabled = (ConvertTo-ExchFlatValue -Value $o.GlobalWebDistributionEnabled)
            LastTouchedTime   = (ConvertTo-ExchFlatValue -Value $o.LastTouchedTime)
        }
    }

    $policyRows = foreach ($p in $abPolicies) {
        [pscustomobject]@{
            Name              = [string]$p.Name
            AddressLists      = (ConvertTo-ExchFlatValue -Value $p.AddressLists)
            GlobalAddressList = [string]$p.GlobalAddressList
            OfflineAddressBook= [string]$p.OfflineAddressBook
            RoomList          = [string]$p.RoomList
        }
    }

    $listArr   = @($listRows)
    $galArr    = @($galRows)
    $oabArr    = @($oabRows)
    $policyArr = @($policyRows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'exchange/address-lists.json' -ContentObject ([ordered]@{
        addressLists        = $listArr
        globalAddressLists  = $galArr
        offlineAddressBooks = $oabArr
        addressBookPolicies = $policyArr
        errors              = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'exchange.address-lists' -Title 'Address Lists' -Area 'Exchange' `
            -Columns @('Name', 'DisplayName', 'RecipientFilter', 'Container', 'LastUpdatedRecipientFilter') -Rows $listArr

        New-ExchInventorySection -Run $Run -Key 'exchange.global-address-lists' -Title 'Global Address Lists' -Area 'Exchange' `
            -Columns @('Name', 'IsDefaultGlobalAddressList', 'RecipientFilter') -Rows $galArr

        New-ExchInventorySection -Run $Run -Key 'exchange.offline-address-books' -Title 'Offline Address Books' -Area 'Exchange' `
            -Columns @('Name', 'IsDefault', 'GeneratingMailbox', 'AddressLists', 'GlobalWebDistributionEnabled', 'LastTouchedTime') -Rows $oabArr

        New-ExchInventorySection -Run $Run -Key 'exchange.address-book-policies' -Title 'Address Book Policies' -Area 'Exchange' `
            -Columns @('Name', 'AddressLists', 'GlobalAddressList', 'OfflineAddressBook', 'RoomList') -Rows $policyArr
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($galArr.Count -eq 0) {
        $problems.Add('No global address list exists, so clients have nothing to resolve names against') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    elseif (@($galArr | Where-Object { $_.IsDefaultGlobalAddressList -eq $true }).Count -eq 0) {
        $problems.Add(("{0} global address lists exist but none is marked default" -f $galArr.Count)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($oabArr.Count -eq 0) {
        $problems.Add('No offline address book exists, so cached-mode Outlook clients cannot download an address book') | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    else {
        $orphanOab = @($oabArr | Where-Object { -not $_.GeneratingMailbox })
        if ($orphanOab.Count -gt 0) {
            $problems.Add(("{0} offline address books have no generating mailbox, so they will not be regenerated: {1}" -f $orphanOab.Count, `
                (($orphanOab | ForEach-Object { $_.Name }) -join ', '))) | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
        if (@($oabArr | Where-Object { $_.IsDefault -eq $true }).Count -eq 0) {
            $problems.Add(("{0} offline address books exist but none is marked default" -f $oabArr.Count)) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }
    }

    if ($errors.Count -gt 0) {
        $problems.Add(("Some address list configuration could not be read: {0}" -f ($errors -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Low' }
        'Unknown'            { 'Low' }
        default              { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else { ("{0} address lists, {1} global address lists and {2} offline address books are defined, each with a generating mailbox." -f `
                        $listArr.Count, $galArr.Count, $oabArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Assign a generating mailbox to every offline address book, and make sure exactly one global address list and one offline address book are marked as default.' `
        -Metrics @{
            addressLists        = $listArr.Count
            globalAddressLists  = $galArr.Count
            offlineAddressBooks = $oabArr.Count
            addressBookPolicies = $policyArr.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

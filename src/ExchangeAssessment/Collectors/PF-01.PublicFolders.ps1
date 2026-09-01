<#
PF-01 - Public folder deployment.

Public folders are often the forgotten part of a migration. This reports whether they are in use
at all, whether a primary hierarchy mailbox exists (without one the whole deployment is
read-only), and whether a legacy public folder database is still present.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_PF_01_PublicFolders {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'PF-01'

    $errors = New-Object System.Collections.Generic.List[string]

    $pfMailboxes = @(Invoke-ExchQuery -Label 'Get-Mailbox -PublicFolder' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-Mailbox -PublicFolder -ResultSize Unlimited -ErrorAction Stop })
    $folders     = @(Invoke-ExchQuery -Label 'Get-PublicFolder'          -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-PublicFolder -Recurse -ResultSize 2000 -ErrorAction Stop })
    $legacyDbs   = @(Invoke-ExchQuery -Label 'Get-PublicFolderDatabase'  -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-PublicFolderDatabase -ErrorAction Stop })
    $orgConfig   = @(Invoke-ExchQuery -Label 'Get-OrganizationConfig'    -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-OrganizationConfig -ErrorAction Stop }) | Select-Object -First 1

    $publicFoldersEnabled = ''
    $hierarchyMailbox = ''
    if ($orgConfig) {
        $p = $orgConfig.PSObject.Properties.Match('PublicFoldersEnabled') | Select-Object -First 1
        if ($p) { $publicFoldersEnabled = [string]$p.Value }
        $h = $orgConfig.PSObject.Properties.Match('DefaultPublicFolderMailbox') | Select-Object -First 1
        if ($h) { $hierarchyMailbox = [string]$h.Value }
    }

    $mailboxRows = foreach ($m in $pfMailboxes) {
        $isPrimary = $false
        $p = $m.PSObject.Properties.Match('IsRootPublicFolderMailbox') | Select-Object -First 1
        if ($p) { $isPrimary = [bool]$p.Value }
        [pscustomobject]@{
            Name                = [string]$m.Name
            Database            = [string]$m.Database
            IsPrimaryHierarchy  = $isPrimary
            IsExcludedFromServingHierarchy = (ConvertTo-ExchFlatValue -Value $m.IsExcludedFromServingHierarchy)
            ProhibitSendQuota   = [string]$m.ProhibitSendQuota
        }
    }

    $folderRows = foreach ($f in $folders) {
        [pscustomobject]@{
            Identity        = [string]$f.Identity
            Name            = [string]$f.Name
            ParentPath      = [string]$f.ParentPath
            MailEnabled     = (ConvertTo-ExchFlatValue -Value $f.MailEnabled)
            ContentMailbox  = [string]$f.ContentMailboxName
            FolderClass     = [string]$f.FolderClass
        }
    }

    $legacyRows = foreach ($d in $legacyDbs) {
        [pscustomobject]@{
            Name   = [string]$d.Name
            Server = [string]$d.Server
            EdbFilePath = [string]$d.EdbFilePath
        }
    }

    $mailboxArr = @($mailboxRows)
    $folderArr  = @($folderRows)
    $legacyArr  = @($legacyRows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'exchange/public-folders.json' -ContentObject ([ordered]@{
        publicFolderMailboxes = $mailboxArr
        publicFolders         = $folderArr
        legacyDatabases       = $legacyArr
        publicFoldersEnabled  = $publicFoldersEnabled
        defaultHierarchyMailbox = $hierarchyMailbox
        errors                = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'exchange.public-folder-mailboxes' -Title 'Public Folder Mailboxes' -Area 'Exchange' `
            -Columns @('Name', 'Database', 'IsPrimaryHierarchy', 'IsExcludedFromServingHierarchy', 'ProhibitSendQuota') -Rows $mailboxArr

        New-ExchInventorySection -Run $Run -Key 'exchange.public-folders' -Title 'Public Folders' -Area 'Exchange' `
            -Columns @('Identity', 'Name', 'ParentPath', 'MailEnabled', 'ContentMailbox', 'FolderClass') -Rows $folderArr -HighCardinality

        New-ExchInventorySection -Run $Run -Key 'exchange.legacy-public-folder-databases' -Title 'Legacy Public Folder Databases' -Area 'Exchange' `
            -Columns @('Name', 'Server', 'EdbFilePath') -Rows $legacyArr
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($mailboxArr.Count -eq 0 -and $legacyArr.Count -eq 0) {
        # Whether public folders are expected is a property of the client, so the verdict comes
        # from the threshold configuration rather than being assumed here.
        $required = [bool](Get-ExchThreshold -Run $Run -Name 'PublicFolder.RequirePublicFolders' -Default $false)

        $finding = New-ExchControlFinding -Control $control `
            -Severity $(if ($required) { 'High' } else { 'Info' }) `
            -Outcome $(if ($required) { 'NonCompliant' } else { 'Compliant' }) `
            -Rationale $(if ($required) {
                    ("No public folder mailboxes exist, but this organisation is configured as requiring public folders. The organisation PublicFoldersEnabled setting reads '{0}'." -f $publicFoldersEnabled)
                } else {
                    ("No public folder mailboxes and no legacy public folder databases exist, so public folders are not deployed. The organisation PublicFoldersEnabled setting reads '{0}', and the assessment configuration does not require them for this organisation." -f $publicFoldersEnabled)
                }) `
            -Evidence @($evidence) `
            -Remediation 'If public folders are expected, create a public folder mailbox to hold the hierarchy. If they are deliberately not deployed, leave PublicFolder.RequirePublicFolders false for this client.' `
            -Metrics @{ publicFolderMailboxes = 0; publicFolders = 0; legacyDatabases = 0; publicFoldersRequired = $required } `
            -Meta @{ dataSources = @{ Exchange = @{ state = 'Success'; reason = 'No public folders deployed' } }; evaluationStatus = 'Complete' }

        return New-ExchCollectorResult -Sections $sections -Findings @($finding)
    }

    if ([bool](Get-ExchThreshold -Run $Run -Name 'PublicFolder.FlagLegacyPublicFolderDatabase' -Default $true) -and $legacyArr.Count -gt 0) {
        $problems.Add(("{0} legacy public folder databases still exist and are not supported on a current Exchange version: {1}" -f $legacyArr.Count, `
            (($legacyArr | ForEach-Object { "$($_.Name) on $($_.Server)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }

    if ($mailboxArr.Count -gt 0) {
        $primary = @($mailboxArr | Where-Object { $_.IsPrimaryHierarchy -eq $true })
        if ($primary.Count -eq 0) {
            $problems.Add('No public folder mailbox holds the primary hierarchy, so the hierarchy cannot be written to') | Out-Null
            $outcomes.Add('NonCompliant') | Out-Null
        }
        elseif ($primary.Count -gt 1) {
            $problems.Add(("{0} public folder mailboxes claim the primary hierarchy, which should be exactly one" -f $primary.Count)) | Out-Null
            $outcomes.Add('PartiallyCompliant') | Out-Null
        }
    }

    if ($errors.Count -gt 0) {
        $problems.Add(("Some public folder configuration could not be read: {0}" -f ($errors -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Medium' }
        'Unknown'            { 'Low' }
        default              { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else { ("{0} public folder mailboxes hold {1} folders, with exactly one primary hierarchy mailbox and no legacy public folder database." -f `
                        $mailboxArr.Count, $folderArr.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Migrate or decommission any legacy public folder database, and make sure exactly one public folder mailbox serves the primary hierarchy.' `
        -Metrics @{
            publicFolderMailboxes = $mailboxArr.Count
            publicFolders         = $folderArr.Count
            legacyDatabases       = $legacyArr.Count
            publicFoldersEnabled  = $publicFoldersEnabled
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

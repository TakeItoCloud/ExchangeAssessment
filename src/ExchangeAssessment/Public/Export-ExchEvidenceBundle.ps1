<#
Exports the Exchange Assessment bundle (evidence + findings + crosswalk + markdown + CAB CSV + best-effort Word/PDF) into a ZIP.
#>

function Export-ExchEvidenceBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidateNotNull()][object[]]$Findings,
        [Parameter()][ValidatePattern('^[a-zA-Z0-9\-_\.]{0,80}$')][string]$BundleName = ''
    )

    $ErrorActionPreference = 'Stop'
    $Findings = @($Findings | ForEach-Object { $_ }) | Where-Object { $_ -ne $null }

    $genRoot = Join-Path $Run.RunFolder 'generated'
    New-Item -ItemType Directory -Path $genRoot -Force | Out-Null

    function Get-Prop { param([object]$Obj,[string]$Name) if ($null -eq $Obj) { return $null } $p=$Obj.PSObject.Properties.Match($Name) | Select-Object -First 1; if($p){return $p.Value}; return $null }
    function Get-Nested { param([object]$Obj,[string[]]$Path) $cur=$Obj; foreach($k in $Path){ if($null -eq $cur){return $null}; $cur=Get-Prop -Obj $cur -Name $k }; return $cur }
    function Coalesce { param([Parameter(ValueFromRemainingArguments=$true)]$Values) foreach ($v in $Values) { if ($null -ne $v -and $v -ne '') { return $v } } return '' }
    function FriendlyList {
        param($Val)
        if ($null -eq $Val) { return '' }
        if ($Val -is [System.Array]) { return ($Val | ForEach-Object { $_.ToString() }) -join ',' }
        return $Val.ToString()
    }
    function TranslateFlags {
        param($Val,[string]$EnumName)
        if ($null -eq $Val) { return '' }
        $type = $null
        try { $type = [type]$EnumName } catch { return FriendlyList $Val }

        function _toName($v,$t) {
            if ($null -eq $v) { return '' }
            # If already string, try parse to enum; if int, cast to enum
            if ($v -is [System.Array]) { return ($v | ForEach-Object { _toName $_ $t }) -join ',' }
            $obj = $null
            if ($v -is [string] -and $v -as [int]) { $v = [int]$v }
            try { $obj = [enum]::ToObject($t, $v) } catch { return $v.ToString() }
            try { return $obj.ToString() } catch { return $v.ToString() }
        }

        return _toName $Val $type
    }

    # Catalog snapshot
    $catalog = Get-ExchControlCatalog
    ($catalog | ConvertTo-Json -Depth 12) | Set-Content -Path (Join-Path $genRoot 'control-catalog.json') -Encoding UTF8

    # Crosswalks
    $controlsToFrameworks = $catalog | ForEach-Object { [pscustomobject]@{ controlId=$_.controlId; domain=$_.domain; frameworks=$_.mappings } }
    $frameworkIndex = @{}
    foreach ($c in $catalog) {
        foreach ($m in @($c.mappings)) {
            $key = $m.framework
            if (-not $frameworkIndex.ContainsKey($key)) { $frameworkIndex[$key] = New-Object System.Collections.Generic.List[object] }
            $frameworkIndex[$key].Add([pscustomobject]@{ controlId=$c.controlId; title=$c.title; ref=$m.ref; note=$m.note }) | Out-Null
        }
    }
    $frameworksToControls = foreach ($k in $frameworkIndex.Keys) {
        [pscustomobject]@{ framework=$k; controls=@($frameworkIndex[$k].ToArray()) }
    }

    ($controlsToFrameworks | ConvertTo-Json -Depth 12) | Set-Content -Path (Join-Path $genRoot 'controls-to-frameworks.json') -Encoding UTF8
    ($frameworksToControls | ConvertTo-Json -Depth 12) | Set-Content -Path (Join-Path $genRoot 'frameworks-to-controls.json') -Encoding UTF8

    # Markdown summaries (simple table)
    function Write-ExchMarkdown {
        param([string]$Path,[string]$Title,[object[]]$Rows)

        function Read-JsonSafe {
            param([string]$rel)
            $full = Join-Path $Run.RunFolder $rel
            if (-not (Test-Path $full)) { return $null }
            try { return Get-Content -Path $full -Raw | ConvertFrom-Json } catch { return $null }
        }

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("# $Title") | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add(("Generated (UTC): {0}" -f (Get-Date).ToUniversalTime().ToString('o'))) | Out-Null
        $lines.Add(("Tenant hint: {0}" -f $Run.TenantHint)) | Out-Null
        $lines.Add(("RunId: {0}" -f $Run.RunId)) | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add(("Total findings: {0}" -f @($Rows).Count)) | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add('| controlId | domain | severity | outcome | sufficiency | title |') | Out-Null
        $lines.Add('| --- | --- | --- | --- | --- | --- |') | Out-Null
        foreach ($r in @($Rows)) {
            $lines.Add( ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f (
                (Coalesce (Get-Prop -Obj $r -Name 'controlId')),
                (Coalesce (Get-Prop -Obj $r -Name 'controlDomain') (Get-Prop -Obj $r -Name 'domain')),
                (Coalesce (Get-Prop -Obj $r -Name 'severity')),
                (Coalesce (Get-Nested -Obj $r -Path @('result','outcome')) 'Unknown'),
                (Coalesce (Get-Nested -Obj $r -Path @('result','sufficiency')) 'HardFail'),
                (Coalesce (Get-Prop -Obj $r -Name 'title')) -replace '\|' ,'|'
            )) ) | Out-Null
        }
        $lines.Add('') | Out-Null
        $lines.Add('## Collected Evidence (summaries)') | Out-Null
        $lines.Add('') | Out-Null

        # Environment snapshots
        $envVers = Read-JsonSafe 'evidence\environment\domain-forest-schema.json'
        if ($envVers) {
            $lines.Add('### Domain / Forest / Schema') | Out-Null
            $lines.Add( ("- Forest mode: {0}" -f (Coalesce (Get-Prop -Obj $envVers.forest -Name 'ForestMode'))) ) | Out-Null
            $lines.Add( ("- Domain mode: {0}" -f (Coalesce (Get-Prop -Obj $envVers.domain -Name 'DomainMode'))) ) | Out-Null
            $lines.Add( ("- Schema version: {0}" -f (Coalesce (Get-Prop -Obj $envVers -Name 'schemaVersion'))) ) | Out-Null
            $lines.Add('') | Out-Null
        }

        $envOs = Read-JsonSafe 'evidence\environment\exchange-os.json'
        if ($envOs) {
            $lines.Add('### Exchange Server OS') | Out-Null
            $lines.Add('| Server | Edition | Version | LastBoot | Error |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- |') | Out-Null
            foreach ($s in @($envOs)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} |' -f (Coalesce $s.server), (Coalesce $s.edition), (Coalesce $s.version), (Coalesce $s.lastBoot), (Coalesce $s.error)) ) | Out-Null
            }
            $lines.Add('') | Out-Null
        }

        $builds = Read-JsonSafe 'evidence\exchange\builds.json'
        if ($builds) {
            $lines.Add('### Exchange Builds / CU') | Out-Null
            $lines.Add('| Server | Edition | Version | Major | Minor | Build |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- | --- |') | Out-Null
            foreach ($b in @($builds)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f (Coalesce $b.server), (Coalesce $b.edition), (Coalesce $b.adminDisplayVersion), (Coalesce $b.major), (Coalesce $b.minor), (Coalesce $b.build)) ) | Out-Null
            }
            $lines.Add('') | Out-Null
        }

        $dbs = Read-JsonSafe 'evidence\mailbox\databases.json'
        if ($dbs) {
            $lines.Add('### Mailbox Databases') | Out-Null
            $lines.Add('| DB | Server | Mounted | Copies |') | Out-Null
            $lines.Add('| --- | --- | --- | --- |') | Out-Null
            foreach ($d in @($dbs)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} |' -f (Coalesce $d.name), (Coalesce $d.server), (Coalesce $d.mounted), (@($d.copies).Count)) ) | Out-Null
            }
            # Copy status detail (first 10 rows)
            $lines.Add('') | Out-Null
            $lines.Add('#### Copy Status (sample)') | Out-Null
            $lines.Add('| DB Copy | Status | CopyQueue | ReplayQueue | CI | ActiveCopy |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- | --- |') | Out-Null
            foreach ($d in @($dbs)) {
                foreach ($c in @($d.copies | Select-Object -First 3)) {
                    $lines.Add( ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f (Coalesce $c.Name), (Coalesce $c.Status), (Coalesce $c.CopyQueueLength), (Coalesce $c.ReplayQueueLength), (Coalesce $c.ContentIndexState), (Coalesce $c.ActiveCopy)) ) | Out-Null
                }
            }
            $lines.Add('') | Out-Null
        }

        $dag = Read-JsonSafe 'evidence\dag\state.json'
        if ($dag) {
            $lines.Add('### DAG Configuration') | Out-Null
            $lines.Add('| DAG | Members | Operational | Witness | Networks |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- |') | Out-Null
            foreach ($g in @($dag)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} |' -f (Coalesce $g.name), (Coalesce ($g.members -join ',')), (Coalesce ($g.operational -join ',')), (Coalesce $g.witness), (Coalesce ($g.networks -join ','))) ) | Out-Null
            }
            $lines.Add('') | Out-Null
        }

        $certs = Read-JsonSafe 'evidence\certificates\state.json'
        if ($certs) {
            $lines.Add('### Certificates') | Out-Null
            $lines.Add('| Thumbprint | Services | Expires | Subject | Status |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- |') | Out-Null
            foreach ($c in @($certs)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} |' -f (Coalesce $c.Thumbprint), (Coalesce ($c.Services -join ',')), (Coalesce $c.NotAfter), (Coalesce $c.Subject), (Coalesce $c.Status)) ) | Out-Null
            }
            $lines.Add('') | Out-Null
        }

        $connectors = Read-JsonSafe 'evidence\transport\connectors.json'
        if ($connectors) {
            $lines.Add('### Transport Connectors') | Out-Null
            $lines.Add('#### Send Connectors') | Out-Null
            $lines.Add('| Name | AddressSpaces | TLSAuthLevel | SourceServers | MaxMessageSize |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- |') | Out-Null
            foreach ($s in @($connectors.send)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} |' -f (Coalesce $s.Name), (FriendlyList $s.AddressSpaces), (Coalesce $s.TLSAuthLevel), (FriendlyList $s.SourceTransportServers), (Coalesce $s.MaxMessageSize)) ) | Out-Null
            }
            $lines.Add('') | Out-Null
            $lines.Add('#### Receive Connectors') | Out-Null
            $lines.Add('| Name | PermissionGroups | AuthMechanism | RemoteIPRanges | Bindings | MaxMessageSize |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- | --- |') | Out-Null
            foreach ($r in @($connectors.receive)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f
                    (Coalesce $r.Name),
                    (TranslateFlags $r.PermissionGroups 'Microsoft.Exchange.Data.Directory.SystemConfiguration.PermissionGroups'),
                    (TranslateFlags $r.AuthMechanism 'Microsoft.Exchange.Data.Directory.SystemConfiguration.AuthMechanisms'),
                    (FriendlyList $r.RemoteIPRanges),
                    (FriendlyList $r.Bindings),
                    (Coalesce $r.MaxMessageSize)
                )) | Out-Null
            }
            $lines.Add('') | Out-Null
        }

        $hyb = Read-JsonSafe 'evidence\hybrid\config.json'
        if ($hyb) {
            $lines.Add('### Hybrid Configuration (summary)') | Out-Null
            $lines.Add( ("- Hybrid configs: {0}" -f (@($hyb.hybridConfiguration).Count)) ) | Out-Null
            $lines.Add( ("- Intra-Org connectors: {0}" -f (@($hyb.intraOrgConnectors).Count)) ) | Out-Null
            $lines.Add('') | Out-Null
        }

        $logErrs = Read-JsonSafe 'evidence\logs\exchange-event-errors.json'
        if ($logErrs) {
            $lines.Add('### Recent Exchange Event Log Errors') | Out-Null
            $lines.Add( ("- Errors/Critical (last run window): {0}" -f (@($logErrs).Count)) ) | Out-Null
            $lines.Add('| Time | Provider | EventId | Level | Machine | Message |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- | --- |') | Out-Null
            foreach ($e in @($logErrs | Select-Object -First 20)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f (Coalesce $e.timeCreated), (Coalesce $e.provider), (Coalesce $e.id), (Coalesce $e.level), (Coalesce $e.machine), ((Coalesce $e.message) -replace '\|','|')) ) | Out-Null
            }
            if (@($logErrs).Count -gt 20) { $lines.Add(('_(truncated to first 20 of {0} events)_' -f (@($logErrs).Count))) | Out-Null }
            $lines.Add('') | Out-Null
        }

        $accepted = Read-JsonSafe 'evidence\exchange\accepted-domains.json'
        if ($accepted) {
            $lines.Add('### Accepted Domains') | Out-Null
            $lines.Add('| Name | Domain | Type | Default | MatchSubDomains |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- |') | Out-Null
            foreach ($a in @($accepted)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} |' -f (Coalesce $a.Name), (Coalesce $a.DomainName), (Coalesce $a.DomainType), (Coalesce $a.Default), (Coalesce $a.MatchSubDomains)) ) | Out-Null
            }
            $lines.Add('') | Out-Null
        }

        $vdirs = Read-JsonSafe 'evidence\exchange\virtual-directories.json'
        if ($vdirs) {
            $lines.Add('### Virtual Directories') | Out-Null
            $lines.Add('#### OWA') | Out-Null
            $lines.Add('| Name | Server | InternalUrl | ExternalUrl | Auth |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- |') | Out-Null
            foreach ($v in @($vdirs.owa)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} |' -f (Coalesce $v.Name), (Coalesce $v.Server), (Coalesce $v.InternalUrl), (Coalesce $v.ExternalUrl), (FriendlyList $v.FormsAuthentication)) ) | Out-Null
            }
            $lines.Add('') | Out-Null

            $lines.Add('#### ECP') | Out-Null
            $lines.Add('| Name | Server | InternalUrl | ExternalUrl | Auth |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- |') | Out-Null
            foreach ($v in @($vdirs.ecp)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} |' -f (Coalesce $v.Name), (Coalesce $v.Server), (Coalesce $v.InternalUrl), (Coalesce $v.ExternalUrl), (FriendlyList $v.FormsAuthentication)) ) | Out-Null
            }
            $lines.Add('') | Out-Null

            $lines.Add('#### EWS') | Out-Null
            $lines.Add('| Name | Server | InternalUrl | ExternalUrl | Auth |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- |') | Out-Null
            foreach ($v in @($vdirs.ews)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} |' -f (Coalesce $v.Name), (Coalesce $v.Server), (Coalesce $v.InternalUrl), (Coalesce $v.ExternalUrl), (FriendlyList @($v.WindowsAuthentication,$v.OAuthAuthentication,$v.BasicAuthentication))) ) | Out-Null
            }
            $lines.Add('') | Out-Null

            $lines.Add('#### OAB') | Out-Null
            $lines.Add('| Name | Server | InternalUrl | ExternalUrl | RequireSSL | Auth |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- | --- |') | Out-Null
            foreach ($v in @($vdirs.oab)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f (Coalesce $v.Name), (Coalesce $v.Server), (Coalesce $v.InternalUrl), (Coalesce $v.ExternalUrl), (Coalesce $v.RequireSSL), (FriendlyList $v.WindowsAuthentication)) ) | Out-Null
            }
            $lines.Add('') | Out-Null

            $lines.Add('#### Autodiscover') | Out-Null
            $lines.Add('| Name | Server | InternalUrl | ExternalUrl | Auth |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- |') | Out-Null
            foreach ($v in @($vdirs.autodiscover)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} |' -f (Coalesce $v.Name), (Coalesce $v.Server), (Coalesce $v.InternalUrl), (Coalesce $v.ExternalUrl), (FriendlyList $v.WindowsAuthentication)) ) | Out-Null
            }
            $lines.Add('') | Out-Null

            $lines.Add('#### MAPI') | Out-Null
            $lines.Add('| Name | Server | InternalUrl | ExternalUrl | IISAuthMethods |') | Out-Null
            $lines.Add('| --- | --- | --- | --- | --- |') | Out-Null
            foreach ($v in @($vdirs.mapi)) {
                $lines.Add( ('| {0} | {1} | {2} | {3} | {4} |' -f
                    (Coalesce $v.Name),
                    (Coalesce $v.Server),
                    (Coalesce $v.InternalUrl),
                    (Coalesce $v.ExternalUrl),
                    (TranslateFlags $v.IISAuthenticationMethods 'Microsoft.Exchange.Data.Directory.SystemConfiguration.AuthenticationMethod')
                )) | Out-Null
            }
            $lines.Add('') | Out-Null
        }

        ($lines -join "`r`n") | Set-Content -Path $Path -Encoding UTF8
    }

    $execPath = Join-Path $genRoot 'executive-summary.md'
    $techPath = Join-Path $genRoot 'technical-report.md'
    Write-ExchMarkdown -Path $execPath -Title 'Executive Summary' -Rows $Findings
    Write-ExchMarkdown -Path $techPath -Title 'Technical Report' -Rows $Findings

    # CAB-style CSV
    $cabPath = Join-Path $genRoot 'CAB-Remediation.csv'
    $rows = foreach ($f in $Findings) {
        $dom = Coalesce (Get-Prop -Obj $f -Name 'controlDomain') (Get-Prop -Obj $f -Name 'domain')
        $sev = Coalesce (Get-Prop -Obj $f -Name 'severity')
        $out = Coalesce (Get-Nested -Obj $f -Path @('result','outcome')) 'Unknown'
        $suf = Coalesce (Get-Nested -Obj $f -Path @('result','sufficiency')) 'HardFail'
        $eval = Coalesce (Get-Nested -Obj $f -Path @('meta','evaluationStatus'))

        $change = switch -Wildcard ($dom) {
            'Environment' { 'Config' }
            'Exchange' { 'Config' }
            'Upgrade' { 'Plan' }
            'Mailbox' { 'Config' }
            default { 'Config' }
        }
        $rollback = switch ($sev) { 'Critical' { 'High' } 'High' { 'High' } 'Medium' { 'Medium' } default { 'Low' } }

        $remStatus = 'Open'
        if ($out -eq 'Compliant') { $remStatus = 'Complete' }
        elseif ($out -eq 'PartiallyCompliant') { $remStatus = 'In Progress' }

        [pscustomobject]@{
            controlId         = Coalesce (Get-Prop -Obj $f -Name 'controlId')
            outcome           = $out
            sufficiency       = $suf
            severity          = $sev
            title             = Coalesce (Get-Prop -Obj $f -Name 'title')
            remediation       = Coalesce (Get-Prop -Obj $f -Name 'remediation')
            controlDomain     = $dom
            changeType        = $change
            owner             = ''
            estimatedEffort   = ''
            rollbackComplexity= $rollback
            evidenceCollected = if ($suf -eq 'Pass') { 'Yes' } elseif ($suf -eq 'SoftFail') { 'Partial' } else { 'No' }
            remediationStatus = $remStatus
            targetDate        = ''
            cabDecision       = ''
            notes             = ''
            evaluationStatus  = $eval
        }
    }
    $rows | Export-Csv -Path $cabPath -NoTypeInformation -Encoding UTF8

    # Persist findings for reference
    try { $null = Save-ExchFindings -Run $Run -Findings $Findings } catch { }

    # Word report placeholder
    $docxPath = $null
    try { $docxPath = New-ExchWordReport -Run $Run -TechMarkdownPath $techPath } catch { }

    # PDF (best-effort)
    $pdfPath = $null
    try {
        if (Get-Command pandoc -ErrorAction SilentlyContinue) {
            $pdfPath = Join-Path $genRoot 'executive-summary.pdf'
            pandoc $execPath -o $pdfPath
        }
    } catch { $pdfPath = $null }

    # Build ZIP
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $name = if ($BundleName) { $BundleName } else { "ExchEvidence-$($Run.TenantHint)-$ts" }
    $zipPath = Join-Path $Run.RunFolder "$name.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    $pathsToZip = @(
        (Join-Path $Run.RunFolder 'evidence'),
        (Join-Path $Run.RunFolder 'logs'),
        $genRoot,
        (Join-Path $Run.RunFolder 'hash-manifest.json')
    ) | Where-Object { Test-Path $_ }

    Compress-Archive -Path $pathsToZip -DestinationPath $zipPath -Force

    try { Write-ExchEvent -Run $Run -Level INFO -Message 'Bundle exported' -Data @{ zipPath=$zipPath; cabPath=$cabPath; docxPath=$docxPath; execPdf=$pdfPath } } catch { }

    return $zipPath
}

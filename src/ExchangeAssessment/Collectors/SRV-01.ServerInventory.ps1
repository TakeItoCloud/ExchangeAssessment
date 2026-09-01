<#
SRV-01 - Exchange server inventory and service health.

The inventory the rest of the assessment implies but never actually produced: how many Exchange
servers there are, what roles they hold, which Active Directory site they sit in, whether their
required services are running, and whether any server component has been left inactive.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_SRV_01_ServerInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'SRV-01'

    try { $servers = @(Get-ExchangeServer -ErrorAction Stop) }
    catch {
        $reason = "Get-ExchangeServer failed, so the organisation could not be inventoried: $($_.Exception.Message)"
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control -Reason $reason `
                -Remediation 'Run from an Exchange Management Shell with rights to enumerate servers.'
        )
    }

    if ($servers.Count -eq 0) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control `
                -Reason 'Get-ExchangeServer returned no servers, so there is no organisation to inventory.' `
                -Remediation 'Confirm the session is connected to the intended Exchange organisation.'
        )
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $activeState = [string](Get-ExchThreshold -Run $Run -Name 'Server.ActiveComponentState' -Default 'Active')
    $ignoredComponents = @(Get-ExchThreshold -Run $Run -Name 'Server.IgnoredComponents' -Default @())

    $serverRows    = New-Object System.Collections.Generic.List[object]
    $serviceRows   = New-Object System.Collections.Generic.List[object]
    $componentRows = New-Object System.Collections.Generic.List[object]

    foreach ($srv in $servers) {
        $name = [string]$srv.Name

        $serverRows.Add([pscustomobject]@{
            Name             = $name
            Fqdn             = [string]$srv.Fqdn
            Edition          = [string]$srv.Edition
            AdminDisplayVersion = [string]$srv.AdminDisplayVersion
            ServerRole       = (ConvertTo-ExchFlatValue -Value $srv.ServerRole)
            Site             = [string]$srv.Site
            IsMailboxServer  = [bool]$srv.IsMailboxServer
            IsClientAccessServer = [bool]$srv.IsClientAccessServer
            IsEdgeServer     = [bool]$srv.IsEdgeServer
            IsHubTransportServer = [bool]$srv.IsHubTransportServer
            CustomerFeedbackEnabled = (ConvertTo-ExchFlatValue -Value $srv.CustomerFeedbackEnabled)
        }) | Out-Null

        foreach ($health in @(Invoke-ExchQuery -Label ("Test-ServiceHealth on {0}" -f $name) -Errors $errors -Script { Test-ServiceHealth -Server $name -ErrorAction Stop })) {
            $notRunning = @($health.ServicesNotRunning)
            $serviceRows.Add([pscustomobject]@{
                Server              = $name
                Role                = [string]$health.Role
                RequiredServicesRunning = [bool]$health.RequiredServicesRunning
                ServicesRunning     = (ConvertTo-ExchFlatValue -Value $health.ServicesRunning)
                ServicesNotRunning  = (ConvertTo-ExchFlatValue -Value $notRunning)
                NotRunningCount     = $notRunning.Count
            }) | Out-Null
        }

        foreach ($component in @(Invoke-ExchQuery -Label ("Get-ServerComponentState on {0}" -f $name) -Errors $errors -Script { Get-ServerComponentState -Identity $name -ErrorAction Stop })) {
            $componentName = [string]$component.Component
            if ($ignoredComponents -contains $componentName) { continue }
            $state = [string]$component.State
            $componentRows.Add([pscustomobject]@{
                Server    = $name
                Component = $componentName
                State     = $state
                IsActive  = ($state -eq $activeState)
            }) | Out-Null
        }
    }

    $serverArr    = @($serverRows.ToArray())
    $serviceArr   = @($serviceRows.ToArray())
    $componentArr = @($componentRows.ToArray())

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'environment/server-inventory.json' -ContentObject ([ordered]@{
        servers    = $serverArr
        services   = $serviceArr
        components = $componentArr
        errors     = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'environment.servers' -Title 'Exchange Servers' -Area 'Environment' `
            -Columns @('Name', 'Fqdn', 'Edition', 'AdminDisplayVersion', 'ServerRole', 'Site', 'IsMailboxServer', 'IsClientAccessServer', 'IsEdgeServer', 'IsHubTransportServer', 'CustomerFeedbackEnabled') `
            -Rows $serverArr

        New-ExchInventorySection -Run $Run -Key 'environment.service-health' -Title 'Exchange Service Health' -Area 'Environment' `
            -Columns @('Server', 'Role', 'RequiredServicesRunning', 'ServicesNotRunning', 'NotRunningCount', 'ServicesRunning') `
            -Rows $serviceArr

        New-ExchInventorySection -Run $Run -Key 'environment.server-components' -Title 'Server Component States' -Area 'Environment' `
            -Columns @('Server', 'Component', 'State', 'IsActive') `
            -Rows $componentArr -HighCardinality
    )

    $stoppedServices = @($serviceArr | Where-Object { -not $_.RequiredServicesRunning })
    $inactive        = @($componentArr | Where-Object { -not $_.IsActive })
    $sites           = @($serverArr | ForEach-Object { $_.Site } | Where-Object { $_ } | Sort-Object -Unique)

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    if ($stoppedServices.Count -gt 0) {
        $problems.Add(("Required services are not running on {0} server roles: {1}" -f $stoppedServices.Count, `
            (($stoppedServices | ForEach-Object { "$($_.Server) $($_.Role) [$($_.ServicesNotRunning)]" }) -join '; '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($inactive.Count -gt 0) {
        $problems.Add(("{0} server components are not Active, so that functionality is offline: {1}" -f $inactive.Count, `
            (($inactive | ForEach-Object { "$($_.Server)/$($_.Component)=$($_.State)" }) -join ', '))) | Out-Null
        $outcomes.Add('NonCompliant') | Out-Null
    }
    if ($errors.Count -gt 0) {
        $problems.Add(("Some server health could not be read: {0}" -f ($errors -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant' { 'High' }
        'Unknown'      { 'Medium' }
        default        { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else { ("{0} Exchange servers across {1} Active Directory sites have all required services running and every component Active." -f $serverArr.Count, $sites.Count) }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Start the required Exchange services on every server and return any component left Inactive to Active once the maintenance that required it is finished.' `
        -Metrics @{
            serverCount       = $serverArr.Count
            sites             = $sites
            rolesWithStoppedServices = $stoppedServices.Count
            inactiveComponents= $inactive.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

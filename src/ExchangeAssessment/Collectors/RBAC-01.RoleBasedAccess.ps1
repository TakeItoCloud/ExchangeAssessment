<#
RBAC-01 - Role based access control and privileged group membership.

Who can do what to the Exchange organisation. Organization Management is effectively
administrative control of every mailbox in the estate, so its membership is the single most
useful number in this control.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_RBAC_01_RoleBasedAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'RBAC-01'

    $errors = New-Object System.Collections.Generic.List[string]

    $roleGroups  = @(Invoke-ExchQuery -Label 'Get-RoleGroup'              -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-RoleGroup -ErrorAction Stop })
    $assignments = @(Invoke-ExchQuery -Label 'Get-ManagementRoleAssignment' -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-ManagementRoleAssignment -ErrorAction Stop })
    $scopes      = @(Invoke-ExchQuery -Label 'Get-ManagementScope'        -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-ManagementScope -ErrorAction Stop })
    $policies    = @(Invoke-ExchQuery -Label 'Get-RoleAssignmentPolicy'   -Errors $errors -Run $Run -ControlId $control.controlId -Script { Get-RoleAssignmentPolicy -ErrorAction Stop })

    if ($roleGroups.Count -eq 0 -and @($errors | Where-Object { $_ -like 'Get-RoleGroup*' }).Count -gt 0) {
        return New-ExchCollectorResult -Findings @(
            New-ExchUnavailableFinding -Control $control `
                -Reason ("Role groups could not be read, so privileged access was not assessed: {0}" -f (($errors | Where-Object { $_ -like 'Get-RoleGroup*' }) -join '; ')) `
                -Remediation 'Run from an Exchange Management Shell with rights to read role groups and management role assignments.'
        )
    }

    $privileged = @(Get-ExchThreshold -Run $Run -Name 'Rbac.PrivilegedRoleGroups' -Default @())
    $maxOrgAdmins = [int](Get-ExchThreshold -Run $Run -Name 'Rbac.MaxOrganizationManagementMembers' -Default 5)

    $groupRows = New-Object System.Collections.Generic.List[object]
    $memberRows = New-Object System.Collections.Generic.List[object]

    foreach ($group in $roleGroups) {
        $name = [string]$group.Name
        $members = @($group.Members | ForEach-Object { [string]$_ })

        $groupRows.Add([pscustomobject]@{
            Name         = $name
            Privileged   = ($privileged -contains $name)
            MemberCount  = $members.Count
            Members      = (ConvertTo-ExchFlatValue -Value $members)
            ManagedBy    = (ConvertTo-ExchFlatValue -Value $group.ManagedBy)
            RoleGroupType= [string]$group.RoleGroupType
            Description  = (Get-ExchTruncatedText -Text ([string]$group.Description) -Length 200)
        }) | Out-Null

        foreach ($member in $members) {
            $memberRows.Add([pscustomobject]@{
                RoleGroup  = $name
                Member     = $member
                Privileged = ($privileged -contains $name)
            }) | Out-Null
        }
    }

    $assignmentRows = foreach ($a in $assignments) {
        [pscustomobject]@{
            Name              = [string]$a.Name
            Role              = [string]$a.Role
            RoleAssigneeName  = [string]$a.RoleAssigneeName
            RoleAssigneeType  = [string]$a.RoleAssigneeType
            AssignmentMethod  = [string]$a.RoleAssignmentDelegationType
            CustomRecipientWriteScope = [string]$a.CustomRecipientWriteScope
            CustomConfigWriteScope    = [string]$a.CustomConfigWriteScope
            Enabled           = (ConvertTo-ExchFlatValue -Value $a.Enabled)
        }
    }

    $scopeRows = foreach ($sc in $scopes) {
        [pscustomobject]@{
            Name             = [string]$sc.Name
            ScopeRestrictionType = [string]$sc.ScopeRestrictionType
            RecipientRoot    = [string]$sc.RecipientRoot
            RecipientFilter  = (Get-ExchTruncatedText -Text ([string]$sc.RecipientFilter) -Length 200)
            Exclusive        = (ConvertTo-ExchFlatValue -Value $sc.Exclusive)
        }
    }

    $policyRows = foreach ($pol in $policies) {
        [pscustomobject]@{
            Name        = [string]$pol.Name
            IsDefault   = (ConvertTo-ExchFlatValue -Value $pol.IsDefault)
            AssignedRoles = (ConvertTo-ExchFlatValue -Value $pol.AssignedRoles)
        }
    }

    $groupArr      = @($groupRows.ToArray())
    $memberArr     = @($memberRows.ToArray())
    $assignmentArr = @($assignmentRows)
    $scopeArr      = @($scopeRows)
    $policyArr     = @($policyRows)

    $evidence = Write-ExchEvidenceFile -Run $Run -RelativePath 'security/rbac.json' -ContentObject ([ordered]@{
        roleGroups            = $groupArr
        roleGroupMembers      = $memberArr
        managementRoleAssignments = $assignmentArr
        managementScopes      = $scopeArr
        roleAssignmentPolicies= $policyArr
        errors                = @($errors.ToArray())
    })

    $sections = @(
        New-ExchInventorySection -Run $Run -Key 'security.role-groups' -Title 'Role Groups' -Area 'Security' `
            -Columns @('Name', 'Privileged', 'MemberCount', 'Members', 'ManagedBy', 'RoleGroupType', 'Description') -Rows $groupArr

        New-ExchInventorySection -Run $Run -Key 'security.role-group-members' -Title 'Role Group Membership' -Area 'Security' `
            -Columns @('RoleGroup', 'Member', 'Privileged') -Rows $memberArr -HighCardinality

        New-ExchInventorySection -Run $Run -Key 'security.role-assignments' -Title 'Management Role Assignments' -Area 'Security' `
            -Columns @('Name', 'Role', 'RoleAssigneeName', 'RoleAssigneeType', 'AssignmentMethod', 'CustomRecipientWriteScope', 'CustomConfigWriteScope', 'Enabled') `
            -Rows $assignmentArr -HighCardinality

        New-ExchInventorySection -Run $Run -Key 'security.management-scopes' -Title 'Management Scopes' -Area 'Security' `
            -Columns @('Name', 'ScopeRestrictionType', 'RecipientRoot', 'RecipientFilter', 'Exclusive') -Rows $scopeArr

        New-ExchInventorySection -Run $Run -Key 'security.role-assignment-policies' -Title 'Role Assignment Policies' -Area 'Security' `
            -Columns @('Name', 'IsDefault', 'AssignedRoles') -Rows $policyArr
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $outcomes = New-Object System.Collections.Generic.List[string]

    $orgManagement = @($groupArr | Where-Object { $_.Name -eq 'Organization Management' }) | Select-Object -First 1
    if ($orgManagement -and $orgManagement.MemberCount -gt $maxOrgAdmins) {
        $problems.Add(("Organization Management has {0} members, above the {1} expected for this organisation. That group is effectively administrative control of every mailbox: {2}" -f `
            $orgManagement.MemberCount, $maxOrgAdmins, $orgManagement.Members)) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    $emptyPrivileged = @($groupArr | Where-Object { $_.Privileged -and $_.MemberCount -eq 0 })
    $delegating = @($assignmentArr | Where-Object { $_.AssignmentMethod -eq 'Delegating' })
    if ([bool](Get-ExchThreshold -Run $Run -Name 'Rbac.FlagDelegatingAssignments' -Default $true) -and $delegating.Count -gt 0) {
        $problems.Add(("{0} delegating role assignments exist, which let their holder grant the same role to others: {1}" -f $delegating.Count, `
            (($delegating | Select-Object -First 10 | ForEach-Object { "$($_.Role) to $($_.RoleAssigneeName)" }) -join ', '))) | Out-Null
        $outcomes.Add('PartiallyCompliant') | Out-Null
    }

    if ($errors.Count -gt 0) {
        $problems.Add(("Some role configuration could not be read: {0}" -f ($errors -join '; '))) | Out-Null
        $outcomes.Add('Unknown') | Out-Null
    }
    if ($problems.Count -eq 0) { $outcomes.Add('Compliant') | Out-Null }

    $outcome = Get-ExchWorstOutcome -Outcomes $outcomes.ToArray()
    $severity = switch ($outcome) {
        'NonCompliant'       { 'High' }
        'PartiallyCompliant' { 'Medium' }
        'Unknown'            { 'Medium' }
        default              { 'Low' }
    }

    $rationale = if ($problems.Count -gt 0) { ($problems -join '. ') + '.' }
                 else { ("{0} role groups hold {1} memberships in total; Organization Management has {2} members, within the expected {3}." -f `
                        $groupArr.Count, $memberArr.Count, $(if ($orgManagement) { $orgManagement.MemberCount } else { 0 }), $maxOrgAdmins) }
    if ($emptyPrivileged.Count -gt 0) {
        $rationale += (" {0} privileged role groups are empty, which is fine and worth knowing: {1}." -f `
            $emptyPrivileged.Count, (($emptyPrivileged | ForEach-Object { $_.Name }) -join ', '))
    }

    $finding = New-ExchControlFinding -Control $control -Severity $severity -Outcome $outcome `
        -Sufficiency $(if ($errors.Count -gt 0) { 'SoftFail' } else { 'Pass' }) `
        -Rationale $rationale `
        -Evidence @($evidence) `
        -Remediation 'Review every member of Organization Management against who genuinely needs organisation-wide control, and move the rest to a narrower role group. Confirm each delegating assignment is deliberate, since its holder can grant the same role onward.' `
        -Metrics @{
            roleGroups          = $groupArr.Count
            memberships         = $memberArr.Count
            organizationManagementMembers = $(if ($orgManagement) { $orgManagement.MemberCount } else { 0 })
            roleAssignments     = $assignmentArr.Count
            delegatingAssignments = $delegating.Count
            managementScopes    = $scopeArr.Count
        } `
        -Meta @{ dataSources = @{ Exchange = @{ state = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Success' }); reason = ($errors -join '; ') } }; evaluationStatus = 'Complete' }

    return New-ExchCollectorResult -Sections $sections -Findings @($finding)
}

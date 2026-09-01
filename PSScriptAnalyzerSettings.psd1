@{
    # Run the full set of built-in PSScriptAnalyzer rules...
    IncludeDefaultRules = $true

    # ...but only fail on findings that actually matter for a shipped tool.
    Severity            = @('Error', 'Warning')

    # Two rules stay suppressed. Both are cosmetic here, and both are wrong for this codebase
    # rather than work that is merely outstanding - so unlike the pair that used to sit
    # alongside them, they are not a backlog row waiting to be cleared.
    #
    #   PSUseSingularNouns   7 hits - six are collector functions whose name encodes the control
    #                        they implement (Invoke-ExchCollector_CERT_01_Certificates), and the
    #                        seventh is Save-ExchFindings, which genuinely saves all of them.
    #                        Renaming any of these would make the name less accurate, not more.
    #   PSUseShouldProcessForStateChangingFunctions
    #                        8 hits - all on New-* factory functions. New-ExchFinding,
    #                        New-ExchInventorySection and New-ExchCollectorResult build in-memory
    #                        objects and change nothing at all; New-ExchRun and
    #                        New-ExchAssessmentJson write only inside the run folder. The
    #                        assessment is read-only against Exchange and Active Directory, which
    #                        is enforced by the read-only cmdlet test in the Pester suite rather
    #                        than by this rule.
    #
    # PSAvoidUsingEmptyCatchBlock and PSUseApprovedVerbs were suppressed here until the
    # collectors were reworked. Both are clean now and the suppressions are gone, so a silently
    # swallowed failure fails the build.
    ExcludeRules        = @(
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
    )

    # Rules this tool relies on, named explicitly so they survive future changes to the
    # analyzer defaults.
    Rules               = @{
        PSAvoidUsingWriteHost                 = @{ Enable = $true }
        PSUseDeclaredVarsMoreThanAssignments  = @{ Enable = $true }
        PSPossibleIncorrectComparisonWithNull = @{ Enable = $true }
        PSAvoidUsingEmptyCatchBlock           = @{ Enable = $true }

        # The module runs inside the Exchange Management Shell, which is Windows PowerShell.
        PSUseCompatibleSyntax                 = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}

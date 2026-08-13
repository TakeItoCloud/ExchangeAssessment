@{
    # Run the full set of built-in PSScriptAnalyzer rules...
    IncludeDefaultRules = $true

    # ...but only fail on findings that actually matter for a shipped tool.
    Severity            = @('Error', 'Warning')

    # Rules suspended for the code inherited from infra-scripting-suite. Each is a real
    # backlog row in PORT-PLAN.md (phase P2), not a permanent waiver.
    #   PSAvoidUsingEmptyCatchBlock 19 hits - collectors swallow per-control failures, so a
    #                               control that could not be evaluated is indistinguishable
    #                               from one that passed. The findings model already has
    #                               'Unknown' / 'HardFail' outcomes for exactly this; the
    #                               catches need to use them.
    #   PSUseSingularNouns           7 hits - e.g. Get-ExchAcceptedDomains,
    #                               Get-ExchVirtualDirectories. Internal to the module.
    #   PSUseShouldProcessForStateChangingFunctions
    #                                3 hits - New-*/Save-*/Export-* write to the run folder.
    #                               The assessment is read-only against Exchange.
    #   PSUseApprovedVerbs           2 hits - Ensure-ExchLocalShell, Ensure-ExchADModule,
    #                               both private.
    ExcludeRules        = @(
        'PSAvoidUsingEmptyCatchBlock'
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseApprovedVerbs'
    )

    # Rules this tool relies on, named explicitly so they survive future changes to the
    # analyzer defaults.
    Rules               = @{
        PSAvoidUsingWriteHost                 = @{ Enable = $true }
        PSUseDeclaredVarsMoreThanAssignments  = @{ Enable = $true }
        PSPossibleIncorrectComparisonWithNull = @{ Enable = $true }

        # The module runs inside the Exchange Management Shell, which is Windows PowerShell.
        PSUseCompatibleSyntax                 = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}

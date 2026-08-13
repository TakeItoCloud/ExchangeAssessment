<#
ENV.VERS-01 - Domain/forest functional level and schema readiness.
#>

Set-StrictMode -Version Latest

function Invoke-ExchCollector_ENV_VERS_01_DomainForestSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $ErrorActionPreference = 'Stop'
    $control = Get-ExchControlById -ControlId 'ENV.VERS-01'

    try { Ensure-ExchADModule -Run $Run }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'ActiveDirectory module unavailable' -Data @{ error=$_.Exception.Message }
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'High' -Title $control.title -Description $control.target -Evidence @() -Remediation 'Install/enable the ActiveDirectory module on the Exchange server.' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale 'ActiveDirectory module missing; unable to query domain/forest.' -Metrics @{}
    }

    try {
        $root = Get-ADRootDSE -ErrorAction Stop
        $forest = Get-ADForest -ErrorAction Stop
        $domain = Get-ADDomain -ErrorAction Stop

        $schemaVersion = [int]($root.schemaVersion | Select-Object -First 1)
        $forestMode = $forest.ForestMode.ToString()
        $domainMode = $domain.DomainMode.ToString()

        $evidenceObj = [ordered]@{
            rootDse        = $root
            forest         = $forest
            domain         = $domain
            schemaVersion  = $schemaVersion
        }

        $evidencePath = Write-ExchEvidenceFile -Run $Run -RelativePath 'environment/domain-forest-schema.json' -ContentObject $evidenceObj

        $forestOk = $forestMode -match '2016|2019|2022'
        $domainOk = $domainMode -match '2016|2019|2022'
        $schemaOk = $schemaVersion -ge 87

        $outcome = 'Unknown'
        $suff = 'Pass'
        $sev = 'Medium'
        $rat = ''

        if ($forestOk -and $domainOk -and $schemaOk) {
            $outcome = 'Compliant'
            $rat = 'Forest/domain functional levels and schema meet Exchange 2016+ baseline.'
        }
        elseif (-not ($forestOk -and $domainOk)) {
            $outcome = 'NonCompliant'
            $sev = 'High'
            $rat = 'Forest/domain functional level below Windows Server 2016.'
        }
        elseif (-not $schemaOk) {
            $outcome = 'PartiallyCompliant'
            $sev = 'High'
            $rat = 'Schema version below Exchange 2016 baseline; extend schema before upgrades.'
        }

        return New-ExchFinding `
            -ControlDomain $control.domain `
            -ControlId $control.controlId `
            -Severity $sev `
            -Title $control.title `
            -Description $control.target `
            -Evidence @($evidencePath) `
            -Remediation 'Raise forest/domain functional level to Windows Server 2016+ and ensure Exchange schema extensions are applied.' `
            -FrameworkMappings $control.mappings `
            -Outcome $outcome `
            -Sufficiency $suff `
            -Rationale $rat `
            -Metrics @{
                forestMode   = $forestMode
                domainMode   = $domainMode
                schemaVersion= $schemaVersion
            } `
            -Meta @{ dataSources = @{ ActiveDirectory = @{ state='Success'; reason='' } }; evaluationStatus = 'Complete' }
    }
    catch {
        Write-ExchEvent -Run $Run -Level ERROR -Message 'ENV.VERS-01 failed' -Data @{ error=$_.Exception.Message }
        return New-ExchFinding -ControlDomain $control.domain -ControlId $control.controlId -Severity 'High' -Title $control.title -Description $control.target -Evidence @() -Remediation 'Confirm Exchange server can query Active Directory (RootDSE/forest/domain).' -FrameworkMappings $control.mappings -Outcome 'Unknown' -Sufficiency 'HardFail' -Rationale 'Unable to query domain/forest/schema details.' -Metrics @{ error=$_.Exception.Message } -Meta @{ dataSources = @{ ActiveDirectory = @{ state='Error'; reason=$_.Exception.Message } }; evaluationStatus = 'Partial' }
    }
}

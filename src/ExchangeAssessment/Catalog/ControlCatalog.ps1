<#
Control catalog for Exchange On-Prem/Hybrid Assessment (starter set).
#>

Set-StrictMode -Version Latest

function Get-ExchControlCatalog {
    [CmdletBinding()]
    param()

    $controls = @(
        @{
            controlId = 'ENV.VERS-01'
            domain    = 'Environment'
            title     = 'Domain/forest functional level and schema readiness'
            target    = 'Forest/domain functional level and Exchange schema support at least Exchange Server 2016+; schema version meets deployment requirements.'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.5.23'; note='Change control for directory services' }
                @{ framework='NIS2'; ref='Infrastructure resilience'; note='Directory services underpin messaging availability' }
            )
        },
        @{
            controlId = 'ENV.OS-01'
            domain    = 'Environment'
            title     = 'Exchange server OS supportability'
            target    = 'Exchange servers run supported Windows Server versions (2022 preferred for Subscription Edition readiness).'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.8.8'; note='Secure configuration and platform supportability' }
                @{ framework='CISv8'; ref='4.1'; note='Establish and maintain secure configuration process' }
            )
        },
        @{
            controlId = 'EX.CH-01'
            domain    = 'Exchange'
            title     = 'Exchange build and cumulative update currency'
            target    = 'Exchange servers run supported builds/CUs with required security updates applied.'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.8.8'; note='Keeping software up to date' }
                @{ framework='CISv8'; ref='7.3'; note='Apply vendor-supported updates' }
            )
        },
        @{
            controlId = 'UPG-01'
            domain    = 'Upgrade'
            title     = 'Exchange SE readiness (roll-up)'
            target    = 'Prereqs for Exchange Server Subscription Edition met: supported OS, functional levels, schema, and Exchange CU.'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.5.30'; note='Plan changes for platform upgrades' }
                @{ framework='NIS2'; ref='Modernization'; note='Roadmap for supported messaging platform' }
            )
        },
        @{
            controlId = 'MB.DB-01'
            domain    = 'Mailbox'
            title     = 'Mailbox database health and copy status'
            target    = 'Mailbox databases are mounted/active, copies are healthy, and replication/queue health is monitored.'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.8.16'; note='Monitoring activities (service health)' }
                @{ framework='CISv8'; ref='5.1'; note='Establish and maintain service inventory/health' }
            )
        },
        @{
            controlId = 'DAG-01'
            domain    = 'Mailbox'
            title     = 'Database Availability Group health'
            target    = 'DAG members, quorum, and networks are healthy with no failed copies.'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.8.14'; note='Redundancy for availability' }
                @{ framework='NIS2'; ref='Business continuity'; note='Resilient messaging platform' }
            )
        },
        @{
            controlId = 'TR.CO-01'
            domain    = 'Transport'
            title     = 'Transport connector posture'
            target    = 'Send/receive connectors are configured with appropriate auth, scoping, size limits, and no open relays.'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.5.7'; note='Threat protection (mail flow)' }
                @{ framework='CISv8'; ref='9.2'; note='Email protections' }
            )
        },
        @{
            controlId = 'CERT-01'
            domain    = 'Certificate'
            title     = 'Certificate bindings and expiry'
            target    = 'Exchange services use valid certificates with no imminent expiry and correct bindings.'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.8.8'; note='Crypto and platform configuration' }
                @{ framework='CISv8'; ref='4.6'; note='Use of approved cryptography' }
            )
        },
        @{
            controlId = 'MB.AV-01'
            domain    = 'Mailbox'
            title     = 'Exchange anti-malware/AV exclusions'
            target    = 'Exchange servers have required anti-malware exclusions applied (processes/paths) to avoid service impact while maintaining protection.'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.8.7'; note='Protection against malware' }
                @{ framework='CISv8'; ref='10.5'; note='Configure enterprise anti-malware' }
            )
        },
        @{
            controlId = 'AA.SPAM-01'
            domain    = 'Security'
            title     = 'Anti-spam/anti-malware posture'
            target    = 'Mail hygiene (on-prem/EOP) policies are enabled and thresholds enforced; malware scanning is active.'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.8.7'; note='Protection against malware (mail hygiene)' }
                @{ framework='CISv8'; ref='9.7'; note='Deploy and maintain email anti-malware protections' }
            )
        },
        @{
            controlId = 'HYB-01'
            domain    = 'Hybrid'
            title     = 'Hybrid configuration and OAuth'
            target    = 'Hybrid Configuration Wizard applied; connectors and OAuth/free-busy are configured and healthy.'
            mappings  = @(
                @{ framework='NIS2'; ref='Integration security'; note='Secure hybrid connectivity' }
            )
        },
        @{
            controlId = 'ID.SYNC-01'
            domain    = 'Identity'
            title     = 'AAD Connect synchronization health'
            target    = 'AAD Connect (or successor) sync is present, running, and recent; errors are addressed.'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.5.16'; note='Identity management (hybrid)' }
                @{ framework='NIS2'; ref='Identity and access'; note='Reliable directory sync to cloud' }
            )
        },
        @{
            controlId = 'LOG.EX-01'
            domain    = 'Monitoring'
            title     = 'Recent Exchange-related event log errors'
            target    = 'Exchange-related services show no recent critical/error events in Application/System logs within the review window.'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.8.16'; note='Monitoring activities (service health)' }
                @{ framework='CISv8'; ref='8.2'; note='Collect and review event logs' }
            )
        },
        @{
            controlId = 'EX.ADM-01'
            domain    = 'Exchange'
            title     = 'Accepted domains inventory'
            target    = 'Accepted domains are inventoried and categorized (Authoritative/InternalRelay/ExternalRelay).'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.5.7'; note='Mail domain governance' }
            )
        },
        @{
            controlId = 'EX.VDIR-01'
            domain    = 'Exchange'
            title     = 'Virtual directories configuration'
            target    = 'OWA/ECP/EWS/OAB/Autodiscover/MAPI virtual directories have defined internal/external URLs and appropriate authentication.'
            mappings  = @(
                @{ framework='ISO27001:2022'; ref='A.8.8'; note='Secure service configuration' }
            )
        }
    )

    return $controls
}

function Get-ExchControlById {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ControlId)

    $catalog = Get-ExchControlCatalog
    $c = $catalog | Where-Object { $_.controlId -eq $ControlId } | Select-Object -First 1
    if (-not $c) { throw "ControlId not found: $ControlId" }
    return $c
}

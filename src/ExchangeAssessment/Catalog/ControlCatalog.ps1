<#
Control catalog for the Exchange On-Prem/Hybrid Assessment.

Each control states what "good" looks like (target), which frameworks it maps to, and the
authoritative Microsoft article behind it. The references travel with every finding into
assessment.json, so a reader working from the JSON alone can check the tool's reasoning against
the vendor rather than taking it on trust.
#>

Set-StrictMode -Version Latest

function Get-ExchControlCatalog {
    [CmdletBinding()]
    param()

    $controls = @(
        @{
            controlId  = 'ENV.VERS-01'
            domain     = 'Environment'
            title      = 'Domain/forest functional level and schema readiness'
            target     = 'Forest and domain functional levels are supported for the installed Exchange version, and Active Directory is prepared to the target Exchange schema and object versions.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.23'; note='Change control for directory services' }
                @{ framework='NIS2'; ref='Infrastructure resilience'; note='Directory services underpin messaging availability' }
            )
            references = @(
                @{ title='Supported Active Directory environments'; url='https://learn.microsoft.com/exchange/plan-and-deploy/supportability-matrix#supported-active-directory-environments' }
                @{ title='Exchange Active Directory versions'; url='https://learn.microsoft.com/exchange/plan-and-deploy/prepare-ad-and-domains#exchange-active-directory-versions' }
            )
        },
        @{
            controlId  = 'ENV.OS-01'
            domain     = 'Environment'
            title      = 'Exchange server OS supportability'
            target     = 'Exchange servers run a Windows Server version supported for the installed Exchange release, with enough free disk and a recent reboot.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.8'; note='Secure configuration and platform supportability' }
                @{ framework='CISv8'; ref='4.1'; note='Establish and maintain secure configuration process' }
            )
            references = @(
                @{ title='Supported operating systems for Exchange Server'; url='https://learn.microsoft.com/exchange/plan-and-deploy/supportability-matrix#supported-operating-systems' }
            )
        },
        @{
            controlId  = 'EX.CH-01'
            domain     = 'Exchange'
            title      = 'Exchange build and cumulative update currency'
            target     = 'Exchange servers run a supported product version on a current build with security updates applied, and the organisation is not left in a mixed-version state.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.8'; note='Keeping software up to date' }
                @{ framework='CISv8'; ref='7.3'; note='Apply vendor-supported updates' }
            )
            references = @(
                @{ title='Exchange Server build numbers and release dates'; url='https://learn.microsoft.com/exchange/new-features/build-numbers-and-release-dates' }
                @{ title='Exchange Server 2019 and 2016 end of support roadmap'; url='https://learn.microsoft.com/troubleshoot/exchange/administration/exchange-2019-2016-end-of-support' }
                @{ title='Exchange Server supportability matrix'; url='https://learn.microsoft.com/exchange/plan-and-deploy/supportability-matrix' }
            )
        },
        @{
            controlId  = 'UPG-01'
            domain     = 'Upgrade'
            title      = 'Exchange SE readiness (roll-up)'
            target     = 'Prerequisites for Exchange Server Subscription Edition are met: supported OS, supported functional levels, prepared Active Directory, and a build that supports the upgrade path.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.30'; note='Plan changes for platform upgrades' }
                @{ framework='NIS2'; ref='Modernization'; note='Roadmap for supported messaging platform' }
            )
            references = @(
                @{ title='Upgrading to Exchange Server Subscription Edition (SE)'; url='https://learn.microsoft.com/exchange/plan-and-deploy/deploy-new-installations/upgrade-to-exchange-server-se' }
            )
        },
        @{
            controlId  = 'MB.DB-01'
            domain     = 'Mailbox'
            title      = 'Mailbox database health and copy status'
            target     = 'Mailbox databases are mounted, copies are healthy with short queues and a healthy content index, and every database has a recent full backup.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.16'; note='Monitoring activities (service health)' }
                @{ framework='CISv8'; ref='5.1'; note='Establish and maintain service inventory/health' }
            )
            references = @(
                @{ title='Get-MailboxDatabaseCopyStatus'; url='https://learn.microsoft.com/powershell/module/exchange/get-mailboxdatabasecopystatus' }
                @{ title='Managing mailbox database copies'; url='https://learn.microsoft.com/exchange/high-availability/manage-ha/manage-mailbox-database-copies' }
            )
        },
        @{
            controlId  = 'DAG-01'
            domain     = 'Mailbox'
            title      = 'Database Availability Group health'
            target     = 'DAG members are operational, a witness is configured so quorum can be held, and replication networks are present.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.14'; note='Redundancy for availability' }
                @{ framework='NIS2'; ref='Business continuity'; note='Resilient messaging platform' }
            )
            references = @(
                @{ title='Database availability groups'; url='https://learn.microsoft.com/exchange/high-availability/database-availability-groups/database-availability-groups' }
            )
        },
        @{
            controlId  = 'TR.CO-01'
            domain     = 'Transport'
            title      = 'Transport connector posture'
            target     = 'Send and receive connectors are scoped, authenticated and size-limited, internet send connectors require TLS, and no receive connector grants ms-Exch-SMTP-Accept-Any-Recipient to an anonymous or externally secured principal from an unrestricted address range.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.7'; note='Threat protection (mail flow)' }
                @{ framework='CISv8'; ref='9.2'; note='Email protections' }
            )
            references = @(
                @{ title='Receive connectors'; url='https://learn.microsoft.com/exchange/mail-flow/connectors/receive-connectors' }
                @{ title='Allow anonymous relay on Exchange servers'; url='https://learn.microsoft.com/exchange/mail-flow/connectors/allow-anonymous-relay' }
            )
        },
        @{
            controlId  = 'CERT-01'
            domain     = 'Certificate'
            title      = 'Certificate bindings and expiry'
            target     = 'Exchange services are bound to valid, trusted certificates with adequate key size and no imminent expiry.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.8'; note='Crypto and platform configuration' }
                @{ framework='CISv8'; ref='4.6'; note='Use of approved cryptography' }
            )
            references = @(
                @{ title='Certificate requirements for Exchange Server'; url='https://learn.microsoft.com/exchange/architecture/client-access/certificates' }
            )
        },
        @{
            controlId  = 'MB.AV-01'
            domain     = 'Mailbox'
            title      = 'Exchange anti-malware/AV exclusions'
            target     = 'Every Exchange server has the Microsoft-recommended folder and process exclusions applied to its anti-malware product.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.7'; note='Protection against malware' }
                @{ framework='CISv8'; ref='10.5'; note='Configure enterprise anti-malware' }
            )
            references = @(
                @{ title='Running Windows antivirus software on Exchange servers'; url='https://learn.microsoft.com/exchange/antispam-and-antimalware/windows-antivirus-software' }
            )
        },
        @{
            controlId  = 'AA.SPAM-01'
            domain     = 'Security'
            title      = 'Anti-spam/anti-malware posture'
            target     = 'Malware filtering is enabled, anti-spam agents are installed and running, and content filter thresholds are set rather than left at defaults.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.7'; note='Protection against malware (mail hygiene)' }
                @{ framework='CISv8'; ref='9.7'; note='Deploy and maintain email anti-malware protections' }
            )
            references = @(
                @{ title='Anti-spam protection in Exchange Server'; url='https://learn.microsoft.com/exchange/antispam-and-antimalware/antispam-protection/antispam-protection' }
                @{ title='Anti-malware protection in Exchange Server'; url='https://learn.microsoft.com/exchange/antispam-and-antimalware/antimalware-protection/antimalware-protection' }
            )
        },
        @{
            controlId  = 'HYB-01'
            domain     = 'Hybrid'
            title      = 'Hybrid configuration and OAuth'
            target     = 'Where hybrid is deployed, the Hybrid Configuration Wizard has been run and OAuth, intra-organization connectors and organization relationships are configured.'
            mappings   = @(
                @{ framework='NIS2'; ref='Integration security'; note='Secure hybrid connectivity' }
            )
            references = @(
                @{ title='Exchange Server hybrid deployments'; url='https://learn.microsoft.com/exchange/exchange-hybrid' }
                @{ title='Configure OAuth authentication between Exchange and Exchange Online'; url='https://learn.microsoft.com/exchange/configure-oauth-authentication-between-exchange-and-exchange-online-organizations-exchange-2013-help' }
            )
        },
        @{
            controlId  = 'ID.SYNC-01'
            domain     = 'Identity'
            title      = 'Directory synchronisation health'
            target     = 'Directory synchronisation to Entra ID is present, running, and has completed a cycle recently.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.16'; note='Identity management (hybrid)' }
                @{ framework='NIS2'; ref='Identity and access'; note='Reliable directory sync to cloud' }
            )
            references = @(
                @{ title='Microsoft Entra Connect Sync: scheduler'; url='https://learn.microsoft.com/entra/identity/hybrid/connect/how-to-connect-sync-feature-scheduler' }
            )
        },
        @{
            controlId  = 'LOG.EX-01'
            domain     = 'Monitoring'
            title      = 'Recent Exchange-related event log errors'
            target     = 'Exchange-related providers show no sustained pattern of critical or error events in the review window.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.16'; note='Monitoring activities (service health)' }
                @{ framework='CISv8'; ref='8.2'; note='Collect and review event logs' }
            )
            references = @(
                @{ title='Exchange Server monitoring and health'; url='https://learn.microsoft.com/exchange/architecture/mailbox-servers/mailbox-servers' }
            )
        },
        @{
            controlId  = 'EX.ADM-01'
            domain     = 'Exchange'
            title      = 'Accepted and remote domain configuration'
            target     = 'Accepted domains are inventoried and correctly typed, external relay domains are deliberate, and remote domain settings do not leak internal detail.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.7'; note='Mail domain governance' }
            )
            references = @(
                @{ title='Accepted domains in Exchange Server'; url='https://learn.microsoft.com/exchange/mail-flow/accepted-domains/accepted-domains' }
                @{ title='Remote domains in Exchange Server'; url='https://learn.microsoft.com/exchange/mail-flow/remote-domains/remote-domains' }
            )
        },
        @{
            controlId  = 'SRV-01'
            domain     = 'Environment'
            title      = 'Exchange server inventory and service health'
            target     = 'Every Exchange server is inventoried with its roles and site, all required services are running, and no server component is left inactive.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.9'; note='Inventory of information and other associated assets' }
                @{ framework='CISv8'; ref='2.1'; note='Establish and maintain a software inventory' }
            )
            references = @(
                @{ title='Get-ExchangeServer'; url='https://learn.microsoft.com/powershell/module/exchange/get-exchangeserver' }
                @{ title='Server component states in Exchange Server'; url='https://learn.microsoft.com/exchange/high-availability/manage-ha/server-component-states' }
            )
        },
        @{
            controlId  = 'TR.CFG-01'
            domain     = 'Transport'
            title      = 'Organisation and server transport configuration'
            target     = 'Organisation-wide transport limits, safety-net and shadow redundancy settings, per-server transport configuration, and transport and journal rules are inventoried and sane.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.9'; note='Configuration management' }
                @{ framework='CISv8'; ref='4.1'; note='Secure configuration process' }
            )
            references = @(
                @{ title='Get-TransportConfig'; url='https://learn.microsoft.com/powershell/module/exchange/get-transportconfig' }
                @{ title='Shadow redundancy in Exchange Server'; url='https://learn.microsoft.com/exchange/mail-flow/transport-high-availability/shadow-redundancy' }
                @{ title='Safety Net in Exchange Server'; url='https://learn.microsoft.com/exchange/mail-flow/transport-high-availability/safety-net' }
            )
        },
        @{
            controlId  = 'REPL-01'
            domain     = 'Mailbox'
            title      = 'Mailbox replication and client connectivity health'
            target     = 'Test-ReplicationHealth passes on every DAG member and mailbox databases answer MAPI connectivity checks.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.14'; note='Redundancy of information processing facilities' }
                @{ framework='NIS2'; ref='Business continuity'; note='Replication underpins mailbox availability' }
            )
            references = @(
                @{ title='Test-ReplicationHealth'; url='https://learn.microsoft.com/powershell/module/exchange/test-replicationhealth' }
                @{ title='Test-MAPIConnectivity'; url='https://learn.microsoft.com/powershell/module/exchange/test-mapiconnectivity' }
            )
        },
        @{
            controlId  = 'EX.VDIR-01'
            domain     = 'Exchange'
            title      = 'Virtual directories configuration'
            target     = 'Client access virtual directories have internal and external URLs set, present them consistently across servers, enforce HTTPS, and do not expose Basic authentication.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.8'; note='Secure service configuration' }
            )
            references = @(
                @{ title='Configure Exchange Server virtual directories'; url='https://learn.microsoft.com/exchange/clients/configure-virtual-directories' }
                @{ title='Disable Basic authentication in Exchange Server'; url='https://learn.microsoft.com/exchange/clients-and-mobile-in-exchange-online/disable-basic-authentication-in-exchange-online' }
            )
        }
        @{
            controlId  = 'TR.QUE-01'
            domain     = 'Transport'
            title      = 'Transport queue depth and age'
            target     = 'No transport queue is backing up or holding messages beyond the acceptable age, and no queue is in a retry or suspended state.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.16'; note='Monitoring activities (mail flow)' }
            )
            references = @(
                @{ title='Queues and messages in queues'; url='https://learn.microsoft.com/exchange/mail-flow/queues/queues' }
                @{ title='Get-Queue'; url='https://learn.microsoft.com/powershell/module/exchange/get-queue' }
            )
        },
        @{
            controlId  = 'RBAC-01'
            domain     = 'Security'
            title      = 'Role based access control and privileged group membership'
            target     = 'Privileged Exchange role groups have a small, known membership; no unexpected delegation grants organisation-wide management rights.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.15'; note='Access control' }
                @{ framework='ISO27001:2022'; ref='A.8.2'; note='Privileged access rights' }
                @{ framework='CISv8'; ref='5.4'; note='Restrict administrator privileges to dedicated accounts' }
            )
            references = @(
                @{ title='Understanding role based access control'; url='https://learn.microsoft.com/exchange/permissions/role-based-access-control' }
                @{ title='Built-in management role groups'; url='https://learn.microsoft.com/exchange/permissions/role-groups' }
            )
        },
        @{
            controlId  = 'MB.INV-01'
            domain     = 'Mailbox'
            title      = 'Mailbox, quota and archive inventory'
            target     = 'Mailboxes are inventoried with their database, size, quota and archive state; none is at or over its send quota and none has unexpected forwarding configured.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.9'; note='Inventory of information and associated assets' }
                @{ framework='ISO27001:2022'; ref='A.8.12'; note='Data leakage prevention (forwarding)' }
            )
            references = @(
                @{ title='Get-Mailbox'; url='https://learn.microsoft.com/powershell/module/exchange/get-mailbox' }
                @{ title='Configure storage quotas for a mailbox'; url='https://learn.microsoft.com/exchange/recipients/user-mailboxes/mailbox-storage-quotas' }
            )
        },
        @{
            controlId  = 'RET-01'
            domain     = 'Compliance'
            title      = 'Retention, holds and audit configuration'
            target     = 'Retention policies and tags are defined and applied, litigation hold state is known, and administrator and mailbox audit logging is enabled.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.33'; note='Protection of records' }
                @{ framework='ISO27001:2022'; ref='A.8.15'; note='Logging' }
                @{ framework='CISv8'; ref='8.2'; note='Collect audit logs' }
            )
            references = @(
                @{ title='Retention tags and retention policies'; url='https://learn.microsoft.com/exchange/policy-and-compliance/mrm/retention-tags-and-retention-policies' }
                @{ title='Administrator audit logging'; url='https://learn.microsoft.com/exchange/policy-and-compliance/admin-audit-logging/admin-audit-logging' }
            )
        },
        @{
            controlId  = 'CAS-01'
            domain     = 'Client'
            title      = 'Client access policies and legacy authentication'
            target     = 'Mobile device and Outlook on the web policies are defined, legacy protocols are constrained, and Basic authentication is blocked by an authentication policy.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.5'; note='Secure authentication' }
                @{ framework='CISv8'; ref='6.4'; note='Require MFA for remote access' }
            )
            references = @(
                @{ title='Disable Basic authentication in Exchange Server'; url='https://learn.microsoft.com/exchange/clients-and-mobile-in-exchange-online/disable-basic-authentication-in-exchange-online' }
                @{ title='Mobile device mailbox policies'; url='https://learn.microsoft.com/exchange/clients/exchange-activesync/mobile-device-mailbox-policies' }
            )
        },
        @{
            controlId  = 'AL-01'
            domain     = 'Exchange'
            title      = 'Address lists and offline address book'
            target     = 'Address lists, the global address list and offline address books are defined and the OAB has a generating mailbox.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.9'; note='Configuration management' }
            )
            references = @(
                @{ title='Address lists in Exchange Server'; url='https://learn.microsoft.com/exchange/address-books/address-lists/address-lists' }
                @{ title='Offline address books in Exchange Server'; url='https://learn.microsoft.com/exchange/address-books/offline-address-books/offline-address-books' }
            )
        },
        @{
            controlId  = 'PF-01'
            domain     = 'Exchange'
            title      = 'Public folder deployment'
            target     = 'Public folder mailboxes and hierarchy are inventoried, a primary hierarchy mailbox exists, and no legacy public folder database remains.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.9'; note='Inventory of information and associated assets' }
            )
            references = @(
                @{ title='Public folders in Exchange Server'; url='https://learn.microsoft.com/exchange/collaboration/public-folders/public-folders' }
            )
        },
        @{
            controlId  = 'TLS-01'
            domain     = 'Security'
            title      = 'TLS protocol and .NET cryptography configuration'
            target     = 'TLS 1.2 is enabled and the deprecated SSL and TLS protocols are disabled for both client and server, .NET is configured for strong cryptography and system default TLS versions, and Exchange serialised data signing is enabled.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.24'; note='Use of cryptography' }
                @{ framework='CISv8'; ref='3.10'; note='Encrypt sensitive data in transit' }
            )
            references = @(
                @{ title='Exchange Server TLS configuration best practices'; url='https://learn.microsoft.com/exchange/exchange-tls-configuration' }
                @{ title='Configure Exchange Server for serialized data signing'; url='https://learn.microsoft.com/powershell/module/exchange/get-authconfig' }
            )
        },
        @{
            controlId  = 'PTCH-01'
            domain     = 'Security'
            title      = 'Security update state and emergency mitigations'
            target     = 'Exchange servers carry a current security update, the Exchange Emergency Mitigation Service is available and applying mitigations, and no server is exposed to a known unpatched vulnerability.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.8'; note='Management of technical vulnerabilities' }
                @{ framework='CISv8'; ref='7.4'; note='Perform automated application patch management' }
            )
            references = @(
                @{ title='Exchange Emergency Mitigation Service'; url='https://learn.microsoft.com/exchange/exchange-emergency-mitigation-service' }
                @{ title='Exchange Server build numbers and release dates'; url='https://learn.microsoft.com/exchange/new-features/build-numbers-and-release-dates' }
            )
        },
        @{
            controlId  = 'DNS-01'
            domain     = 'Network'
            title      = 'External mail DNS posture'
            target     = 'Every authoritative accepted domain publishes MX, a restrictive SPF record, and a DMARC policy.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.7'; note='Threat intelligence and mail domain abuse' }
                @{ framework='CISv8'; ref='9.5'; note='Implement DMARC' }
            )
            references = @(
                @{ title='How SPF prevents spoofing'; url='https://learn.microsoft.com/defender-office-365/email-authentication-spf-configure' }
                @{ title='Use DMARC to validate email'; url='https://learn.microsoft.com/defender-office-365/email-authentication-dmarc-configure' }
            )
        }
        @{
            controlId  = 'CLD.ORG-01'
            domain     = 'Cloud'
            title      = 'Exchange Online organisation configuration'
            target     = 'The tenant organisation configuration and accepted domains are inventoried, modern authentication is on, and no domain is left unverified.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.9'; note='Inventory of information and associated assets' }
                @{ framework='ISO27001:2022'; ref='A.8.5'; note='Secure authentication' }
            )
            references = @(
                @{ title='Get-OrganizationConfig (Exchange Online)'; url='https://learn.microsoft.com/powershell/module/exchangepowershell/get-organizationconfig' }
                @{ title='Manage accepted domains in Exchange Online'; url='https://learn.microsoft.com/exchange/mail-flow-best-practices/manage-accepted-domains/manage-accepted-domains' }
            )
        },
        @{
            controlId  = 'CLD.CONN-01'
            domain     = 'Cloud'
            title      = 'Exchange Online mail flow connectors'
            target     = 'Inbound and outbound connectors are scoped and require TLS, and no connector accepts mail from anywhere without validation.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.7'; note='Threat protection (mail flow)' }
                @{ framework='CISv8'; ref='9.2'; note='Email protections' }
            )
            references = @(
                @{ title='Configure mail flow using connectors in Exchange Online'; url='https://learn.microsoft.com/exchange/mail-flow-best-practices/use-connectors-to-configure-mail-flow/use-connectors-to-configure-mail-flow' }
            )
        },
        @{
            controlId  = 'CLD.SEC-01'
            domain     = 'Cloud'
            title      = 'Exchange Online mail hygiene and Defender policies'
            target     = 'Anti-spam, anti-malware and anti-phishing policies exist and are tightened from their defaults, and Safe Links and Safe Attachments are in place where licensed.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.8.7'; note='Protection against malware' }
                @{ framework='CISv8'; ref='9.7'; note='Deploy and maintain email anti-malware protections' }
            )
            references = @(
                @{ title='Recommended settings for EOP and Defender for Office 365 security'; url='https://learn.microsoft.com/defender-office-365/recommended-settings-for-eop-and-office365' }
                @{ title='Anti-phishing policies in Microsoft 365'; url='https://learn.microsoft.com/defender-office-365/anti-phishing-policies-about' }
            )
        },
        @{
            controlId  = 'CLD.MIG-01'
            domain     = 'Cloud'
            title      = 'Exchange Online migration endpoints and batches'
            target     = 'Migration endpoints are configured for the hybrid move path and no migration batch is left failed or stalled.'
            mappings   = @(
                @{ framework='ISO27001:2022'; ref='A.5.30'; note='ICT readiness for business continuity' }
            )
            references = @(
                @{ title='Migration endpoints in Exchange Online'; url='https://learn.microsoft.com/powershell/module/exchangepowershell/get-migrationendpoint' }
                @{ title='Move mailboxes between on-premises and Exchange Online'; url='https://learn.microsoft.com/exchange/hybrid-deployment/move-mailboxes' }
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

function Get-ExchControlReference {
    <#
    The references for a control, as the hashtable array New-ExchFinding expects.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Control)

    if ($null -eq $Control) { return @() }
    if ($Control -is [System.Collections.IDictionary] -and $Control.Contains('references')) {
        return @($Control['references'])
    }
    return @()
}

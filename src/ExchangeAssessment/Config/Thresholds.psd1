<#
Every value this tool judges against, in one place.

Nothing here is baked into collector code. A collector reads a threshold, compares the data it
collected, and reports what it found. To assess a client whose baseline differs, copy the keys
you want to change into your own .psd1 and pass it with -ConfigPath; the values you supply are
merged over these defaults and everything you leave out keeps the default.

Sources are named per section. Where a value is a judgement call rather than a Microsoft
statement it says so.
#>
@{
    # --------------------------------------------------------------------------------------
    # Exchange Server support state
    # https://learn.microsoft.com/exchange/plan-and-deploy/supportability-matrix
    # https://learn.microsoft.com/troubleshoot/exchange/administration/exchange-2019-2016-end-of-support
    # Exchange 2016 and Exchange 2019 both reached end of support on 2025-10-14. Exchange
    # Server SE is the only supported version.
    # --------------------------------------------------------------------------------------
    Exchange = @{
        # Product families keyed by the major.minor of AdminDisplayVersion.
        Families = @(
            @{ Major = 15; Minor = 2; MinBuild = 2562; Name = 'Exchange Server SE'; Supported = $true;  EndOfSupport = '' }
            @{ Major = 15; Minor = 2; MinBuild = 0;    Name = 'Exchange Server 2019'; Supported = $false; EndOfSupport = '2025-10-14' }
            @{ Major = 15; Minor = 1; MinBuild = 0;    Name = 'Exchange Server 2016'; Supported = $false; EndOfSupport = '2025-10-14' }
            @{ Major = 15; Minor = 0; MinBuild = 0;    Name = 'Exchange Server 2013'; Supported = $false; EndOfSupport = '2023-04-11' }
            @{ Major = 14; Minor = 0; MinBuild = 0;    Name = 'Exchange Server 2010'; Supported = $false; EndOfSupport = '2020-10-13' }
        )

        # Running more than one product family at once is a migration state, not a steady one.
        FlagMixedVersions = $true

        # Security updates ship out of band. A server more than this many days behind the
        # newest build known to Config/BuildTable.psd1 is called out. Judgement call, not a
        # Microsoft figure - raise it for organisations with a slower patch window.
        MaxBuildAgeDays = 180

        # The build table is a point-in-time copy of a Microsoft page. Past this age the
        # assessment says so, because judging build currency against a stale reference is a
        # weaker statement than judging it against a fresh one. Judgement call, not a
        # Microsoft figure.
        MaxBuildTableAgeDays = 60
    }

    # --------------------------------------------------------------------------------------
    # Operating system
    # https://learn.microsoft.com/exchange/plan-and-deploy/supportability-matrix#supported-operating-systems
    # Verified 2026-09-02. The supported operating system list is per Exchange version, not
    # global: Exchange Server SE and Exchange Server 2019 support Windows Server 2025, 2022 and
    # 2019; Exchange Server 2016 supports Windows Server 2016, 2012 R2 and 2012. Exchange 2016's
    # set therefore has an upper bound as well as a floor, which is why SupportedBuilds is an
    # explicit list rather than a minimum.
    # --------------------------------------------------------------------------------------
    OperatingSystem = @{
        # Product must match a Name in Exchange.Families. An Exchange version with no row here
        # is reported as not assessable rather than as unsupported.
        SupportMatrix = @(
            @{ Product = 'Exchange Server SE';   MinimumBuild = '10.0.17763'; RecommendedBuild = '10.0.20348'; SupportedBuilds = @('10.0.26100', '10.0.20348', '10.0.17763') }
            @{ Product = 'Exchange Server 2019'; MinimumBuild = '10.0.17763'; RecommendedBuild = '10.0.20348'; SupportedBuilds = @('10.0.26100', '10.0.20348', '10.0.17763') }
            @{ Product = 'Exchange Server 2016'; MinimumBuild = '6.2.9200';   RecommendedBuild = '10.0.14393'; SupportedBuilds = @('10.0.14393', '6.3.9600', '6.2.9200') }
        )
        KnownBuilds      = @(
            @{ Build = '10.0.26100'; Name = 'Windows Server 2025' }
            @{ Build = '10.0.20348'; Name = 'Windows Server 2022' }
            @{ Build = '10.0.17763'; Name = 'Windows Server 2019' }
            @{ Build = '10.0.14393'; Name = 'Windows Server 2016' }
            @{ Build = '6.3.9600';   Name = 'Windows Server 2012 R2' }
            @{ Build = '6.2.9200';   Name = 'Windows Server 2012' }
        )
        # An Exchange server that has not rebooted in this long has pending updates it has not
        # finished applying. Judgement call.
        MaxUptimeDays        = 90
        MinFreeDiskPercent   = 15
        MinFreeDiskGB        = 20
    }

    # --------------------------------------------------------------------------------------
    # Active Directory
    # https://learn.microsoft.com/exchange/plan-and-deploy/prepare-ad-and-domains#exchange-active-directory-versions
    # https://learn.microsoft.com/exchange/plan-and-deploy/supportability-matrix#supported-active-directory-environments
    # Exchange SE supports forest functional level Windows Server 2016 or 2012 R2.
    # --------------------------------------------------------------------------------------
    ActiveDirectory = @{
        # Verified 2026-09-02 against the supportability matrix linked above. Microsoft lists
        # Windows Server 2016 and Windows Server 2012 R2 as the forest functional levels for
        # Exchange Server SE and Exchange Server 2019. Windows Server 2025 introduced functional
        # level 10, and Microsoft has not added it to the Exchange matrix - so it is deliberately
        # absent here rather than assumed to be supported.
        SupportedForestModes   = @('Windows2012R2Forest', 'Windows2016Forest')
        RecommendedForestModes = @('Windows2016Forest')
        SupportedDomainModes   = @('Windows2012R2Domain', 'Windows2016Domain')
        RecommendedDomainModes = @('Windows2016Domain')

        # A Schema Master running Windows Server 2025 must be on this build or later before any
        # Exchange /PrepareSchema or /PrepareAD (KB5068861, November 2025). See the Important box
        # under Supported Active Directory environments in the supportability matrix.
        MinimumSchemaMaster2025Build = '10.0.26100.7171'

        # Exchange AD preparation state. rangeUpper lives on ms-Exch-Schema-Version-Pt in the
        # schema NC; objectVersion (Default) on the Microsoft Exchange System Objects container
        # in the default NC; objectVersion (Configuration) on the organisation container under
        # Services > Microsoft Exchange in the configuration NC.
        TargetSchemaRangeUpper           = 17003   # Exchange SE RTM
        TargetObjectVersionDefault       = 13243   # Exchange SE RTM
        TargetObjectVersionConfiguration = 16763   # Exchange SE RTM

        # Reported so an operator can name what the organisation is prepared for. Verified
        # 2026-09-02 against https://learn.microsoft.com/exchange/plan-and-deploy/prepare-ad-and-domains
        # Each rangeUpper/objectVersion pair appears exactly once; where several cumulative
        # updates share a pair the row names the range. A directory whose pair is not listed
        # reports an unrecognised preparation level, which is honest - the numeric comparison
        # against the target values is made regardless of whether a name was matched.
        KnownPreparationLevels = @(
            @{ RangeUpper = 17003; ConfigVersion = 16763; Name = 'Exchange SE RTM / Exchange 2019 CU15' }
            @{ RangeUpper = 17003; ConfigVersion = 16762; Name = 'Exchange 2019 CU14' }
            @{ RangeUpper = 17003; ConfigVersion = 16761; Name = 'Exchange 2019 CU13' }
            @{ RangeUpper = 17003; ConfigVersion = 16760; Name = 'Exchange 2019 CU12' }
            @{ RangeUpper = 17003; ConfigVersion = 16759; Name = 'Exchange 2019 CU11' }
            @{ RangeUpper = 17003; ConfigVersion = 16758; Name = 'Exchange 2019 CU10' }
            @{ RangeUpper = 17002; ConfigVersion = 16757; Name = 'Exchange 2019 CU9' }
            @{ RangeUpper = 17002; ConfigVersion = 16756; Name = 'Exchange 2019 CU8' }
            @{ RangeUpper = 17001; ConfigVersion = 16755; Name = 'Exchange 2019 CU7' }
            @{ RangeUpper = 17000; ConfigVersion = 16752; Name = 'Exchange 2019 CU1' }
            @{ RangeUpper = 17000; ConfigVersion = 16751; Name = 'Exchange 2019 RTM' }
            @{ RangeUpper = 17001; ConfigVersion = 16754; Name = 'Exchange 2019 CU2-CU6' }
            @{ RangeUpper = 15334; ConfigVersion = 16223; Name = 'Exchange 2016 CU23' }
            @{ RangeUpper = 15334; ConfigVersion = 16222; Name = 'Exchange 2016 CU22' }
            @{ RangeUpper = 15334; ConfigVersion = 16221; Name = 'Exchange 2016 CU21' }
            @{ RangeUpper = 15333; ConfigVersion = 16220; Name = 'Exchange 2016 CU20' }
            @{ RangeUpper = 15333; ConfigVersion = 16219; Name = 'Exchange 2016 CU19' }
            @{ RangeUpper = 15332; ConfigVersion = 16218; Name = 'Exchange 2016 CU18' }
            @{ RangeUpper = 15332; ConfigVersion = 16217; Name = 'Exchange 2016 CU13-CU17' }
            @{ RangeUpper = 15332; ConfigVersion = 16215; Name = 'Exchange 2016 CU12' }
            @{ RangeUpper = 15332; ConfigVersion = 16214; Name = 'Exchange 2016 CU11' }
            @{ RangeUpper = 15332; ConfigVersion = 16213; Name = 'Exchange 2016 CU7-CU10' }
            @{ RangeUpper = 15330; ConfigVersion = 16213; Name = 'Exchange 2016 CU6' }
            @{ RangeUpper = 15326; ConfigVersion = 16213; Name = 'Exchange 2016 CU4-CU5' }
            @{ RangeUpper = 15326; ConfigVersion = 16212; Name = 'Exchange 2016 CU3' }
            @{ RangeUpper = 15325; ConfigVersion = 16212; Name = 'Exchange 2016 CU2' }
            @{ RangeUpper = 15323; ConfigVersion = 16211; Name = 'Exchange 2016 CU1' }
            @{ RangeUpper = 15317; ConfigVersion = 16210; Name = 'Exchange 2016 RTM' }
            @{ RangeUpper = 15312; ConfigVersion = 16133; Name = 'Exchange 2013 CU23' }
            @{ RangeUpper = 15312; ConfigVersion = 16131; Name = 'Exchange 2013 CU22' }
            @{ RangeUpper = 15312; ConfigVersion = 16130; Name = 'Exchange 2013 CU10-CU21' }
            @{ RangeUpper = 15312; ConfigVersion = 15965; Name = 'Exchange 2013 CU7-CU9' }
            @{ RangeUpper = 15303; ConfigVersion = 15965; Name = 'Exchange 2013 CU6' }
            @{ RangeUpper = 15300; ConfigVersion = 15870; Name = 'Exchange 2013 CU5' }
            @{ RangeUpper = 15292; ConfigVersion = 15844; Name = 'Exchange 2013 SP1' }
            @{ RangeUpper = 15283; ConfigVersion = 15763; Name = 'Exchange 2013 CU3' }
            @{ RangeUpper = 15281; ConfigVersion = 15688; Name = 'Exchange 2013 CU2' }
            @{ RangeUpper = 15254; ConfigVersion = 15614; Name = 'Exchange 2013 CU1' }
            @{ RangeUpper = 15137; ConfigVersion = 15449; Name = 'Exchange 2013 RTM' }
        )
    }

    # --------------------------------------------------------------------------------------
    # Certificates
    # --------------------------------------------------------------------------------------
    Certificate = @{
        ExpiryCriticalDays = 30
        ExpiryWarningDays  = 90
        MinKeySize         = 2048
        # A service listed here with no valid certificate bound is a finding.
        RequiredBoundServices = @('IIS', 'SMTP')
        FlagSelfSigned        = $true
        WeakSignatureAlgorithms = @('md5RSA', 'sha1RSA')
    }

    # --------------------------------------------------------------------------------------
    # Databases and replication
    # --------------------------------------------------------------------------------------
    Database = @{
        HealthyCopyStatuses     = @('Healthy', 'Mounted', 'DisconnectedAndHealthy')
        HealthyContentIndex     = @('Healthy', 'HealthyAndUpgrading')
        CopyQueueLengthWarning  = 10
        CopyQueueLengthCritical = 100
        ReplayQueueLengthWarning  = 10
        ReplayQueueLengthCritical = 100
        # A database whose last full backup is older than this has no usable restore point.
        MaxBackupAgeDays        = 7
        FlagCircularLogging     = $true
        # Databases beyond this size are called out for review, not failed.
        LargeDatabaseGB         = 200
    }

    Dag = @{
        # A DAG with an even member count and no witness cannot hold quorum.
        RequireWitness       = $true
        MinMembersForQuorum  = 2
        RequireAlternateWitness = $false
        # Whether this organisation is expected to provide mailbox high availability at all.
        # A standalone deployment is a legitimate design, so the default is to report the
        # absence of a DAG rather than fail it. Set this true for a client whose service level
        # requires database copies and automatic failover.
        RequireHighAvailability = $false
    }

    # --------------------------------------------------------------------------------------
    # Transport
    # --------------------------------------------------------------------------------------
    Transport = @{
        # The Anonymous users permission group, and the remote ranges that cover the whole
        # address space. Both describe Microsoft's own Default Frontend connector, so neither is
        # a verdict on its own - see AnonymousSecurityPrincipals below.
        AnonymousPermissionGroups = @('AnonymousUsers')
        UnrestrictedRemoteRanges  = @('0.0.0.0-255.255.255.255', '0.0.0.0/0', '::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff', '::/0')

        # What actually grants relay.
        # https://learn.microsoft.com/exchange/mail-flow/connectors/receive-connectors
        # https://learn.microsoft.com/exchange/mail-flow/connectors/allow-anonymous-relay
        # The Anonymous users permission group maps to NT AUTHORITY\ANONYMOUS LOGON and grants
        # accept-any-sender and submit, but NOT ms-Exch-SMTP-Accept-Any-Recipient - the right
        # that lets a client relay through the connector. That right reaches an anonymous caller
        # only when it is granted explicitly on the connector, or through the ExchangeServers
        # permission group combined with the externally secured authentication mechanism.
        AnonymousSecurityPrincipals      = @('NT AUTHORITY\ANONYMOUS LOGON', 'ANONYMOUS LOGON')
        RelayPermission                  = 'ms-Exch-SMTP-Accept-Any-Recipient'
        ExternallySecuredAuthMechanism   = 'ExternalAuthoritative'
        ExternallySecuredPermissionGroup = 'ExchangeServers'
        # Send connectors to the internet should require TLS.
        RequiredSendTlsAuthLevels = @('EncryptionOnly', 'CertificateValidation', 'DomainValidation')
        DiscouragedAuthMechanisms = @('BasicAuth')
        QueueLengthWarning        = 100
        QueueLengthCritical       = 500
        MaxQueueAgeHours          = 4
        # Organisation transport configuration. Shadow redundancy and Safety Net protect
        # in-flight mail across a transport failure; both are on by default and turning them
        # off is a deliberate, and usually regrettable, choice.
        RequireShadowRedundancy   = $true
        RequireSafetyNet          = $true
        MinSafetyNetHoldTimeHours = 2
        # An organisation-wide limit far above what the connectors allow is misleading rather
        # than harmful, so this is reported for review rather than failed.
        ReviewMaxReceiveSizeMB    = 150
    }

    # --------------------------------------------------------------------------------------
    # Server inventory and service health
    # https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/services-overview
    # --------------------------------------------------------------------------------------
    Server = @{
        # Component states that mean a server is deliberately out of service. Reported, and
        # failed only when the operator has not also put the server into maintenance.
        ActiveComponentState = 'Active'
        IgnoredComponents    = @('ForwardSyncDaemon', 'ProvisioningRps')
    }

    # --------------------------------------------------------------------------------------
    # Replication
    # https://learn.microsoft.com/powershell/module/exchange/test-replicationhealth
    # --------------------------------------------------------------------------------------
    Replication = @{
        PassingResults = @('Passed')
        # Checks that are informational on a healthy single-copy database.
        IgnoredChecks  = @()
    }

    # --------------------------------------------------------------------------------------
    # Virtual directories and client access
    # --------------------------------------------------------------------------------------
    VirtualDirectory = @{
        RequireExternalUrl     = @('owa', 'ecp', 'ews', 'oab', 'mapi', 'activesync')
        RequireHttps           = $true
        # Basic authentication on an internet-facing directory is a credential-theft path.
        FlagBasicAuthentication = $true
        # Every server should present the same external URL for a given directory type.
        RequireConsistentUrls   = $true
    }

    # --------------------------------------------------------------------------------------
    # Anti-malware exclusions
    # https://learn.microsoft.com/exchange/antispam-and-antimalware/windows-antivirus-software
    # --------------------------------------------------------------------------------------
    AntiVirus = @{
        RequiredPathTokens = @(
            'Microsoft\Exchange Server'
            'TransportRoles'
            'ClientAccess'
            'Mailbox'
            'GroupMetrics'
            'Logging'
        )
        RequiredProcessTokens = @(
            'Microsoft.Exchange.Store.Worker.exe'
            'Microsoft.Exchange.Store.Service.exe'
            'EdgeTransport.exe'
            'MSExchangeHMWorker.exe'
            'MSExchangeDelivery.exe'
            'MSExchangeSubmission.exe'
            'MSExchangeTransport.exe'
            'MSExchangeTransportLogSearch.exe'
            'MSExchangeCompliance.exe'
            'MSExchangeMailboxAssistants.exe'
            'MSExchangeRepl.exe'
            'w3wp.exe'
            'noderunner.exe'
        )
    }

    # --------------------------------------------------------------------------------------
    # Event log review
    # --------------------------------------------------------------------------------------
    EventLog = @{
        HoursBack  = 24
        MaxEvents  = 500
        Providers  = @('MSExchange*', 'MSExchangeIS', 'MSExchangeTransport', 'MSExchangeCommon', 'MSExchange ADAccess', 'FIPFS', 'MSFilteringEngine', 'IIS-W3SVC-WP')
        # Event IDs that are noisy in a healthy organisation. Counted, never failed on.
        NoiseEventIds = @(1008, 2937, 4999)
        # Fewer distinct errors than this in the window is reported, not failed.
        ErrorCountWarning  = 1
        ErrorCountCritical = 25
    }

    # --------------------------------------------------------------------------------------
    # Identity synchronisation
    # --------------------------------------------------------------------------------------
    DirectorySync = @{
        MaxSyncAgeHours = 3
    }

    # --------------------------------------------------------------------------------------
    # TLS
    # https://learn.microsoft.com/exchange/plan-and-deploy/post-installation-tasks/security-best-practices/exchange-tls-configuration
    # --------------------------------------------------------------------------------------
    Tls = @{
        RequiredEnabledProtocols  = @('TLS 1.2')
        RequiredDisabledProtocols = @('SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1')
        RequireStrongCryptoDotNet = $true
    }

    # --------------------------------------------------------------------------------------
    # DNS posture. Checked against the organisation's authoritative accepted domains.
    # --------------------------------------------------------------------------------------
    Dns = @{
        RequireSpf   = $true
        RequireDmarc = $true
        # An SPF record ending +all accepts mail from anywhere.
        DiscouragedSpfAll = @('+all', '?all')
        RequireMx    = $true
    }

    # --------------------------------------------------------------------------------------
    # Role based access control
    # https://learn.microsoft.com/exchange/permissions/role-groups
    # --------------------------------------------------------------------------------------
    Rbac = @{
        # Role groups that grant organisation-wide control. Membership beyond the count below
        # is reported for review - the right number is a client decision, not a fixed rule.
        PrivilegedRoleGroups = @(
            'Organization Management'
            'Recipient Management'
            'Server Management'
            'Discovery Management'
            'Hygiene Management'
            'Compliance Management'
        )
        MaxOrganizationManagementMembers = 5
        # Management role assignments scoped to the whole organisation and delegated to a
        # non-standard security group are worth a look.
        FlagDelegatingAssignments = $true
    }

    # --------------------------------------------------------------------------------------
    # Mailbox inventory
    # --------------------------------------------------------------------------------------
    Mailbox = @{
        # Percentage of the send quota at which a mailbox is called out.
        QuotaWarningPercent = 90
        # Mailboxes larger than this are reported for review.
        LargeMailboxGB      = 50
        # Forwarding to an address outside the organisation is a data-egress path.
        FlagExternalForwarding = $true
        # Cap the enumeration so a very large organisation cannot make a run take hours.
        # 0 means no cap.
        MaxMailboxes        = 5000
    }

    # --------------------------------------------------------------------------------------
    # Retention, holds and audit
    # --------------------------------------------------------------------------------------
    Compliance = @{
        RequireRetentionPolicy      = $true
        RequireAdminAuditLogging    = $true
        MinAdminAuditLogAgeDays     = 90
        RequireMailboxAuditLogging  = $true
    }

    # --------------------------------------------------------------------------------------
    # Client access
    # --------------------------------------------------------------------------------------
    ClientAccess = @{
        # An authentication policy that blocks legacy Basic authentication should exist and be
        # set as the organisation default.
        RequireAuthenticationPolicy = $true
        RequireDefaultAuthPolicy    = $true
        # Protocols that should be off unless a business case exists.
        DiscouragedProtocols        = @('PopEnabled', 'ImapEnabled')
        RequireMobileDevicePolicy   = $true
        # Devices that have not synchronised in this long are stale registrations.
        StaleDeviceDays             = 90
    }

    # --------------------------------------------------------------------------------------
    # Public folders
    # --------------------------------------------------------------------------------------
    PublicFolder = @{
        FlagLegacyPublicFolderDatabase = $true
        MaxItemsPerFolder              = 10000
        # Whether this organisation is expected to have public folders at all. Most modern
        # deployments do not, so the default is to report their absence as a fact. Set this true
        # for a client whose applications depend on them.
        RequirePublicFolders           = $false
    }

    # --------------------------------------------------------------------------------------
    # Security updates and mitigations
    # --------------------------------------------------------------------------------------
    Patch = @{
        RequireMitigationService = $true
        # Windows updates older than this suggest the patch cycle has stalled.
        MaxHotfixAgeDays         = 60
    }

    # --------------------------------------------------------------------------------------
    # Exchange Online
    # https://learn.microsoft.com/powershell/exchange/connect-to-exchange-online-powershell
    # --------------------------------------------------------------------------------------
    Cloud = @{
        # Exchange Online and on-premises Exchange share cmdlet names. The tenant session is
        # always imported with this prefix so the two can never be confused - Get-AcceptedDomain
        # becomes Get-CloudAcceptedDomain. Change it only if it collides with something else in
        # the session.
        CommandPrefix = 'Cloud'
        # An inbound connector that accepts mail from any address without requiring TLS or a
        # certificate is the cloud equivalent of an open relay.
        RequireConnectorTls = $true
        # Anti-spam and anti-phish policies that were never tightened from the defaults.
        RequireAntiPhishPolicy = $true
        RequireSafeAttachments = $true
        RequireSafeLinks       = $true
        # A migration batch that has been sitting in a failed or stalled state.
        MaxMigrationBatchAgeDays = 30
    }

    # --------------------------------------------------------------------------------------
    # Reporting
    # --------------------------------------------------------------------------------------
    MaxRowsPerSection = 500
    # assessment.json splits into per-area parts above this size so that each part stays
    # small enough to upload.
    MaxAssessmentJsonBytes = 8388608
}

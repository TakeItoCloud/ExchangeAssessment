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
        # newest build known to BuildTable.ps1 is called out. Judgement call, not a Microsoft
        # figure - raise it for organisations with a slower patch window.
        MaxBuildAgeDays = 180
    }

    # --------------------------------------------------------------------------------------
    # Operating system
    # https://learn.microsoft.com/exchange/plan-and-deploy/supportability-matrix#supported-operating-systems
    # Exchange Server SE supports Windows Server 2019, 2022 and 2025.
    # --------------------------------------------------------------------------------------
    OperatingSystem = @{
        MinimumBuild     = '10.0.17763'   # Windows Server 2019 - the floor for Exchange SE
        RecommendedBuild = '10.0.20348'   # Windows Server 2022
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
        SupportedForestModes   = @('Windows2012R2Forest', 'Windows2016Forest', 'Windows2025Forest')
        RecommendedForestModes = @('Windows2016Forest', 'Windows2025Forest')
        SupportedDomainModes   = @('Windows2012R2Domain', 'Windows2016Domain', 'Windows2025Domain')
        RecommendedDomainModes = @('Windows2016Domain', 'Windows2025Domain')

        # Exchange AD preparation state. rangeUpper lives on ms-Exch-Schema-Version-Pt in the
        # schema NC; objectVersion (Default) on the Microsoft Exchange System Objects container
        # in the default NC; objectVersion (Configuration) on the organisation container under
        # Services > Microsoft Exchange in the configuration NC.
        TargetSchemaRangeUpper           = 17003   # Exchange SE RTM
        TargetObjectVersionDefault       = 13243   # Exchange SE RTM
        TargetObjectVersionConfiguration = 16763   # Exchange SE RTM

        # Reported so an operator can name what the organisation is prepared for.
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
        # Receive connectors offering these permission groups to unrestricted remote ranges are
        # open relays.
        AnonymousPermissionGroups = @('AnonymousUsers')
        UnrestrictedRemoteRanges  = @('0.0.0.0-255.255.255.255', '0.0.0.0/0', '::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff', '::/0')
        # Send connectors to the internet should require TLS.
        RequiredSendTlsAuthLevels = @('EncryptionOnly', 'CertificateValidation', 'DomainValidation')
        DiscouragedAuthMechanisms = @('BasicAuth')
        QueueLengthWarning        = 100
        QueueLengthCritical       = 500
        MaxQueueAgeHours          = 4
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
    # Reporting
    # --------------------------------------------------------------------------------------
    MaxRowsPerSection = 500
    # assessment.json splits into per-area parts above this size so that each part stays
    # small enough to upload.
    MaxAssessmentJsonBytes = 8388608
}

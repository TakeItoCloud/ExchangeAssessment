<#
Exchange Server SE prerequisites for a server that will become an Exchange server (Mailbox role).

Read by DEP.TGT-01. Every value was read on Microsoft Learn on the date in its Read field, from the
URL in its Source field. A prerequisite Learn does not state is $null here, with a Note saying what
is missing, and DEP.TGT-01 reports that check Unknown - it never substitutes a number from memory.

Microsoft updates these pages as operating systems, .NET Framework releases and Exchange updates
ship, so this file goes stale. It carries the date it was last refreshed. To assess against a newer
reading without editing the module, copy the file, change the values, move TableAsOf, and pass the
copy with -PrereqTablePath. A $null here can be filled the same way by an operator who has verified
the value themselves; the check then judges against it.

Refresh: re-read every Source URL, change what changed, move TableAsOf and every Read date that was
re-read, and note it in CHANGELOG.md.

One key is one check. A test counts the keys under Prerequisites from this file's text and holds
the count to the number of checks DEP.TGT-01 runs per server, so a key cannot be added or dropped
without the test noticing.
#>
@{
    TableAsOf = '2026-09-11'
    Source    = 'https://learn.microsoft.com/exchange/plan-and-deploy/prerequisites'

    Prerequisites = @{
        # Supported operating systems for Exchange Server SE: Windows Server 2025, 2022 and 2019.
        # The matrix names the products; the release information page gives their build numbers
        # (OS build 26100, 20348 and 17763). Judged on major.minor.build of Win32_OperatingSystem.Version.
        OperatingSystemBuild = @{
            Value  = @('10.0.26100', '10.0.20348', '10.0.17763')
            Source = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/supportability-matrix#supported-operating-systems'
                'https://learn.microsoft.com/windows/release-health/windows-server-release-info'
            )
            Read   = '2026-09-11'
            Note   = 'Windows Server 2025 (26100), Windows Server 2022 (20348), Windows Server 2019 (17763).'
        }

        # Supported editions for Exchange Server SE: Datacenter and Standard, Desktop Experience or
        # Server Core (Server Core recommended). Judged on Win32_OperatingSystem.OperatingSystemSKU,
        # whose values Learn lists: 7 Standard and 8 Datacenter (Desktop Experience installation),
        # 12 Datacenter Server Core, 13 Standard Server Core, 147 Datacenter and 148 Standard
        # (Server Core installation). Datacenter: Azure Edition (407) is a separate edition the
        # matrix does not list, so it is not included.
        OperatingSystemEdition = @{
            Value  = @(7, 8, 12, 13, 147, 148)
            Source = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/supportability-matrix#supported-operating-systems'
                'https://learn.microsoft.com/windows/win32/cimwin32prov/win32-operatingsystem'
            )
            Read   = '2026-09-11'
            Note   = 'OperatingSystemSKU values for the Standard and Datacenter editions.'
        }

        # Minimum .NET Framework Release value, per operating system build. The matrix lists
        # .NET Framework 4.8.1 (recommended) or 4.8 for Exchange Server SE on Windows Server 2025
        # and 2022. The .NET page gives 528040 as the minimum Release value for 4.8 (533320 for
        # 4.8.1), read from HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full.
        # Windows Server 2019 is $null: the matrix's .NET Framework table has no Exchange Server SE
        # row for Windows Server 2019 (only Exchange 2019 CU14/CU15 on it, with .NET 4.8).
        DotNetFrameworkRelease = @{
            Value  = @{
                '10.0.26100' = 528040
                '10.0.20348' = 528040
                '10.0.17763' = $null
            }
            Source = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/supportability-matrix#net-framework'
                'https://learn.microsoft.com/dotnet/framework/install/how-to-determine-which-versions-are-installed'
            )
            Read   = '2026-09-11'
            Note   = 'Not documented for Exchange Server SE on Windows Server 2019: the supportability matrix .NET Framework table has no such row.'
        }

        # Visual C++ Redistributable Package for Visual Studio 2012 - a Mailbox role prerequisite.
        # Value is the uninstall-key DisplayName it is found under. The UCMA 4.0 pages list the
        # component as "Microsoft Visual C++ 2012 Redistributable (x64) 11.0.50727"; the x64 package
        # is what UCMA 4.0 is built on.
        VisualCppRedistributable2012 = @{
            Value  = 'Microsoft Visual C++ 2012 Redistributable (x64)*'
            Source = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/prerequisites#exchange-server-mailbox-server-role'
                'https://learn.microsoft.com/lync/ucma-sdk/installing-ucma-4-0-sdk'
            )
            Read   = '2026-09-11'
            Note   = 'Found by DisplayName in the uninstall keys.'
        }

        # Minimum version of the Visual C++ 2012 package. Exchange names and links the package but
        # states no minimum version. For reference only, the Visual C++ page lists 11.0.61030.0 as
        # the latest Visual Studio 2012 Update 4 build; that is not an Exchange requirement.
        VisualCppRedistributable2012Version = @{
            Value      = $null
            PackageKey = 'VisualCppRedistributable2012'
            Source     = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/prerequisites#exchange-server-mailbox-server-role'
                'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist'
            )
            Read       = '2026-09-11'
            Note       = 'Exchange documents no minimum Visual C++ 2012 version.'
        }

        # Visual C++ Redistributable Package for Visual Studio 2013 - a Mailbox role prerequisite.
        # $null: Learn does not document the uninstall DisplayName the package registers under, so
        # there is no documented name to look for.
        VisualCppRedistributable2013 = @{
            Value  = $null
            Source = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/prerequisites#exchange-server-mailbox-server-role'
                'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist'
            )
            Read   = '2026-09-11'
            Note   = 'Required by Exchange, but Learn does not document the uninstall DisplayName of the Visual C++ 2013 package.'
        }

        # Minimum version of the Visual C++ 2013 package. Exchange states no minimum version. For
        # reference only, the Visual C++ page lists 12.0.40664.0 as the latest 2013 build.
        VisualCppRedistributable2013Version = @{
            Value      = $null
            PackageKey = 'VisualCppRedistributable2013'
            Source     = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/prerequisites#exchange-server-mailbox-server-role'
                'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist'
            )
            Read       = '2026-09-11'
            Note       = 'Exchange documents no minimum Visual C++ 2013 version.'
        }

        # Unified Communications Managed API 4.0 Runtime - a Mailbox role prerequisite. Value is the
        # Programs and Features entry name the UCMA 4.0 Runtime page tells you to uninstall.
        UcmaRuntime = @{
            Value  = 'Microsoft Unified Communications Managed API 4.0, Runtime'
            Source = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/prerequisites#exchange-server-mailbox-server-role'
                'https://learn.microsoft.com/lync/ucma-sdk/ucma-4-0-runtime'
            )
            Read   = '2026-09-11'
            Note   = 'Found by DisplayName in the uninstall keys.'
        }

        # Minimum UCMA version. Exchange requires "Unified Communications Managed API 4.0" and
        # states no build number.
        UcmaRuntimeVersion = @{
            Value      = $null
            PackageKey = 'UcmaRuntime'
            Source     = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/prerequisites#exchange-server-mailbox-server-role'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/ms-exch-setupreadiness-ucmaredistmsi'
            )
            Read       = '2026-09-11'
            Note       = 'Exchange documents no minimum UCMA 4.0 build number.'
        }

        # IIS URL Rewrite Module - a Mailbox role prerequisite; Setup requires version 2.1.
        # $null: Learn does not document the uninstall DisplayName the module registers under, nor
        # a value that identifies the 2.1 release, so there is no documented name to look for.
        IisUrlRewrite = @{
            Value  = $null
            Source = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/prerequisites#exchange-server-mailbox-server-role'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/ms-exch-setupreadiness-iisurlrewritenotinstalled'
            )
            Read   = '2026-09-11'
            Note   = 'Required (version 2.1), but Learn does not document the uninstall DisplayName of the IIS URL Rewrite Module.'
        }

        # Windows features for the Mailbox role, as the two Install-WindowsFeature lists on the
        # prerequisites page: one for Desktop Experience and one for Server Core. The installation
        # option is read from OperatingSystemSKU using the SKU descriptions on the Win32_OperatingSystem
        # page. Get-WindowsFeature reports each feature's InstallState.
        WindowsFeatures = @{
            Value  = @{
                DesktopExperience = @(
                    'Server-Media-Foundation', 'NET-Framework-45-Core', 'NET-Framework-45-ASPNET',
                    'NET-WCF-HTTP-Activation45', 'NET-WCF-Pipe-Activation45', 'NET-WCF-TCP-Activation45',
                    'NET-WCF-TCP-PortSharing45', 'RPC-over-HTTP-proxy', 'RSAT-Clustering',
                    'RSAT-Clustering-CmdInterface', 'RSAT-Clustering-Mgmt', 'RSAT-Clustering-PowerShell',
                    'WAS-Process-Model', 'Web-Asp-Net45', 'Web-Basic-Auth', 'Web-Client-Auth',
                    'Web-Digest-Auth', 'Web-Dir-Browsing', 'Web-Dyn-Compression', 'Web-Http-Errors',
                    'Web-Http-Logging', 'Web-Http-Redirect', 'Web-Http-Tracing', 'Web-ISAPI-Ext',
                    'Web-ISAPI-Filter', 'Web-Metabase', 'Web-Mgmt-Console', 'Web-Mgmt-Service',
                    'Web-Net-Ext45', 'Web-Request-Monitor', 'Web-Server', 'Web-Stat-Compression',
                    'Web-Static-Content', 'Web-Windows-Auth', 'Web-WMI', 'Windows-Identity-Foundation',
                    'RSAT-ADDS'
                )
                ServerCore        = @(
                    'Server-Media-Foundation', 'NET-Framework-45-Core', 'NET-Framework-45-ASPNET',
                    'NET-WCF-HTTP-Activation45', 'NET-WCF-Pipe-Activation45', 'NET-WCF-TCP-Activation45',
                    'NET-WCF-TCP-PortSharing45', 'RPC-over-HTTP-proxy', 'RSAT-Clustering',
                    'RSAT-Clustering-CmdInterface', 'RSAT-Clustering-PowerShell', 'WAS-Process-Model',
                    'Web-Asp-Net45', 'Web-Basic-Auth', 'Web-Client-Auth', 'Web-Digest-Auth',
                    'Web-Dir-Browsing', 'Web-Dyn-Compression', 'Web-Http-Errors', 'Web-Http-Logging',
                    'Web-Http-Redirect', 'Web-Http-Tracing', 'Web-ISAPI-Ext', 'Web-ISAPI-Filter',
                    'Web-Metabase', 'Web-Mgmt-Service', 'Web-Net-Ext45', 'Web-Request-Monitor',
                    'Web-Server', 'Web-Stat-Compression', 'Web-Static-Content', 'Web-Windows-Auth',
                    'Web-WMI', 'RSAT-ADDS'
                )
            }
            InstallationOptionBySku = @{
                DesktopExperience = @(7, 8)
                ServerCore        = @(12, 13, 147, 148)
            }
            Source = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/prerequisites#exchange-server-mailbox-server-role'
                'https://learn.microsoft.com/windows/win32/cimwin32prov/win32-operatingsystem'
                'https://learn.microsoft.com/powershell/module/servermanager/get-windowsfeature'
            )
            Read   = '2026-09-11'
            Note   = 'Desktop Experience list and Server Core list, verbatim from the prerequisites page.'
        }

        # "The Remote Registry Service must be set to Automatic and must not be set to Disabled."
        # Read as Win32_Service.StartMode of the service named RemoteRegistry, where Automatic is
        # reported as "Auto".
        RemoteRegistryStartMode = @{
            Value       = 'Auto'
            ServiceName = 'RemoteRegistry'
            Source      = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/prerequisites#what-do-you-need-to-know-before-you-begin'
                'https://learn.microsoft.com/windows-server/security/windows-services/security-guidelines-for-disabling-system-services-in-windows-server#remote-registry'
                'https://learn.microsoft.com/windows/win32/cimwin32prov/win32-service'
            )
            Read        = '2026-09-11'
            Note        = 'StartMode Auto is Automatic.'
        }

        # "At least 30 GB of free space on the drive where you're installing Exchange." The drive is
        # the default install location, %ExchangeInstallPath% = %ProgramFiles%\Microsoft\Exchange
        # Server\V15\; Setup's /TargetDir moves it, and the check then does not describe it.
        InstallVolumeFreeSpaceGB = @{
            Value  = 30
            Source = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/system-requirements#hardware-requirements-for-exchange-server'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deploy-new-installations/unattended-installs'
            )
            Read   = '2026-09-11'
            Note   = 'Judged on the volume holding %ProgramFiles%, the default install location.'
        }

        # "At least 200 MB of free space on the system drive."
        SystemVolumeFreeSpaceMB = @{
            Value  = 200
            Source = 'https://learn.microsoft.com/exchange/plan-and-deploy/system-requirements#hardware-requirements-for-exchange-server'
            Read   = '2026-09-11'
            Note   = 'Judged on Win32_OperatingSystem.SystemDrive.'
        }

        # "At least 500 MB of free space on the drive that contains the message queue database."
        # The queue database defaults to %ExchangeInstallPath%TransportRoles\data\Queue, so before
        # Exchange is installed it is the install volume. A relocated queue database is not seen.
        QueueVolumeFreeSpaceMB = @{
            Value  = 500
            Source = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/system-requirements#hardware-requirements-for-exchange-server'
                'https://learn.microsoft.com/exchange/mail-flow/queues/queues#queue-database-files'
            )
            Read   = '2026-09-11'
            Note   = 'Judged on the volume holding %ProgramFiles%, the default queue database location.'
        }

        # "Set the paging file minimum and maximum value to the same size: 25% of installed memory."
        # Value is the percentage. Installed memory is the sum of Win32_PhysicalMemory.Capacity -
        # Learn says TotalPhysicalMemory is not accurate for this. Page file sizes are
        # Win32_PageFileSetting.InitialSize and MaximumSize, in megabytes.
        PageFileSize = @{
            Value  = 25
            Source = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/system-requirements#hardware-requirements-for-exchange-server'
                'https://learn.microsoft.com/windows/win32/cimwin32prov/win32-pagefilesetting'
                'https://learn.microsoft.com/windows/win32/cimwin32prov/win32-computersystem'
            )
            Read   = '2026-09-11'
            Note   = 'Minimum equal to maximum, each 25% of installed memory.'
        }

        # Setup cannot continue while a restart is pending. Learn does not document which indicators
        # Exchange Setup reads; these are the four pending-restart locations Microsoft documents for
        # Configuration Manager's own setup prerequisite check. A key with no ValueName is present
        # when the key exists; one with a ValueName is present when that value exists.
        PendingReboot = @{
            Value  = @(
                @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'; ValueName = '' }
                @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'; ValueName = '' }
                @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'; ValueName = 'PendingFileRenameOperations' }
                @{ Path = 'HKLM:\SOFTWARE\Microsoft\ServerManager'; ValueName = 'CurrentRebootAttempts' }
            )
            Source = @(
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/ms-exch-setupreadiness-rebootpending'
                'https://learn.microsoft.com/intune/configmgr/core/servers/deploy/install/list-of-prerequisite-checks'
            )
            Read   = '2026-09-11'
            Note   = 'None of the indicators may be present.'
        }
    }
}

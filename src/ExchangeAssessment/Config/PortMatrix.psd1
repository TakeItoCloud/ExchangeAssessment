<#
Network flows a member server that will become an Exchange Server SE server needs, probed FROM that
server. Read by DEP.NET-01, which runs every probe on the target itself over WinRM.

Every flow names the role it starts from (always TargetServer: this table describes traffic that
originates on the target), the role it goes to, its port and protocol, why it exists, the Microsoft
Learn page the port was read from and the date it was read. A port Learn does not state is $null,
with a Note saying so; DEP.NET-01 reports that flow Unknown - never a pass - and records what it
measured on the target instead of asserting a number.

Probe says how the target tests the flow:
  TcpConnect   a TCP connection. Open when the handshake completes, Closed when the target is told
               the connection is refused, Unknown with cause 'timeout' when nothing answers in time.
  UdpDns       a DNS query over UDP. Open when the server answers, Closed when the target is told
               the port is unreachable, Unknown with cause 'timeout' when nothing answers.
  UdpDatagram  one empty datagram. Closed when the target is told the port is unreachable, Open if
               anything replies, otherwise Unknown: a UDP service need not answer an empty datagram.
  WmiConnect   a WMI connection, then a read of the TCP connections the target holds to that host
               afterwards. Used where Learn names the mechanism and not the port.

These flows prove reachability from the target to a listener. A refused flow is reported, not
judged: before Exchange and failover clustering are installed nothing listens on a peer's
replication or cluster port, and a refusal there is what a correctly built greenfield server
returns.

Exchange's own rule is broader than this table. Learn says traffic between Exchange servers, and
between Exchange servers and domain controllers, must not be restricted on any port, including the
random RPC ports. The dynamic RPC range cannot be proven by probing fixed ports - the port the
endpoint mapper hands out is the one used - so it is not a flow here, and a target on which every
flow below is Open has not thereby been shown to meet that rule.

Refresh: re-read every Source URL, change what changed, move TableAsOf and every Read date that was
re-read, and note it in CHANGELOG.md. To probe against a different table for one run, copy this file
and pass the copy with -PortMatrixPath.

One entry is one flow. A test counts the Id lines under Flows from this file's text and holds the
count to the number of flows DEP.NET-01 hands to the targets, so a flow cannot be added or dropped
without the test noticing.
#>
@{
    TableAsOf = '2026-09-11'
    Source    = 'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'

    Flows = @(
        # --------------------------------------------------------------------------------------
        # Target server -> every domain controller discovered in the directory.
        # Exchange Learn names no port list for this traffic: "We don't support restricting or
        # altering network traffic ... between internal Exchange servers and internal Active
        # Directory domain controllers", and asks for rules allowing "any port (including random
        # RPC ports)". The fixed ports below are the rows Windows Learn gives for reaching Active
        # Directory: the Active Directory (local security authority) and Kerberos Key Distribution
        # Center tables of the service overview. Global catalog ports go only to global catalogs.
        # --------------------------------------------------------------------------------------
        @{
            Id              = 'DcKerberosTcp'
            SourceRole      = 'TargetServer'
            DestinationRole = 'DomainController'
            Port            = 88
            Protocol        = 'TCP'
            Probe           = 'TcpConnect'
            Purpose         = 'Kerberos authentication against the domain controller'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Kerberos Key Distribution Center: Kerberos, TCP, 88.'
        }
        @{
            Id              = 'DcKerberosUdp'
            SourceRole      = 'TargetServer'
            DestinationRole = 'DomainController'
            Port            = 88
            Protocol        = 'UDP'
            Probe           = 'UdpDatagram'
            Purpose         = 'Kerberos authentication against the domain controller'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Kerberos Key Distribution Center: Kerberos, UDP, 88.'
        }
        @{
            Id              = 'DcRpcEndpointMapper'
            SourceRole      = 'TargetServer'
            DestinationRole = 'DomainController'
            Port            = 135
            Protocol        = 'TCP'
            Probe           = 'TcpConnect'
            Purpose         = 'RPC endpoint mapper, which hands out the dynamic port an RPC service listens on'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Active Directory (local security authority): RPC, TCP, 135.'
        }
        @{
            Id              = 'DcLdapTcp'
            SourceRole      = 'TargetServer'
            DestinationRole = 'DomainController'
            Port            = 389
            Protocol        = 'TCP'
            Probe           = 'TcpConnect'
            Purpose         = 'LDAP directory reads'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Active Directory (local security authority): LDAP Server, TCP, 389.'
        }
        @{
            Id              = 'DcLocatorUdp'
            SourceRole      = 'TargetServer'
            DestinationRole = 'DomainController'
            Port            = 389
            Protocol        = 'UDP'
            Probe           = 'UdpDatagram'
            Purpose         = 'DC Locator, which finds a domain controller for the site'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Kerberos Key Distribution Center: DC Locator, UDP, 389.'
        }
        @{
            Id              = 'DcSmb'
            SourceRole      = 'TargetServer'
            DestinationRole = 'DomainController'
            Port            = 445
            Protocol        = 'TCP'
            Probe           = 'TcpConnect'
            Purpose         = 'SMB, for SYSVOL and Group Policy and RPC over named pipes'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Active Directory (local security authority): SMB, TCP, 445.'
        }
        @{
            Id              = 'DcKerberosPasswordTcp'
            SourceRole      = 'TargetServer'
            DestinationRole = 'DomainController'
            Port            = 464
            Protocol        = 'TCP'
            Probe           = 'TcpConnect'
            Purpose         = 'Kerberos password change'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Kerberos Key Distribution Center: Kerberos Password V5, TCP, 464.'
        }
        @{
            Id              = 'DcKerberosPasswordUdp'
            SourceRole      = 'TargetServer'
            DestinationRole = 'DomainController'
            Port            = 464
            Protocol        = 'UDP'
            Probe           = 'UdpDatagram'
            Purpose         = 'Kerberos password change'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Kerberos Key Distribution Center: Kerberos Password V5, UDP, 464.'
        }
        @{
            Id              = 'DcLdapSsl'
            SourceRole      = 'TargetServer'
            DestinationRole = 'DomainController'
            Port            = 636
            Protocol        = 'TCP'
            Probe           = 'TcpConnect'
            Purpose         = 'LDAP over SSL'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Active Directory (local security authority): LDAP SSL, TCP, 636.'
        }
        @{
            Id                = 'DcGlobalCatalog'
            SourceRole        = 'TargetServer'
            DestinationRole   = 'DomainController'
            GlobalCatalogOnly = $true
            Port              = 3268
            Protocol          = 'TCP'
            Probe             = 'TcpConnect'
            Purpose           = 'Global catalog LDAP, for forest-wide recipient lookups'
            Source            = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read              = '2026-09-11'
            Note              = 'Active Directory (local security authority): Global Catalog, TCP, 3268. Probed only against global catalogs.'
        }
        @{
            Id                = 'DcGlobalCatalogSsl'
            SourceRole        = 'TargetServer'
            DestinationRole   = 'DomainController'
            GlobalCatalogOnly = $true
            Port              = 3269
            Protocol          = 'TCP'
            Probe             = 'TcpConnect'
            Purpose           = 'Global catalog LDAP over SSL'
            Source            = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read              = '2026-09-11'
            Note              = 'Active Directory (local security authority): Global Catalog, TCP, 3269. Probed only against global catalogs.'
        }

        # --------------------------------------------------------------------------------------
        # Target server -> the file share witness named in Deployment.WitnessServer.
        # Exchange Learn: "The witness server uses SMB port 445", and "Exchange uses Windows
        # Management Instrumentation (WMI) to create the directory and file share on the witness
        # server" - with no port for the WMI flow.
        # --------------------------------------------------------------------------------------
        @{
            Id              = 'WitnessSmb'
            SourceRole      = 'TargetServer'
            DestinationRole = 'WitnessServer'
            Port            = 445
            Protocol        = 'TCP'
            Probe           = 'TcpConnect'
            Purpose         = 'SMB to the file share witness'
            Source          = 'https://learn.microsoft.com/exchange/high-availability/manage-ha/manage-dags#creating-dags'
            Read            = '2026-09-11'
            Note            = 'The witness server uses SMB port 445.'
        }
        @{
            Id              = 'WitnessWmi'
            SourceRole      = 'TargetServer'
            DestinationRole = 'WitnessServer'
            # $null: Learn says Exchange uses WMI to create the witness directory and share, and
            # names no port for it. WMI over DCOM starts at the RPC endpoint mapper and continues on
            # a port it assigns, so no single number describes the flow. The probe makes a WMI
            # connection and records the TCP ports the target then holds to the witness - what
            # actually opened - and the flow stays Unknown, because there is no documented port to
            # pass against. Learn's silence is not evidence that no port is needed.
            Port            = $null
            Protocol        = 'TCP'
            Probe           = 'WmiConnect'
            Purpose         = 'WMI, which Exchange uses to create the witness directory and share'
            Source          = 'https://learn.microsoft.com/exchange/high-availability/manage-ha/manage-dags#creating-dags'
            Read            = '2026-09-11'
            Note            = 'Learn states that Exchange uses WMI to create the witness directory and share, and does not state a port'
        }

        # --------------------------------------------------------------------------------------
        # Target server -> every other server in Deployment.TargetServers.
        # Exchange Learn states the DAG replication port; Windows Learn states the failover cluster
        # ports a DAG member needs. Nothing listens on any of them before Exchange and failover
        # clustering are installed, so on a greenfield server a refusal is expected.
        # --------------------------------------------------------------------------------------
        @{
            Id              = 'PeerReplication'
            SourceRole      = 'TargetServer'
            DestinationRole = 'PeerTarget'
            Port            = 64327
            Protocol        = 'TCP'
            Probe           = 'TcpConnect'
            Purpose         = 'DAG continuous replication'
            Source          = @(
                'https://learn.microsoft.com/exchange/high-availability/manage-ha/manage-ha#database-availability-group-management'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'By default, all DAGs use TCP port 64327 for continuous replication; Set-DatabaseAvailabilityGroup -ReplicationPort changes it.'
        }
        @{
            Id              = 'PeerClusterTcp'
            SourceRole      = 'TargetServer'
            DestinationRole = 'PeerTarget'
            Port            = 3343
            Protocol        = 'TCP'
            Probe           = 'TcpConnect'
            Purpose         = 'Failover cluster service, during a node join'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Cluster service: Cluster Service, TCP, 3343 (required during a node join operation).'
        }
        @{
            Id              = 'PeerClusterUdp'
            SourceRole      = 'TargetServer'
            DestinationRole = 'PeerTarget'
            Port            = 3343
            Protocol        = 'UDP'
            Probe           = 'UdpDatagram'
            Purpose         = 'Failover cluster service heartbeats'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Cluster service: Cluster Service, UDP and DTLS, 3343.'
        }
        @{
            Id              = 'PeerRpcEndpointMapper'
            SourceRole      = 'TargetServer'
            DestinationRole = 'PeerTarget'
            Port            = 135
            Protocol        = 'TCP'
            Probe           = 'TcpConnect'
            Purpose         = 'RPC endpoint mapper for the cluster service'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Cluster service: RPC, TCP, 135.'
        }
        @{
            Id              = 'PeerSmb'
            SourceRole      = 'TargetServer'
            DestinationRole = 'PeerTarget'
            Port            = 445
            Protocol        = 'TCP'
            Probe           = 'TcpConnect'
            Purpose         = 'SMB, used by the cluster service when a node joins'
            Source          = @(
                'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements#system-services-ports'
                'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            )
            Read            = '2026-09-11'
            Note            = 'Cluster service: Cluster Service, TCP, 445 (required during a node join operation from the Add Node Wizard).'
        }

        # --------------------------------------------------------------------------------------
        # Target server -> each DNS server in the target's own DNS client configuration.
        # Exchange Learn: "DNS for name resolution of the next mail hop | 53/UDP,53/TCP (DNS) |
        # Mailbox server | DNS server".
        # --------------------------------------------------------------------------------------
        @{
            Id              = 'DnsUdp'
            SourceRole      = 'TargetServer'
            DestinationRole = 'DnsServer'
            Port            = 53
            Protocol        = 'UDP'
            Probe           = 'UdpDns'
            Purpose         = 'DNS name resolution'
            Source          = 'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            Read            = '2026-09-11'
            Note            = 'DNS for name resolution of the next mail hop: 53/UDP, from the Mailbox server to the DNS server.'
        }
        @{
            Id              = 'DnsTcp'
            SourceRole      = 'TargetServer'
            DestinationRole = 'DnsServer'
            Port            = 53
            Protocol        = 'TCP'
            Probe           = 'TcpConnect'
            Purpose         = 'DNS name resolution'
            Source          = 'https://learn.microsoft.com/exchange/plan-and-deploy/deployment-ref/network-ports'
            Read            = '2026-09-11'
            Note            = 'DNS for name resolution of the next mail hop: 53/TCP, from the Mailbox server to the DNS server.'
        }
    )
}

<#
The collector registry.

One ordered row per collector replaces the hand-written dispatcher. Adding a collector is a row
here plus a file under Collectors/ - nothing else changes.

  Id        control id, must resolve in ControlCatalog.ps1
  Function  the Invoke-ExchCollector_* function, which takes -Run and optionally -Upstream
  Area      grouping used by the reports
  Requires  control ids whose results are passed to this collector as -Upstream
  Cloud     true when the collector needs an Exchange Online session
  SkipFlag  name of a switch on Invoke-ExchCollection that suppresses this collector
            (SkipDomainQueries, SkipMailboxInventory, SkipDnsQueries, SkipDeploymentChecks)
#>

Set-StrictMode -Version Latest

function Get-ExchCollectorRegistry {
    [CmdletBinding()]
    param()

    return @(
        @{ Id='ENV.VERS-01'; Function='Invoke-ExchCollector_ENV_VERS_01_DomainForestSchema'; Area='Environment'; Requires=@();                                     Cloud=$false; SkipFlag='SkipDomainQueries' }
        @{ Id='ENV.OS-01';   Function='Invoke-ExchCollector_ENV_OS_01_ExchangeOS';           Area='Environment'; Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='EX.CH-01';    Function='Invoke-ExchCollector_EX_CH_01_ExchangeVersionCU';     Area='Exchange';    Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='UPG-01';      Function='Invoke-ExchCollector_UPG_01_SEReadiness';             Area='Upgrade';     Requires=@('ENV.VERS-01','ENV.OS-01','EX.CH-01'); Cloud=$false; SkipFlag='' }
        @{ Id='MB.DB-01';    Function='Invoke-ExchCollector_MB_DB_01_DatabaseHealth';        Area='Mailbox';     Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='DAG-01';      Function='Invoke-ExchCollector_DAG_01_DagHealth';               Area='Mailbox';     Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='TR.CO-01';    Function='Invoke-ExchCollector_TR_CO_01_TransportConnectors';   Area='Transport';   Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='CERT-01';     Function='Invoke-ExchCollector_CERT_01_Certificates';           Area='Certificate'; Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='MB.AV-01';    Function='Invoke-ExchCollector_MB_AV_01_AVExclusions';          Area='Mailbox';     Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='AA.SPAM-01';  Function='Invoke-ExchCollector_AA_SPAM_01_AntiMalwareSpam';     Area='Security';    Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='HYB-01';      Function='Invoke-ExchCollector_HYB_01_HybridConfig';            Area='Hybrid';      Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='ID.SYNC-01';  Function='Invoke-ExchCollector_ID_SYNC_01_AADConnectStatus';    Area='Identity';    Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='LOG.EX-01';   Function='Invoke-ExchCollector_LOG_EX_01_EventLogErrors';       Area='Monitoring';  Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='EX.ADM-01';   Function='Invoke-ExchCollector_EX_ADM_01_AcceptedDomains';      Area='Exchange';    Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='EX.VDIR-01';  Function='Invoke-ExchCollector_EX_VDIR_01_VirtualDirectories';  Area='Exchange';    Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='SRV-01';      Function='Invoke-ExchCollector_SRV_01_ServerInventory';        Area='Environment'; Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='TR.CFG-01';   Function='Invoke-ExchCollector_TR_CFG_01_TransportConfig';     Area='Transport';   Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='REPL-01';     Function='Invoke-ExchCollector_REPL_01_ReplicationHealth';     Area='Mailbox';     Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='TR.QUE-01';   Function='Invoke-ExchCollector_TR_QUE_01_TransportQueue';      Area='Transport';   Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='RBAC-01';     Function='Invoke-ExchCollector_RBAC_01_RoleBasedAccess';       Area='Security';    Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='MB.INV-01';   Function='Invoke-ExchCollector_MB_INV_01_MailboxInventory';    Area='Mailbox';     Requires=@();                                     Cloud=$false; SkipFlag='SkipMailboxInventory' }
        @{ Id='RET-01';      Function='Invoke-ExchCollector_RET_01_RetentionCompliance';    Area='Compliance';  Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='CAS-01';      Function='Invoke-ExchCollector_CAS_01_ClientAccess';           Area='Client';      Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='AL-01';       Function='Invoke-ExchCollector_AL_01_AddressLists';            Area='Exchange';    Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='PF-01';       Function='Invoke-ExchCollector_PF_01_PublicFolders';           Area='Exchange';    Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='TLS-01';      Function='Invoke-ExchCollector_TLS_01_TlsConfiguration';       Area='Security';    Requires=@();                                     Cloud=$false; SkipFlag='' }
        @{ Id='PTCH-01';     Function='Invoke-ExchCollector_PTCH_01_SecurityUpdates';       Area='Security';    Requires=@('EX.CH-01');                           Cloud=$false; SkipFlag='' }
        @{ Id='DNS-01';      Function='Invoke-ExchCollector_DNS_01_MailDnsPosture';         Area='Network';     Requires=@();                                     Cloud=$false; SkipFlag='SkipDnsQueries' }
        @{ Id='DEP.TGT-01';  Function='Invoke-ExchCollector_DEP_TGT_01_TargetServerReadiness'; Area='Deployment'; Requires=@();                                   Cloud=$false; SkipFlag='SkipDeploymentChecks' }
        @{ Id='DEP.NET-01';  Function='Invoke-ExchCollector_DEP_NET_01_TargetPortMatrix';      Area='Deployment'; Requires=@();                                   Cloud=$false; SkipFlag='SkipDeploymentChecks' }
        @{ Id='DEP.WIT-01';  Function='Invoke-ExchCollector_DEP_WIT_01_WitnessReadiness';      Area='Deployment'; Requires=@();                                   Cloud=$false; SkipFlag='SkipDeploymentChecks' }
        @{ Id='DEP.NAME-01'; Function='Invoke-ExchCollector_DEP_NAME_01_NameAvailability';     Area='Deployment'; Requires=@();                                   Cloud=$false; SkipFlag='SkipDeploymentChecks' }
        @{ Id='CLD.ORG-01';  Function='Invoke-ExchCollector_CLD_ORG_01_TenantOrganization'; Area='Cloud';       Requires=@();                                     Cloud=$true;  SkipFlag='' }
        @{ Id='CLD.CONN-01'; Function='Invoke-ExchCollector_CLD_CONN_01_TenantConnector';   Area='Cloud';       Requires=@();                                     Cloud=$true;  SkipFlag='' }
        @{ Id='CLD.SEC-01';  Function='Invoke-ExchCollector_CLD_SEC_01_TenantSecurity';     Area='Cloud';       Requires=@();                                     Cloud=$true;  SkipFlag='' }
        @{ Id='CLD.MIG-01';  Function='Invoke-ExchCollector_CLD_MIG_01_TenantMigration';    Area='Cloud';       Requires=@();                                     Cloud=$true;  SkipFlag='' }
    )
}

function Get-ExchCollectorOrder {
    <#
    Orders the registry so that every collector runs after the ones it declares in Requires.
    Registry order is preserved wherever dependencies allow, and a dependency cycle throws
    rather than silently dropping a collector.
    #>
    [CmdletBinding()]
    param([Parameter()][object[]]$Registry)

    if (-not $Registry) { $Registry = Get-ExchCollectorRegistry }

    $byId = @{}
    foreach ($entry in $Registry) { $byId[$entry.Id] = $entry }

    $ordered = New-Object System.Collections.Generic.List[object]
    $state = @{}   # Id -> 'visiting' | 'done'

    function Resolve-EntryOrder {
        param($Entry, $Path)

        if ($state.ContainsKey($Entry.Id) -and $state[$Entry.Id] -eq 'done') { return }
        if ($state.ContainsKey($Entry.Id) -and $state[$Entry.Id] -eq 'visiting') {
            throw ("Collector dependency cycle: {0}" -f (($Path + $Entry.Id) -join ' -> '))
        }

        $state[$Entry.Id] = 'visiting'
        foreach ($req in @($Entry.Requires)) {
            if (-not $byId.ContainsKey($req)) {
                throw ("Collector {0} requires {1}, which is not in the registry." -f $Entry.Id, $req)
            }
            Resolve-EntryOrder -Entry $byId[$req] -Path ($Path + $Entry.Id)
        }
        $state[$Entry.Id] = 'done'
        $ordered.Add($Entry) | Out-Null
    }

    foreach ($entry in $Registry) { Resolve-EntryOrder -Entry $entry -Path @() }

    return $ordered.ToArray()
}

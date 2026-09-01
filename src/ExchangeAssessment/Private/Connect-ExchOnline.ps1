<#
Exchange Online connection.

Opt-in, and off by default: an assessment of an on-premises organisation should not sign in to a
tenant unless the operator asked for it.

**The prefix matters more than anything else here.** Exchange Online and on-premises Exchange
share cmdlet names - Get-AcceptedDomain, Get-OrganizationConfig, Get-MigrationEndpoint,
Get-TransportRule and many more. This module normally runs inside the Exchange Management Shell,
where those names are already bound to the on-premises organisation. Importing the Exchange
Online cmdlets unprefixed would silently shadow them, and a cloud collector would then report
on-premises data as though it came from the tenant. So the session is always imported with a
prefix, and cloud collectors reach their data only through Invoke-ExchCloudQuery, which resolves
the prefixed name and refuses to fall back to the unprefixed one.

No secret is written to the run folder. The run records the authentication mode and the
organisation, never a credential, certificate or token.
#>

Set-StrictMode -Version Latest

function New-ExchCloudState {
    <#
    The disconnected starting state, so the run context always has a Cloud property to read.
    #>
    [CmdletBinding()]
    param([Parameter()][string]$Prefix = 'Cloud')

    [pscustomobject]@{
        Connected    = $false
        AuthMode     = 'None'
        Organization = ''
        Prefix       = $Prefix
        Reason       = 'Exchange Online collection was not requested.'
        ConnectedUtc = $null
    }
}

function Connect-ExchOnlineSession {
    <#
    Connects to Exchange Online using whichever authentication the caller configured, and records
    the outcome on the run. Never throws: a failure to connect is a reportable condition, not a
    reason to abandon an otherwise complete on-premises assessment.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $prefix = [string](Get-ExchThreshold -Run $Run -Name 'Cloud.CommandPrefix' -Default 'Cloud')
    if (-not $prefix) { $prefix = 'Cloud' }

    $auth = $null
    $property = $Run.PSObject.Properties.Match('CloudAuth') | Select-Object -First 1
    if ($property) { $auth = $property.Value }
    if ($null -eq $auth) { $auth = @{} }

    $state = New-ExchCloudState -Prefix $prefix

    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement -ErrorAction SilentlyContinue)) {
        $state.Reason = 'The ExchangeOnlineManagement module is not installed on this host, so the tenant could not be read. Install it with: Install-Module ExchangeOnlineManagement -Scope CurrentUser'
        Write-ExchEvent -Run $Run -Level WARN -Message 'Exchange Online module missing' -Data @{ reason = $state.Reason }
        return $state
    }

    $parameters = @{
        Prefix                = $prefix
        ShowBanner            = $false
        ShowProgress          = $false
        SkipLoadingFormatData = $true
        ErrorAction           = 'Stop'
    }

    $organization = Get-ExchAuthValue -Auth $auth -Name 'Organization'
    $appId        = Get-ExchAuthValue -Auth $auth -Name 'AppId'
    $thumbprint   = Get-ExchAuthValue -Auth $auth -Name 'CertificateThumbprint'
    $upn          = Get-ExchAuthValue -Auth $auth -Name 'UserPrincipalName'
    $managed      = [bool](Get-ExchAuthValue -Auth $auth -Name 'ManagedIdentity')

    if ($appId -and $thumbprint -and $organization) {
        $parameters['AppId'] = $appId
        $parameters['CertificateThumbprint'] = $thumbprint
        $parameters['Organization'] = $organization
        $state.AuthMode = 'AppOnlyCertificate'
    }
    elseif ($managed -and $organization) {
        $parameters['ManagedIdentity'] = $true
        $parameters['Organization'] = $organization
        $accountId = Get-ExchAuthValue -Auth $auth -Name 'ManagedIdentityAccountId'
        if ($accountId) { $parameters['ManagedIdentityAccountId'] = $accountId }
        $state.AuthMode = 'ManagedIdentity'
    }
    elseif ($upn) {
        $parameters['UserPrincipalName'] = $upn
        $state.AuthMode = 'Interactive'
    }
    else {
        $parameters['ErrorAction'] = 'Stop'
        $state.AuthMode = 'InteractivePrompt'
    }

    $state.Organization = $organization

    # The organisation and the mode are safe to log. The thumbprint, app id and any token are not
    # recorded anywhere in the run folder.
    Write-ExchEvent -Run $Run -Level INFO -Message 'Connecting to Exchange Online' -Data @{
        authMode     = $state.AuthMode
        organization = $organization
        prefix       = $prefix
    }

    try {
        Import-Module ExchangeOnlineManagement -ErrorAction Stop
        Connect-ExchangeOnline @parameters | Out-Null

        # Prove the session answers before declaring it connected. Connect-ExchangeOnline can
        # return without a usable session when consent or RBAC is missing.
        $probe = Get-ExchCloudCommand -Run $Run -Name 'Get-OrganizationConfig' -Prefix $prefix
        if (-not $probe) {
            $state.Reason = ("Connected, but no prefixed cmdlet named Get-{0}OrganizationConfig was imported, so the session is unusable." -f $prefix)
            Write-ExchEvent -Run $Run -Level WARN -Message 'Exchange Online session unusable' -Data @{ reason = $state.Reason }
            return $state
        }

        $state.Connected = $true
        $state.ConnectedUtc = (Get-Date).ToUniversalTime()
        $state.Reason = ''

        if (-not $state.Organization) {
            try {
                $config = & $probe -ErrorAction Stop | Select-Object -First 1
                if ($config) { $state.Organization = [string]$config.Name }
            }
            catch {
                Write-Verbose ("Could not read the tenant name: {0}" -f $_.Exception.Message)
            }
        }

        Write-ExchEvent -Run $Run -Level INFO -Message 'Connected to Exchange Online' -Data @{
            authMode = $state.AuthMode; organization = $state.Organization; prefix = $prefix
        }
    }
    catch {
        $state.Connected = $false
        $state.Reason = ("Connect-ExchangeOnline failed using {0} authentication: {1}" -f $state.AuthMode, $_.Exception.Message)
        $null = Write-ExchError -Run $Run -Context 'Connect-ExchangeOnline' -ErrorRecord $_ -Severity 'Warning' `
            -Data @{ authMode = $state.AuthMode; organization = $organization }
    }

    return $state
}

function Disconnect-ExchOnlineSession {
    <#
    Closes the tenant session. Best effort: a run that has already produced its reports must not
    fail because a disconnect did not answer.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $state = Get-ExchCloudState -Run $Run
    if ($null -eq $state -or -not $state.Connected) { return }

    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop | Out-Null
        Write-ExchEvent -Run $Run -Level INFO -Message 'Disconnected from Exchange Online' -Data @{}
    }
    catch {
        Write-ExchEvent -Run $Run -Level WARN -Message 'Disconnect from Exchange Online failed' -Data @{ error = $_.Exception.Message }
    }
}

function Get-ExchCloudState {
    <#
    The run's Exchange Online connection state, or $null on a run context that predates it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()]$Run)

    $property = $Run.PSObject.Properties.Match('Cloud') | Select-Object -First 1
    if (-not $property) { return $null }
    return $property.Value
}

function Get-ExchAuthValue {
    [CmdletBinding()]
    param(
        [Parameter()]$Auth,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Auth) { return $null }
    if ($Auth -is [System.Collections.IDictionary]) {
        if (-not $Auth.Contains($Name)) { return $null }
        return $Auth[$Name]
    }
    $property = $Auth.PSObject.Properties.Match($Name) | Select-Object -First 1
    if (-not $property) { return $null }
    return $property.Value
}

function Get-ExchCloudCommand {
    <#
    Resolves an Exchange Online cmdlet to its prefixed name: Get-AcceptedDomain with prefix
    'Cloud' becomes Get-CloudAcceptedDomain.

    Returns $null when the prefixed command does not exist. It deliberately does NOT fall back to
    the unprefixed name: inside the Exchange Management Shell that name belongs to the
    on-premises organisation, and answering a cloud question with on-premises data would be worse
    than answering it with nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]+-[A-Za-z0-9]+$')][string]$Name,
        [Parameter()][string]$Prefix = ''
    )

    if (-not $Prefix) {
        $state = Get-ExchCloudState -Run $Run
        if ($state) { $Prefix = [string]$state.Prefix }
    }
    if (-not $Prefix) { return $null }

    $parts = $Name.Split('-', 2)
    $prefixed = '{0}-{1}{2}' -f $parts[0], $Prefix, $parts[1]

    $command = Get-Command -Name $prefixed -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return $null }
    return $command.Name
}

function Invoke-ExchCloudQuery {
    <#
    The only way a cloud collector reads tenant data.

    Resolves the prefixed cmdlet, runs it, and records a failure the same way Invoke-ExchQuery
    does. An unresolvable cmdlet is reported rather than silently substituted, so a collector can
    never quietly report on-premises configuration as tenant configuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Run,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]+-[A-Za-z0-9]+$')][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors,
        [Parameter()][hashtable]$Arguments = @{},
        [Parameter()][string]$ControlId = ''
    )

    $resolved = Get-ExchCloudCommand -Run $Run -Name $Name
    if (-not $resolved) {
        $message = ("{0} is not available in the Exchange Online session" -f $Name)
        $Errors.Add($message) | Out-Null
        Write-ExchEvent -Run $Run -Level WARN -Message 'Cloud cmdlet unavailable' -Data @{ controlId = $ControlId; cmdlet = $Name }
        return @()
    }

    try {
        $parameters = @{ ErrorAction = 'Stop' }
        foreach ($key in $Arguments.Keys) { $parameters[$key] = $Arguments[$key] }
        return & $resolved @parameters
    }
    catch {
        $Errors.Add(("{0}: {1}" -f $Name, $_.Exception.Message)) | Out-Null
        $null = Write-ExchError -Run $Run -Context ("Exchange Online {0}" -f $Name) -ErrorRecord $_ -ControlId $ControlId -Severity 'Warning'
        return @()
    }
}

function New-ExchCloudUnavailableFinding {
    <#
    The finding a cloud collector returns when there is no usable tenant session. Explicit, never
    a silent skip - a control the operator asked for and did not get must say so.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Control,
        [Parameter(Mandatory)][ValidateNotNull()]$Run
    )

    $state = Get-ExchCloudState -Run $Run
    $reason = if ($state -and $state.Reason) { [string]$state.Reason } else { 'No Exchange Online session was established.' }

    New-ExchControlFinding -Control $Control -Severity 'Medium' -Outcome 'Unknown' -Sufficiency 'HardFail' `
        -Rationale ("Exchange Online collection was requested but this control could not be evaluated: {0}" -f $reason) `
        -Remediation 'Install the ExchangeOnlineManagement module and re-run with -IncludeExchangeOnline, supplying either -CloudUserPrincipalName for an interactive sign-in or -CloudAppId, -CloudCertificateThumbprint and -CloudOrganization for app-only authentication.' `
        -Metrics @{ connected = $false; reason = $reason; authMode = $(if ($state) { [string]$state.AuthMode } else { 'None' }) } `
        -Meta @{ dataSources = @{ ExchangeOnline = @{ state = 'Error'; reason = $reason } }; evaluationStatus = 'Failed' }
}

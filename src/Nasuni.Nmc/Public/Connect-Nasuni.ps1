# FILE: Public/Connect-Nasuni.ps1. Connection lifecycle: Connect (FIPS check, optional SPKI pin
# preflight BEFORE credentials are sent, login), Disconnect (logout, wipe memory), Get-NasuniConnection.

function Test-NmcHostName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $kind = [uri]::CheckHostName($Name.Trim('[', ']'))
    $kind -in @([UriHostNameType]::Dns, [UriHostNameType]::IPv4, [UriHostNameType]::IPv6)
}

function Connect-Nasuni {
    <#
    .SYNOPSIS
        Connects to a Nasuni Management Console over validated TLS and logs in.
    .DESCRIPTION
        There is no default host. The certificate is validated by the OS, optionally against
        a private CA only, and you can also require a SHA-256 SPKI pin. If a pin is given,
        it is checked in a separate TLS handshake *before* any credential is sent, and then
        enforced again on every connection the HTTP client opens.
        The token lives only in memory for this PowerShell session.
    .PARAMETER ComputerName
        NMC host name or IP address (no scheme, no path).
    .PARAMETER Credential
        NMC API user credential. Use Get-NasuniVaultCredential to source it from Vault.
    .PARAMETER ReadOnly
        Refuse every non-GET request on this connection (used by the MCP server).
    .PARAMETER RateShare
        Fraction (0.05-1.0) of the NMC rate limit this process may use, so several processes
        can share one NMC.
    .EXAMPLE
        $cred = Get-NasuniVaultCredential -VaultAddress https://vault.corp:8200 -Mount kv -SecretPath nasuni/nmc-ro -AuthMethod Cert -CertRole nasuni-mcp -ClientCertificateThumbprint ABC123...
        Connect-Nasuni -ComputerName nmc.corp.example -Credential $cred -ReadOnly
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-NmcHostName $_ })][string]$ComputerName,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]$Credential,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [string]$TrustedCaCertificatePath,
        [ValidatePattern('^[A-Za-z0-9+/]{43}=$')][string]$PinnedSpkiSha256,
        [ValidateSet('Online', 'Offline', 'NoCheck')][string]$RevocationMode = 'Online',
        [switch]$ReadOnly,
        [ValidateRange(0.05, 1.0)][double]$RateShare = 1.0,
        # Overrides NASUNI_LOG_LEVEL / Set-NasuniLogging only when given.
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')][string]$LogLevel
    )

    Assert-NasuniFipsHost
    if ($script:NmcState.HttpClient) { Disconnect-Nasuni }

    if ($PSBoundParameters.ContainsKey('LogLevel')) { $script:NmcState.LogLevel = $LogLevel }

    if ($PinnedSpkiSha256) {
        $tls = Test-NasuniNmcTls -ComputerName $ComputerName -Port $Port -TrustedCaCertificatePath $TrustedCaCertificatePath -RevocationMode $RevocationMode
        if (-not $tls.CertificateValid) { throw "TLS validation failed for ${ComputerName}: $($tls.Error)" }
        if (-not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                [System.Text.Encoding]::ASCII.GetBytes($tls.SpkiSha256), [System.Text.Encoding]::ASCII.GetBytes($PinnedSpkiSha256))) {
            throw "Certificate public-key pin mismatch for $ComputerName. Expected $PinnedSpkiSha256, got $($tls.SpkiSha256). No credentials were sent."
        }
    }

    $hostPart = if ([uri]::CheckHostName($ComputerName.Trim('[', ']')) -eq [UriHostNameType]::IPv6) { "[$($ComputerName.Trim('[',']'))]" } else { $ComputerName }
    $portPart = if ($Port -eq 443) { '' } else { ":$Port" }

    $script:NmcState.Host = $ComputerName
    $script:NmcState.BaseUri = "https://$hostPart$portPart/api/v1.2"
    $script:NmcState.Credential = $Credential
    $script:NmcState.ReadOnly = [bool]$ReadOnly
    $script:NmcState.RateShare = $RateShare
    $script:NmcState.TrustedCaPath = $TrustedCaCertificatePath
    $script:NmcState.PinnedSpkiSha256 = $PinnedSpkiSha256
    $script:NmcState.ConsecutiveFailures = 0
    $script:NmcState.CircuitOpenUntilUtc = [datetime]::MinValue
    $script:NmcState.Buckets = @{}
    # The preflight above gives a clear "no credentials were sent" error; the client below also
    # enforces the pin on every handshake, so a later or re-pooled connection cannot skip it.
    $script:NmcState.HttpClient = New-NmcHttpClient -TrustedCaCertificatePath $TrustedCaCertificatePath -RevocationMode $RevocationMode -PinnedSpkiSha256 $PinnedSpkiSha256

    try {
        Request-NmcToken
    }
    catch {
        $err = $_
        Disconnect-Nasuni
        throw $err
    }
    Get-NasuniConnection
}

function Disconnect-Nasuni {
    <#
    .SYNOPSIS
        Logs out (best effort) and wipes the token, credential and HTTP client from memory.
    .EXAMPLE
        Disconnect-Nasuni
    #>
    [CmdletBinding()]
    param()

    if ($script:NmcState.Token -and $script:NmcState.HttpClient) {
        try { $null = Invoke-NmcRequest -Method POST -Path '/auth/logout/' -MaxAttempts 1 } catch { Write-NmcLog -Level Debug -Message 'Logout failed (ignored)' }
    }
    if ($script:NmcState.HttpClient) { $script:NmcState.HttpClient.Dispose() }
    $script:NmcState.HttpClient = $null
    $script:NmcState.Token = $null
    $script:NmcState.TokenExpiresUtc = [datetime]::MinValue
    $script:NmcState.Credential = $null
    $script:NmcState.BaseUri = $null
    $script:NmcState.Host = $null
    $script:NmcState.ReadOnly = $false
}

function Get-NasuniConnection {
    <#
    .SYNOPSIS
        Shows the current connection. The output never includes the token or credential.
    .EXAMPLE
        Get-NasuniConnection
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject]@{
        Connected       = [bool]$script:NmcState.BaseUri
        Host            = $script:NmcState.Host
        BaseUri         = $script:NmcState.BaseUri
        UserName        = if ($script:NmcState.Credential) { $script:NmcState.Credential.UserName } else { $null }
        ReadOnly        = $script:NmcState.ReadOnly
        TokenExpiresUtc = if ($script:NmcState.Token) { $script:NmcState.TokenExpiresUtc } else { $null }
        PinnedSpki      = [bool]$script:NmcState.PinnedSpkiSha256
        PrivateCa       = [bool]$script:NmcState.TrustedCaPath
        RateShare       = $script:NmcState.RateShare
    }
}

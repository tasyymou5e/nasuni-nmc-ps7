# FILE: Public/Test-NasuniNmcTls.ps1. Preflight TLS handshake: protocol, cipher suite, FIPS
# approval, certificate and SPKI pin value. No credentials are sent.

function Test-NasuniNmcTls {
    <#
    .SYNOPSIS
        Opens a TLS connection to a host and reports the protocol, cipher suite and certificate,
        and whether the suite is FIPS-approved.
    .DESCRIPTION
        Uses the same client TLS policy as the module: TLS 1.2/1.3 only, FIPS AES-GCM suites
        on Linux, OS chain validation and revocation checks. No credentials are sent.
        Use it as a preflight check, and to read the SPKI SHA-256 value for -PinnedSpkiSha256.
    .EXAMPLE
        Test-NasuniNmcTls -ComputerName nmc.corp.example
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'TLS is an acronym, not a plural')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-NmcHostName $_ })][string]$ComputerName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [string]$TrustedCaCertificatePath,
        [ValidateSet('Online', 'Offline', 'NoCheck')][string]$RevocationMode = 'Online',
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15
    )

    $result = [ordered]@{
        ComputerName       = $ComputerName
        Port               = $Port
        CertificateValid   = $false
        Protocol           = $null
        CipherSuite        = $null
        IsFipsApprovedSuite = $false
        Subject            = $null
        Issuer             = $null
        NotAfterUtc        = $null
        SpkiSha256         = $null
        Error              = $null
    }

    $tcp = [System.Net.Sockets.TcpClient]::new()
    $ssl = $null
    try {
        $cts = [System.Threading.CancellationTokenSource]::new([timespan]::FromSeconds($TimeoutSeconds))
        # DEBUG NOTE (See docs/TROUBLESHOOTING.md): .GetAwaiter().GetResult() on a Task emits a VoidTaskResult object.
        # Without $null =, the function returned an array, and .CertificateValid was not found on it.
        $null = $tcp.ConnectAsync($ComputerName.Trim('[', ']'), $Port, $cts.Token).AsTask().GetAwaiter().GetResult()
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false)
        $opts = New-NmcSslClientOption -TargetHost $ComputerName.Trim('[', ']') -TrustedCaCertificatePath $TrustedCaCertificatePath -RevocationMode $RevocationMode
        $null = $ssl.AuthenticateAsClientAsync($opts, $cts.Token).GetAwaiter().GetResult()

        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate
        $spki = $cert.PublicKey.ExportSubjectPublicKeyInfo()
        $result.CertificateValid = $true
        $result.Protocol = [string]$ssl.SslProtocol
        $result.CipherSuite = [string]$ssl.NegotiatedCipherSuite
        $result.IsFipsApprovedSuite = $script:FipsApprovedSuites -contains $result.CipherSuite
        $result.Subject = $cert.Subject
        $result.Issuer = $cert.Issuer
        $result.NotAfterUtc = $cert.NotAfter.ToUniversalTime()
        $result.SpkiSha256 = [Convert]::ToBase64String([System.Security.Cryptography.SHA256]::HashData($spki))
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $result.Error = $inner.Message
    }
    finally {
        if ($ssl) { $ssl.Dispose() }
        $tcp.Dispose()
    }
    [pscustomobject]$result
}

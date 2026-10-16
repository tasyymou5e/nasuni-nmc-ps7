# FILE: Private/Http.ps1. Layer 1 of the request stack: transport and TLS.
#   New-NmcSslClientOption  TLS 1.2/1.3, FIPS AES-GCM suites (Linux), OS chain validation, revocation
#   New-NmcHttpClient       one HttpClient per connection: no redirects, no cookies, 30 s timeout
#   Invoke-NmcHttp          the ONLY function that touches the network (the seam tests mock)
#   Assert-NmcPath / ConvertTo-NmcQueryString / Resolve-NmcPathTemplate: URL building, all encoded
# Call flow: cmdlet -> Invoke-NmcEndpoint -> Invoke-NmcRequest (Request.ps1) -> Invoke-NmcHttp.

function Get-NmcTlsCipherSuite {
    # FIPS-approved AES-GCM suites as TlsCipherSuite values (used on Linux, where .NET
    # supports an explicit CipherSuitesPolicy; on Windows SChannel's FIPS policy governs).
    [CmdletBinding()]
    [OutputType([System.Net.Security.TlsCipherSuite[]], [System.Array])]
    param()
    , [System.Net.Security.TlsCipherSuite[]]($script:FipsApprovedSuites)
}

function Import-NmcCaCertificate {
    # Loads one or more PEM/DER CA certificates from a file into a collection.
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2Collection], [System.Array])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "CA certificate file not found: $Path" }
    $collection = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ($raw -match '-----BEGIN CERTIFICATE-----') {
        $collection.ImportFromPem($raw)
    }
    else {
        $collection.Add((Import-NasuniCertificate -Path $Path)) | Out-Null   # .NET 8 and 9 compatible
    }
    if ($collection.Count -eq 0) { throw "No certificates found in $Path" }
    , $collection
}

function New-NmcSpkiPinValidator {
    <#
    .SYNOPSIS
        Builds a RemoteCertificateValidationCallback that accepts a server only when the OS chain
        validation passed (SslPolicyErrors.None) AND the leaf's SHA-256 SPKI matches the pin.
    .NOTES
        The callback runs on whatever thread opens the connection (often a thread-pool thread
        with no runspace), so it cannot be a scriptblock, and Add-Type is banned. It is built as
        a System.Linq.Expressions tree and compiled to a native delegate instead. The SPKI value
        is computed exactly as Test-NasuniNmcTls reports it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Factory: creates an in-memory delegate, changes no system state')]
    [CmdletBinding()]
    [OutputType([System.Net.Security.RemoteCertificateValidationCallback])]
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9+/]{43}=$')][string]$PinnedSpkiSha256)

    $E = [System.Linq.Expressions.Expression]
    $x509 = [System.Security.Cryptography.X509Certificates.X509Certificate]
    $x5092 = [System.Security.Cryptography.X509Certificates.X509Certificate2]
    $pSender = $E::Parameter([object], 'sender')
    $pCert = $E::Parameter($x509, 'certificate')
    $pChain = $E::Parameter([System.Security.Cryptography.X509Certificates.X509Chain], 'chain')
    $pErrors = $E::Parameter([System.Net.Security.SslPolicyErrors], 'errors')

    # errors == None && (cert as X509Certificate2) != null &&
    # string.Equals(Convert.ToBase64String(SHA256.HashData(cert.PublicKey.ExportSubjectPublicKeyInfo())), pin, Ordinal)
    $leaf = $E::TypeAs($pCert, $x5092)
    $spki = $E::Call($E::Property($leaf, 'PublicKey'),
        [System.Security.Cryptography.X509Certificates.PublicKey].GetMethod('ExportSubjectPublicKeyInfo', [type[]]@()))
    $hash = $E::Call([System.Security.Cryptography.SHA256].GetMethod('HashData', [type[]]@([byte[]])), $spki)
    $b64 = $E::Call([Convert].GetMethod('ToBase64String', [type[]]@([byte[]])), $hash)
    $match = $E::Call([string].GetMethod('Equals', [type[]]@([string], [string], [StringComparison])),
        $b64, $E::Constant($PinnedSpkiSha256), $E::Constant([StringComparison]::Ordinal))
    $noErrors = $E::Equal($E::Convert($pErrors, [int]), $E::Constant(0))
    $hasLeaf = $E::NotEqual($leaf, $E::Constant($null, $x5092))
    $body = $E::AndAlso($noErrors, $E::AndAlso($hasLeaf, $match))

    $params = [System.Linq.Expressions.ParameterExpression[]]@($pSender, $pCert, $pChain, $pErrors)
    [System.Net.Security.RemoteCertificateValidationCallback]$E::Lambda([System.Net.Security.RemoteCertificateValidationCallback], $body, $params).Compile()
}

function New-NmcSslClientOption {
    <#
    .SYNOPSIS
        Builds client TLS options: TLS 1.2/1.3 only, FIPS AES-GCM suites on Linux,
        OS chain validation (optionally against a private CA only), revocation checks,
        and an optional SHA-256 SPKI pin enforced on every handshake.
    .NOTES
        Chain validation is done entirely by the OS. Without a pin no callback is set; with a
        pin the callback is a compiled expression (New-NmcSpkiPinValidator), never a scriptblock,
        because a scriptblock callback would run on a thread with no runspace.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Factory: creates an in-memory object, changes no system state')]
    [CmdletBinding()]
    [OutputType([System.Net.Security.SslClientAuthenticationOptions])]
    param(
        [string]$TargetHost,
        [string]$TrustedCaCertificatePath,
        [ValidateSet('Online', 'Offline', 'NoCheck')][string]$RevocationMode = 'Online',
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$ClientCertificate,
        [string]$PinnedSpkiSha256
    )

    $opts = [System.Net.Security.SslClientAuthenticationOptions]::new()
    if ($TargetHost) { $opts.TargetHost = $TargetHost }
    $opts.EnabledSslProtocols = [System.Security.Authentication.SslProtocols]::Tls12 -bor [System.Security.Authentication.SslProtocols]::Tls13
    $opts.CertificateRevocationCheckMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]$RevocationMode
    if ($IsLinux) {
        $opts.CipherSuitesPolicy = [System.Net.Security.CipherSuitesPolicy]::new((Get-NmcTlsCipherSuite))
    }
    if ($TrustedCaCertificatePath) {
        $policy = [System.Security.Cryptography.X509Certificates.X509ChainPolicy]::new()
        $policy.TrustMode = [System.Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        $policy.CustomTrustStore.AddRange((Import-NmcCaCertificate -Path $TrustedCaCertificatePath))
        $policy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]$RevocationMode
        $opts.CertificateChainPolicy = $policy
    }
    if ($ClientCertificate) {
        $certs = [System.Security.Cryptography.X509Certificates.X509CertificateCollection]::new()
        $null = $certs.Add($ClientCertificate)
        $opts.ClientCertificates = $certs
    }
    if ($PinnedSpkiSha256) {
        $opts.RemoteCertificateValidationCallback = New-NmcSpkiPinValidator -PinnedSpkiSha256 $PinnedSpkiSha256
    }
    $opts
}

function New-NmcHttpClient {
    <#
    .SYNOPSIS
        Creates the single HttpClient used for NMC or Vault traffic.
    .DESCRIPTION
        Uses the TLS options from New-NmcSslClientOption. Redirects and cookies are off, so the
        Authorization header can never be forwarded to another host. Requests time out
        after 30 seconds, and responses are capped at 64 MB.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Factory: creates an in-memory object, changes no system state')]
    [CmdletBinding()]
    [OutputType([System.Net.Http.HttpClient])]
    param(
        [string]$TrustedCaCertificatePath,
        [ValidateSet('Online', 'Offline', 'NoCheck')][string]$RevocationMode = 'Online',
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$ClientCertificate,
        [ValidateRange(5, 300)][int]$TimeoutSeconds = 30,
        # Enforced on every pooled connection, not only in the Connect-Nasuni preflight.
        [string]$PinnedSpkiSha256
    )

    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $handler.SslOptions = New-NmcSslClientOption -TrustedCaCertificatePath $TrustedCaCertificatePath `
        -RevocationMode $RevocationMode -ClientCertificate $ClientCertificate -PinnedSpkiSha256 $PinnedSpkiSha256
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseProxy = $true
    $handler.PooledConnectionLifetime = [timespan]::FromMinutes(5)
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::All

    $client = [System.Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [timespan]::FromSeconds($TimeoutSeconds)
    $client.MaxResponseContentBufferSize = 64MB
    $client
}

function Invoke-NmcHttp {
    <#
    .SYNOPSIS
        Sends one HTTP request and returns status, body and Retry-After.
    .DESCRIPTION
        This is the only function that touches the network, and the seam that unit tests
        mock. It does no retries and does not interpret the status code.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][uri]$Uri,
        [hashtable]$Headers = @{},
        [string]$BodyJson
    )

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Uri)
    try {
        foreach ($name in $Headers.Keys) {
            $null = $request.Headers.TryAddWithoutValidation($name, [string]$Headers[$name])
        }
        if ($PSBoundParameters.ContainsKey('BodyJson') -and $null -ne $BodyJson) {
            $request.Content = [System.Net.Http.StringContent]::new($BodyJson, [System.Text.Encoding]::UTF8, 'application/json')
        }
        $response = $Client.Send($request)
        try {
            $reader = [System.IO.StreamReader]::new($response.Content.ReadAsStream())
            try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }

            $retryAfter = $null
            $ra = $response.Headers.RetryAfter
            if ($ra) {
                # DEBUG NOTE (See docs/TROUBLESHOOTING.md): PowerShell unwraps Nullable<T>, so Delta/Date are either $null
                # or the value itself. Calling .Value on them throws under strict mode.
                $delta = $ra.Delta
                $date = $ra.Date
                if ($null -ne $delta) {
                    $retryAfter = [string]([timespan]$delta).TotalSeconds
                }
                elseif ($null -ne $date) {
                    $retryAfter = [string][math]::Max(0, (([datetimeoffset]$date) - [datetimeoffset]::UtcNow).TotalSeconds)
                }
            }
            [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Body       = $body
                RetryAfter = $retryAfter
                Location   = if ($response.Headers.Location) { [string]$response.Headers.Location } else { $null }
            }
        }
        finally { $response.Dispose() }
    }
    finally { $request.Dispose() }
}

function Assert-NmcPath {
    # Rejects anything that is not a plain API path relative to the base URI.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^/[A-Za-z0-9._~%\-/]*$' -or $Path -match '(^|/)\.\.?(/|$)' -or $Path.Contains('//')) {
        throw "Invalid API path '$Path'. Use a relative path such as /volumes/ and pass query values with -Query."
    }
}

function ConvertTo-NmcQueryString {
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable]$Query)
    if (-not $Query -or $Query.Count -eq 0) { return '' }
    $pairs = foreach ($key in ($Query.Keys | Sort-Object)) {
        if ($null -eq $Query[$key]) { continue }
        '{0}={1}' -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([string]$Query[$key])
    }
    if (-not $pairs) { return '' }
    '?' + ($pairs -join '&')
}

function Resolve-NmcPathTemplate {
    <#
    .SYNOPSIS
        Fills {name} placeholders in a path template with URL-encoded values.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Template, [hashtable]$Values = @{})
    $builder = [System.Text.StringBuilder]::new()
    $last = 0
    foreach ($m in [regex]::Matches($Template, '\{([A-Za-z0-9_]+)\}')) {
        $null = $builder.Append($Template, $last, $m.Index - $last)
        $name = $m.Groups[1].Value
        if (-not $Values.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string]$Values[$name])) {
            throw "Missing value for path parameter '$name'."
        }
        $value = [string]$Values[$name]
        if ($name -eq 'path') {
            # Folder paths keep their '/' separators, and each segment is encoded on its own.
            $segments = @($value.Replace('\', '/').Trim('/') -split '/' | Where-Object { $_ -ne '' })
            if ($segments.Count -eq 0) { throw "Path parameter 'path' is empty." }
            if ($segments -contains '.' -or $segments -contains '..') { throw "Path parameter 'path' may not contain '.' or '..' segments." }
            $null = $builder.Append((($segments | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'))
        }
        else {
            $null = $builder.Append([uri]::EscapeDataString($value))
        }
        $last = $m.Index + $m.Length
    }
    $null = $builder.Append($Template.Substring($last))
    $result = $builder.ToString()
    Assert-NmcPath -Path $result
    $result
}

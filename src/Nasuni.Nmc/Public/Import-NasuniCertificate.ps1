# FILE: Public/Import-NasuniCertificate.ps1. Certificate loading that works on BOTH PowerShell 7.4
# (.NET 8) and 7.5+ (.NET 9).
# DEBUG NOTE (See docs/TROUBLESHOOTING.md, ".NET 8 vs 9"): X509CertificateLoader exists only in .NET 9+.
# Code that called it directly passed every test on PowerShell 7.5, then failed on 7.4 with "Unable to
# find type [...X509CertificateLoader]". Found by the Linux container test run. Always use this function.

function Import-NasuniCertificate {
    <#
    .SYNOPSIS
        Loads a certificate (optionally with its private key) on PowerShell 7.4 and 7.5+.
    .DESCRIPTION
        -Pkcs12 / -Password loads a PFX, for example a certificate converted from PEM so that SslStream
        can use its key as a TLS server on Windows and macOS.
        -Path loads a public certificate from a PEM or DER file.
        -PemCertificatePath / -PemKeyPath loads a PEM certificate and key, re-imported through
        PKCS#12 in memory so the key is usable as a server key on every platform.
        It uses X509CertificateLoader on .NET 9+, and the X509Certificate2 constructors on .NET 8.
    .EXAMPLE
        Import-NasuniCertificate -PemCertificatePath ./tls.crt -PemKeyPath ./tls.key
    #>
    [CmdletBinding(DefaultParameterSetName = 'Pkcs12')]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Pkcs12')][byte[]]$Pkcs12,
        [Parameter(ParameterSetName = 'Pkcs12')][AllowNull()][securestring]$Pkcs12Password,
        [Parameter(Mandatory, ParameterSetName = 'File')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Pem')][string]$PemCertificatePath,
        [Parameter(Mandatory, ParameterSetName = 'Pem')][string]$PemKeyPath
    )
    $X509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]
    $loader = 'System.Security.Cryptography.X509Certificates.X509CertificateLoader' -as [type]
    switch ($PSCmdlet.ParameterSetName) {
        'Pkcs12' {
            $plain = if ($Pkcs12Password) { [System.Net.NetworkCredential]::new('', $Pkcs12Password).Password } else { [string]$null }
            if ($loader) { return $loader::LoadPkcs12($Pkcs12, $plain) }
            return $X509::new($Pkcs12, $plain)
        }
        'File' {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Certificate file not found: $Path" }
            if ($loader) { return $loader::LoadCertificateFromFile($Path) }
            return $X509::new([System.IO.File]::ReadAllBytes($Path))
        }
        'Pem' {
            Assert-NmcPrivateKeyFile -Path $PemKeyPath
            $pem = $X509::CreateFromPemFile($PemCertificatePath, $PemKeyPath)
            $pw = [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(18))
            try { return Import-NasuniCertificate -Pkcs12 $pem.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, $pw) -Pkcs12Password (ConvertTo-NmcSecureString -Value $pw) }
            finally { $pem.Dispose() }
        }
    }
}

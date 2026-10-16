# FILE: Public/Get-NasuniVaultCredential.ps1. HashiCorp Vault: cert/AppRole login, KV v2 reads
# (credential or a single secret field), PKI certificate issuance. Each call logs in, does one
# thing, and revokes its Vault token in a finally block.

function ConvertTo-NmcSecureString {
    # Builds a read-only SecureString one character at a time (no -AsPlainText).
    [CmdletBinding()]
    [OutputType([securestring])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $secure = [securestring]::new()
    foreach ($ch in $Value.ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    $secure
}

function Assert-NmcPrivateKeyFile {
    # On Linux and macOS the key file must not be readable by group or others (0600 or stricter).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    if ($IsWindows) { return }
    $mode = (Get-Item -LiteralPath $Path).UnixFileMode
    $loose = [System.IO.UnixFileMode]'GroupRead, GroupWrite, GroupExecute, OtherRead, OtherWrite, OtherExecute'
    if (($mode -band $loose) -ne 0) { throw "Refusing to use $Path`: permissions are $mode; run chmod 600." }
}

function Invoke-NmcVaultCall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][uri]$Uri,
        [hashtable]$Headers = @{},
        [string]$BodyJson
    )
    $args2 = @{ Client = $Client; Method = $Method; Uri = $Uri; Headers = $Headers }
    if ($PSBoundParameters.ContainsKey('BodyJson')) { $args2.BodyJson = $BodyJson }
    $resp = Invoke-NmcHttp @args2
    if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 300) {
        throw (New-NasuniApiError -Message 'Vault request failed' -StatusCode $resp.StatusCode -Method $Method -Endpoint $Uri.AbsolutePath -CorrelationId '' -Body $resp.Body)
    }
    if ([string]::IsNullOrWhiteSpace($resp.Body)) { return $null }
    $resp.Body | ConvertFrom-Json -Depth 32
}

# TODO(roadmap#4): verify against Vault Enterprise (FIPS build): cert/AppRole roles, KV v2, PKI.
function Invoke-NmcVaultSession {
    <#
    .SYNOPSIS
        Logs in to Vault, runs an action with the session, then always revokes the token.
    .DESCRIPTION
        $Vault keys: Address (https), Namespace, AuthMethod (Cert|AppRole), CertRole,
        ClientCertificateThumbprint, ClientCertificatePath, ClientKeyPath, RoleId, SecretIdPath,
        TrustedCaCertificatePath, RevocationMode. The action is called as
        & $Action $session $Arguments, where the session has Client, Base and Headers (the
        headers already carry X-Vault-Token). Actions must use only their two parameters:
        relying on caller variables through dynamic scope can pick up this function's locals.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Vault, [Parameter(Mandatory)][scriptblock]$Action, [hashtable]$Arguments = @{})

    Assert-NasuniFipsHost
    $get = Get-NmcVaultSettingReader -Vault $Vault
    $address = & $get 'Address'
    if (-not $address -or $address -notmatch '^https://[^/\s]+') { throw 'Vault Address must be an https:// URL.' }
    $authMethod = & $get 'AuthMethod'
    if ($authMethod -notin @('Cert', 'AppRole')) { throw "Vault AuthMethod must be 'Cert' or 'AppRole'." }
    $revocation = & $get 'RevocationMode'
    if (-not $revocation) { $revocation = 'Online' }

    $clientCert = $null
    if ($authMethod -eq 'Cert') {
        $thumb = & $get 'ClientCertificateThumbprint'
        $certPath = & $get 'ClientCertificatePath'
        $keyPath = & $get 'ClientKeyPath'
        if ($thumb) {
            if ($thumb -notmatch '^[A-Fa-f0-9]{40,64}$') { throw 'ClientCertificateThumbprint is not a valid thumbprint.' }
            $clientCert = Get-ChildItem -Path Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object Thumbprint -EQ $thumb.ToUpperInvariant() | Select-Object -First 1
            if (-not $clientCert) { throw "Client certificate $thumb not found in CurrentUser\My or LocalMachine\My." }
            if (-not $clientCert.HasPrivateKey) { throw 'Client certificate has no private key.' }
        }
        elseif ($certPath -and $keyPath) {
            Assert-NmcPrivateKeyFile -Path $keyPath
            $clientCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($certPath, $keyPath)
        }
        else { throw 'Cert auth needs -ClientCertificateThumbprint, or both -ClientCertificatePath and -ClientKeyPath.' }
    }
    elseif (-not (& $get 'RoleId') -or -not (& $get 'SecretIdPath')) { throw 'AppRole auth needs -RoleId and -SecretIdPath.' }

    $client = New-NmcHttpClient -TrustedCaCertificatePath (& $get 'TrustedCaCertificatePath') -RevocationMode $revocation -ClientCertificate $clientCert
    $base = $address.TrimEnd('/')
    $headers = @{ Accept = 'application/json' }
    $ns = & $get 'Namespace'
    if ($ns) { $headers['X-Vault-Namespace'] = $ns }
    $vaultToken = $null
    try {
        if ($authMethod -eq 'Cert') {
            $role = & $get 'CertRole'
            $loginBody = if ($role) { @{ name = $role } | ConvertTo-Json -Compress } else { '{}' }
            $login = Invoke-NmcVaultCall -Client $client -Method POST -Uri "$base/v1/auth/cert/login" -Headers $headers -BodyJson $loginBody
        }
        else {
            $sidPath = & $get 'SecretIdPath'
            Assert-NmcPrivateKeyFile -Path $sidPath
            $secretId = (Get-Content -LiteralPath $sidPath -Raw).Trim()
            Register-NmcRedaction -Value $secretId
            $loginBody = @{ role_id = (& $get 'RoleId'); secret_id = $secretId } | ConvertTo-Json -Compress
            $secretId = $null
            $login = Invoke-NmcVaultCall -Client $client -Method POST -Uri "$base/v1/auth/approle/login" -Headers $headers -BodyJson $loginBody
            $loginBody = $null
        }
        $vaultToken = [string]$login.auth.client_token
        if (-not $vaultToken) { throw 'Vault login returned no client token.' }
        Register-NmcRedaction -Value $vaultToken

        $sessionHeaders = @{} + $headers
        $sessionHeaders['X-Vault-Token'] = $vaultToken
        # DEBUG NOTE (See docs/TROUBLESHOOTING.md, "Dynamic scope"): actions get their inputs only through $Arguments.
        # A caller's script block that read $Role would find THIS function's $role first
        # (PowerShell variable names ignore case), and request a certificate from the wrong PKI role.
        & $Action ([pscustomobject]@{ Client = $client; Base = $base; Headers = $sessionHeaders }) $Arguments
    }
    finally {
        if ($vaultToken) {
            try {
                $revokeHeaders = @{} + $headers
                $revokeHeaders['X-Vault-Token'] = $vaultToken
                $null = Invoke-NmcVaultCall -Client $client -Method POST -Uri "$base/v1/auth/token/revoke-self" -Headers $revokeHeaders -BodyJson '{}'
            }
            catch { Write-NmcLog -Level Warning -Message 'Could not revoke Vault token; it will expire at its TTL' }
        }
        $client.Dispose()
    }
}

function Get-NmcVaultSettingReader {
    # Returns a reader for optional string settings in a Vault config hashtable.
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param([Parameter(Mandatory)][hashtable]$Vault)
    $settings = @{}
    foreach ($k in $Vault.Keys) { if ($Vault[$k]) { $settings[$k] = [string]$Vault[$k] } }
    # DEBUG NOTE (See docs/TROUBLESHOOTING.md, "GetNewClosure"): inside a module, GetNewClosure() binds the block to a new
    # dynamic module, which cannot see this module's private functions. It is safe here only
    # because the block uses nothing but the captured $settings.
    { param($k) if ($settings.ContainsKey($k)) { $settings[$k] } else { $null } }.GetNewClosure()
}

function Read-NmcVaultKv {
    # Reads a KV v2 secret's data object.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Mount, [Parameter(Mandatory)][string]$SecretPath)
    if ($Mount -notmatch '^[A-Za-z0-9_\-]+$') { throw 'Invalid Vault mount name.' }
    if ($SecretPath -notmatch '^[A-Za-z0-9_\-/]+$' -or $SecretPath.Contains('..')) { throw 'Invalid Vault secret path.' }
    $secret = Invoke-NmcVaultCall -Client $Session.Client -Method GET -Uri "$($Session.Base)/v1/$Mount/data/$SecretPath" -Headers $Session.Headers
    $secret.data.data
}

function Get-NasuniVaultCredential {
    <#
    .SYNOPSIS
        Reads an NMC username and password from HashiCorp Vault (KV v2) as a PSCredential.
    .DESCRIPTION
        Connects to Vault over the same TLS policy as NMC traffic and authenticates with
        either:
        - Cert: TLS client-certificate auth. On Windows the certificate comes from the
          certificate store by thumbprint, so the private key can be non-exportable. On
          Linux and macOS it comes from PEM files, and the key file must be chmod 600.
        - AppRole: role_id plus a secret_id read from a file that must be chmod 600.
        It reads <Mount>/data/<SecretPath>, then revokes its own Vault token. The password
        never touches disk.
        FIPS: use a Vault Enterprise FIPS build. Vault Community is not FIPS-validated.
    .EXAMPLE
        Get-NasuniVaultCredential -VaultAddress https://vault.corp:8200 -Mount kv -SecretPath nasuni/nmc-ro `
            -AuthMethod Cert -CertRole nasuni-mcp -ClientCertificatePath /etc/nasuni/vault.crt -ClientKeyPath /etc/nasuni/vault.key
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^https://')][string]$VaultAddress,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_\-]+$')][string]$Mount,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_\-/]+$')][string]$SecretPath,
        [Parameter(Mandatory)][ValidateSet('Cert', 'AppRole')][string]$AuthMethod,
        [string]$CertRole,
        [ValidatePattern('^[A-Fa-f0-9]{40,64}$')][string]$ClientCertificateThumbprint,
        [string]$ClientCertificatePath,
        [string]$ClientKeyPath,
        [string]$RoleId,
        [string]$SecretIdPath,
        [string]$Namespace,
        [string]$TrustedCaCertificatePath,
        [ValidateSet('Online', 'Offline', 'NoCheck')][string]$RevocationMode = 'Online',
        [string]$UserField = 'username',
        [string]$SecretField = 'password'
    )

    if ($SecretPath.Contains('..')) { throw 'SecretPath may not contain ..' }
    $vault = @{
        Address = $VaultAddress; AuthMethod = $AuthMethod; CertRole = $CertRole; ClientCertificateThumbprint = $ClientCertificateThumbprint
        ClientCertificatePath = $ClientCertificatePath; ClientKeyPath = $ClientKeyPath; RoleId = $RoleId; SecretIdPath = $SecretIdPath
        Namespace = $Namespace; TrustedCaCertificatePath = $TrustedCaCertificatePath; RevocationMode = $RevocationMode
    }
    $actionArgs = @{ Mount = $Mount; SecretPath = $SecretPath; UserField = $UserField; SecretField = $SecretField }
    Invoke-NmcVaultSession -Vault $vault -Arguments $actionArgs -Action {
        param($session, $a)
        $data = Read-NmcVaultKv -Session $session -Mount $a.Mount -SecretPath $a.SecretPath
        $names = @($data.PSObject.Properties | ForEach-Object Name)
        if ($names -notcontains $a.UserField -or $names -notcontains $a.SecretField) {
            throw "Vault secret $($a.Mount)/$($a.SecretPath) must contain '$($a.UserField)' and '$($a.SecretField)'."
        }
        $userName = [string]$data.($a.UserField)
        if ([string]::IsNullOrWhiteSpace($userName)) { throw "Vault secret field '$($a.UserField)' is empty." }
        [System.Management.Automation.PSCredential]::new($userName, (ConvertTo-NmcSecureString -Value ([string]$data.($a.SecretField))))
    }
}

function Get-NasuniVaultSecret {
    <#
    .SYNOPSIS
        Reads one field of a Vault KV v2 secret as a SecureString.
    .DESCRIPTION
        Used for secrets the dashboard needs, such as the session-cookie secret, the audit-log
        HMAC key and the OIDC client secret. Authentication and token revocation are the same
        as Get-NasuniVaultCredential. -Vault takes the same keys as a config file's Vault block.
    .EXAMPLE
        Get-NasuniVaultSecret -Vault $config.Vault -Mount kv -SecretPath nasuni/audit-hmac -Field key
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)][hashtable]$Vault,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_\-]+$')][string]$Mount,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_\-/]+$')][string]$SecretPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_\-]+$')][string]$Field
    )
    Invoke-NmcVaultSession -Vault $Vault -Arguments @{ Mount = $Mount; SecretPath = $SecretPath; Field = $Field } -Action {
        param($session, $a)
        $data = Read-NmcVaultKv -Session $session -Mount $a.Mount -SecretPath $a.SecretPath
        if ($null -eq $data.PSObject.Properties[$a.Field] -or [string]::IsNullOrEmpty([string]$data.($a.Field))) {
            throw "Vault secret $($a.Mount)/$($a.SecretPath) has no '$($a.Field)' field."
        }
        ConvertTo-NmcSecureString -Value ([string]$data.($a.Field))
    }
}

function New-NasuniVaultPkiCertificate {
    <#
    .SYNOPSIS
        Issues a TLS server certificate from Vault PKI and returns it with its private key.
    .DESCRIPTION
        Calls <PkiMount>/issue/<Role>. The private key is generated by Vault and returned
        only in memory. It is loaded through a PKCS#12 round trip so that SslStream can use
        it as a server key on Windows and macOS, and it is never written to disk.
    .EXAMPLE
        $cert = New-NasuniVaultPkiCertificate -Vault $config.Vault -PkiMount pki -Role nasuni-dashboard -CommonName dash.corp.example
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Issues a short-lived certificate; no local state changes')]
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param(
        [Parameter(Mandatory)][hashtable]$Vault,
        [ValidatePattern('^[A-Za-z0-9_\-]+$')][string]$PkiMount = 'pki',
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_\-]+$')][string]$Role,
        [Parameter(Mandatory)][ValidateScript({ Test-NmcHostName $_ })][string]$CommonName,
        [string[]]$AltNames = @(),
        [ValidateRange(1, 8760)][int]$TtlHours = 720
    )
    foreach ($n in $AltNames) { if (-not (Test-NmcHostName $n)) { throw "Invalid alt name '$n'." } }
    $actionArgs = @{ PkiMount = $PkiMount; PkiRole = $Role; CommonName = $CommonName; AltNames = $AltNames; TtlHours = $TtlHours }
    Invoke-NmcVaultSession -Vault $Vault -Arguments $actionArgs -Action {
        param($session, $a)
        $body = @{ common_name = $a.CommonName; ttl = "$($a.TtlHours)h"; format = 'pem'; private_key_format = 'pkcs8' }
        if ($a.AltNames.Count) { $body.alt_names = ($a.AltNames -join ',') }
        $resp = Invoke-NmcVaultCall -Client $session.Client -Method POST -Uri "$($session.Base)/v1/$($a.PkiMount)/issue/$($a.PkiRole)" -Headers $session.Headers -BodyJson ($body | ConvertTo-Json -Compress)
        $d = $resp.data
        $pem = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem([string]$d.certificate, [string]$d.private_key)
        $pfxPassword = [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
        try {
            $pfx = $pem.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, $pfxPassword)
            Import-NasuniCertificate -Pkcs12 $pfx -Pkcs12Password (ConvertTo-NmcSecureString -Value $pfxPassword)   # .NET 8 and 9 compatible
        }
        finally {
            $pem.Dispose()
            $pfxPassword = $null
        }
    }
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    $script:Dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nmc-vault-" + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $script:Dir
    $script:VaultToken = 'hvs.TESTVAULTTOKEN0001'
    $script:VaultPassword = 'Vault"Pass\word!'

    function Set-PrivateFile([string]$Path, [string]$Content, [string]$Mode = 'UserRead, UserWrite') {
        [System.IO.File]::WriteAllText($Path, $Content)
        if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]$Mode) }
    }
    function Add-VaultRoutes {
        param([hashtable]$SecretData = @{ username = 'svc-nmc-ro'; password = $script:VaultPassword })
        Add-FakeRoute -Method POST -Path '^/v1/auth/approle/login$' -Handler { New-FakeResponse -Body @{ auth = @{ client_token = $script:VaultToken } } }
        Add-FakeRoute -Method POST -Path '^/v1/auth/cert/login$' -Handler { New-FakeResponse -Body @{ auth = @{ client_token = $script:VaultToken } } }
        $script:VaultSecretData = $SecretData
        Add-FakeRoute -Method GET -Path '^/v1/kv/data/nasuni/nmc-ro$' -Handler {
            param($req)
            if ($req.Headers['X-Vault-Token'] -ne $script:VaultToken) { return New-FakeResponse -Status 403 -Body @{ errors = @('permission denied') } }
            New-FakeResponse -Body @{ data = @{ data = $script:VaultSecretData } }
        }
        Add-FakeRoute -Method POST -Path '^/v1/auth/token/revoke-self$' -Handler { New-FakeResponse -Status 204 }
    }
    function New-TestClientPem {
        $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=nasuni-mcp', $key, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $cert = $req.CreateSelfSigned([datetimeoffset]::UtcNow.AddDays(-1), [datetimeoffset]::UtcNow.AddDays(1))
        $certPath = Join-Path -Path $script:Dir -ChildPath 'client.crt'
        $keyPath = Join-Path -Path $script:Dir -ChildPath 'client.key'
        Set-PrivateFile -Path $certPath -Content $cert.ExportCertificatePem() -Mode 'UserRead, UserWrite, GroupRead, OtherRead'
        Set-PrivateFile -Path $keyPath -Content $key.ExportPkcs8PrivateKeyPem()
        @{ Cert = $certPath; Key = $keyPath }
    }
}

AfterAll { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Get-NasuniVaultCredential' {
    BeforeEach {
        Reset-FakeNmc
        Mock -ModuleName Nasuni.Nmc Invoke-NmcHttp {
            $b = Get-Variable -Name BodyJson -ValueOnly -ErrorAction Ignore
            Invoke-FakeNmc -Method $Method -Uri $Uri -Headers $Headers -BodyJson $b
        }
    }

    It 'reads a credential with AppRole and revokes its Vault token afterwards' {
        Add-VaultRoutes
        $sid = Join-Path -Path $script:Dir -ChildPath 'secret-id'
        Set-PrivateFile -Path $sid -Content "s-123-secret-id`n"
        $cred = Get-NasuniVaultCredential -VaultAddress https://vault.test:8200 -Mount kv -SecretPath nasuni/nmc-ro -AuthMethod AppRole -RoleId role-1 -SecretIdPath $sid -Namespace admin/ops
        $cred.UserName | Should -Be 'svc-nmc-ro'
        $cred.GetNetworkCredential().Password | Should -BeExactly $script:VaultPassword

        $login = @($script:Fake.Calls | Where-Object Path -EQ '/v1/auth/approle/login')[0]
        ($login.BodyJson | ConvertFrom-Json).secret_id | Should -Be 's-123-secret-id'
        $login.Headers['X-Vault-Namespace'] | Should -Be 'admin/ops'
        @($script:Fake.Calls | Where-Object Path -EQ '/v1/auth/token/revoke-self').Count | Should -Be 1
    }

    It 'authenticates with a client certificate from PEM files' {
        Add-VaultRoutes
        $pem = New-TestClientPem
        $cred = Get-NasuniVaultCredential -VaultAddress https://vault.test:8200 -Mount kv -SecretPath nasuni/nmc-ro -AuthMethod Cert -CertRole nasuni-mcp -ClientCertificatePath $pem.Cert -ClientKeyPath $pem.Key
        $cred.UserName | Should -Be 'svc-nmc-ro'
        (@($script:Fake.Calls | Where-Object Path -EQ '/v1/auth/cert/login')[0].BodyJson | ConvertFrom-Json).name | Should -Be 'nasuni-mcp'
    }

    It 'refuses a private key or secret-id file readable by others' -Skip:$IsWindows {
        $pem = New-TestClientPem
        [System.IO.File]::SetUnixFileMode($pem.Key, [System.IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead')
        { Get-NasuniVaultCredential -VaultAddress https://vault.test:8200 -Mount kv -SecretPath nasuni/nmc-ro -AuthMethod Cert -ClientCertificatePath $pem.Cert -ClientKeyPath $pem.Key } | Should -Throw '*chmod 600*'
        $sid = Join-Path -Path $script:Dir -ChildPath 'loose-secret-id'
        Set-PrivateFile -Path $sid -Content 'x' -Mode 'UserRead, UserWrite, OtherRead'
        { Get-NasuniVaultCredential -VaultAddress https://vault.test:8200 -Mount kv -SecretPath nasuni/nmc-ro -AuthMethod AppRole -RoleId r -SecretIdPath $sid } | Should -Throw '*chmod 600*'
    }

    It 'fails when the secret lacks a password field, and still revokes the token' {
        Add-VaultRoutes -SecretData @{ username = 'svc' }
        $sid = Join-Path -Path $script:Dir -ChildPath 'secret-id2'
        Set-PrivateFile -Path $sid -Content 's'
        { Get-NasuniVaultCredential -VaultAddress https://vault.test:8200 -Mount kv -SecretPath nasuni/nmc-ro -AuthMethod AppRole -RoleId r -SecretIdPath $sid } | Should -Throw "*must contain 'username' and 'password'*"
        @($script:Fake.Calls | Where-Object Path -EQ '/v1/auth/token/revoke-self').Count | Should -Be 1
    }

    It 'surfaces Vault errors without leaking the secret-id' {
        Add-FakeRoute -Method POST -Path '^/v1/auth/approle/login$' -Handler { param($req) New-FakeResponse -Status 400 -Body ('{"errors":["invalid secret id"],"echo":' + $req.BodyJson + '}') }
        $sid = Join-Path -Path $script:Dir -ChildPath 'secret-id3'
        Set-PrivateFile -Path $sid -Content 'leaky-secret-id-value'
        $msg = $null
        try { Get-NasuniVaultCredential -VaultAddress https://vault.test:8200 -Mount kv -SecretPath nasuni/nmc-ro -AuthMethod AppRole -RoleId r -SecretIdPath $sid } catch { $msg = $_.Exception.Message }
        $msg | Should -Match 'HTTP 400'
        $msg | Should -Not -Match 'leaky-secret-id-value'
    }

    It 'reads a single secret field as a SecureString' {
        Add-VaultRoutes -SecretData @{ key = 'hmac-key-material-0123456789' }
        $sid = Join-Path -Path $script:Dir -ChildPath 'secret-id4'
        Set-PrivateFile -Path $sid -Content 's'
        $vault = @{ Address = 'https://vault.test:8200'; AuthMethod = 'AppRole'; RoleId = 'r'; SecretIdPath = $sid }
        $sec = Get-NasuniVaultSecret -Vault $vault -Mount kv -SecretPath nasuni/nmc-ro -Field key
        $sec | Should -BeOfType [securestring]
        [System.Net.NetworkCredential]::new('', $sec).Password | Should -Be 'hmac-key-material-0123456789'
        { Get-NasuniVaultSecret -Vault $vault -Mount kv -SecretPath nasuni/nmc-ro -Field missing } | Should -Throw "*no 'missing' field*"
        { Get-NasuniVaultSecret -Vault @{ Address = 'http://v'; AuthMethod = 'AppRole' } -Mount kv -SecretPath x -Field k } | Should -Throw '*https*'
    }

    It 'issues a PKI certificate and returns it with a usable private key' {
        $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=dash.test', $key, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $c = $req.CreateSelfSigned([datetimeoffset]::UtcNow.AddMinutes(-5), [datetimeoffset]::UtcNow.AddDays(30))
        $script:IssuedPem = @{ certificate = $c.ExportCertificatePem(); private_key = $key.ExportPkcs8PrivateKeyPem(); ca_chain = @() }
        Add-VaultRoutes
        Add-FakeRoute -Method POST -Path '^/v1/pki/issue/nasuni-dashboard$' -Handler {
            param($req)
            $script:PkiBody = $req.BodyJson | ConvertFrom-Json
            New-FakeResponse -Body @{ data = $script:IssuedPem }
        }
        $sid = Join-Path -Path $script:Dir -ChildPath 'secret-id5'
        Set-PrivateFile -Path $sid -Content 's'
        $cert = New-NasuniVaultPkiCertificate -Vault @{ Address = 'https://vault.test:8200'; AuthMethod = 'AppRole'; RoleId = 'r'; SecretIdPath = $sid } -Role nasuni-dashboard -CommonName dash.test -AltNames dash2.test -TtlHours 24
        $cert.HasPrivateKey | Should -BeTrue
        $cert.Subject | Should -Be 'CN=dash.test'
        $script:PkiBody.ttl | Should -Be '24h'
        $script:PkiBody.alt_names | Should -Be 'dash2.test'
        { New-NasuniVaultPkiCertificate -Vault @{} -Role r -CommonName 'bad host/x' } | Should -Throw
    }

    It 'uses the PKI role, not the Vault login role, with Cert auth (dynamic-scope regression)' {
        $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=dash.test', $key, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $c = $req.CreateSelfSigned([datetimeoffset]::UtcNow.AddMinutes(-5), [datetimeoffset]::UtcNow.AddDays(30))
        $script:IssuedPem = @{ certificate = $c.ExportCertificatePem(); private_key = $key.ExportPkcs8PrivateKeyPem() }
        Add-VaultRoutes
        Add-FakeRoute -Method POST -Path '^/v1/pki/issue/' -Handler { New-FakeResponse -Body @{ data = $script:IssuedPem } }
        $pem = New-TestClientPem
        $vault = @{ Address = 'https://vault.test:8200'; AuthMethod = 'Cert'; CertRole = 'login-role'; ClientCertificatePath = $pem.Cert; ClientKeyPath = $pem.Key }
        $null = New-NasuniVaultPkiCertificate -Vault $vault -Role nasuni-dashboard -CommonName dash.test
        @($script:Fake.Calls | Where-Object Path -EQ '/v1/pki/issue/nasuni-dashboard').Count | Should -Be 1
        @($script:Fake.Calls | Where-Object Path -EQ '/v1/pki/issue/login-role').Count | Should -Be 0
    }

    It 'validates its inputs' {
        { Get-NasuniVaultCredential -VaultAddress https://v -Mount kv -SecretPath nasuni/nmc-ro -AuthMethod Cert } | Should -Throw '*needs -ClientCertificateThumbprint*'
        { Get-NasuniVaultCredential -VaultAddress https://v -Mount kv -SecretPath nasuni/nmc-ro -AuthMethod AppRole } | Should -Throw '*needs -RoleId*'
        { Get-NasuniVaultCredential -VaultAddress https://v -Mount kv -SecretPath 'a/../b' -AuthMethod AppRole } | Should -Throw
        { Get-NasuniVaultCredential -VaultAddress https://v -Mount 'kv;x' -SecretPath a -AuthMethod AppRole } | Should -Throw
    }
}

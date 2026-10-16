# End-to-end over a real TLS handshake with a private test CA on localhost.
BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath '../LocalTlsServer.ps1')
    $script:Dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nmc-tls-" + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $script:Dir
    $script:Pki = New-TestPki -Directory $script:Dir
    $script:Server = Start-TestTlsServer -Pfx $script:Pki.Pfx
    $script:Port = $script:Server.State.Port

    function Get-ServerRequest([string]$Pattern) {
        , @($script:Server.State.Requests.ToArray() | Where-Object { "$($_.Method) $($_.Target)" -match $Pattern })
    }
    function Connect-Local {
        param([string]$Pin)
        $p = @{ ComputerName = 'localhost'; Port = $script:Port; Credential = (Get-CanaryCredential); TrustedCaCertificatePath = $script:Pki.CaPemPath; RevocationMode = 'NoCheck' }
        if ($Pin) { $p.PinnedSpkiSha256 = $Pin }
        Connect-Nasuni @p
    }
}

AfterAll {
    InModuleScope Nasuni.Nmc { if ($script:NmcState.HttpClient) { Disconnect-Nasuni } }
    if ($script:Server) {
        $errs = $script:Server.State.Errors.ToArray()
        Stop-TestTlsServer -Server $script:Server
        if ($errs) { Write-Verbose ("server-side handshake errors (expected for rejection tests): " + ($errs -join ' | ')) }
    }
    if ($script:Dir) { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Certificate validation over real TLS' {
    It 'rejects the server when its CA is not trusted' {
        $r = Test-NasuniNmcTls -ComputerName localhost -Port $script:Port -RevocationMode NoCheck
        $r.CertificateValid | Should -BeFalse
        $r.Error | Should -Not -BeNullOrEmpty
    }
    It 'accepts it with the private CA (PEM), negotiating an approved AES-GCM suite' {
        $r = Test-NasuniNmcTls -ComputerName localhost -Port $script:Port -TrustedCaCertificatePath $script:Pki.CaPemPath -RevocationMode NoCheck
        $r.Error | Should -BeNullOrEmpty
        $r.CertificateValid | Should -BeTrue
        $r.Protocol | Should -BeIn @('Tls12', 'Tls13')
        $r.IsFipsApprovedSuite | Should -BeTrue
        $r.SpkiSha256 | Should -Be $script:Pki.SpkiSha256
    }
    It 'accepts the private CA as a DER file too' {
        (Test-NasuniNmcTls -ComputerName localhost -Port $script:Port -TrustedCaCertificatePath $script:Pki.CaDerPath -RevocationMode NoCheck).CertificateValid | Should -BeTrue
    }
    It 'fails closed when revocation is required but the CA publishes no CRL' {
        (Test-NasuniNmcTls -ComputerName localhost -Port $script:Port -TrustedCaCertificatePath $script:Pki.CaPemPath -RevocationMode Online).CertificateValid | Should -BeFalse
    }
    It 'rejects a host name that does not match the certificate' {
        (Test-NasuniNmcTls -ComputerName 127.0.0.1 -Port $script:Port -TrustedCaCertificatePath $script:Pki.CaPemPath -RevocationMode NoCheck).CertificateValid | Should -BeFalse
    }
    It 'reports a closed port as an error rather than throwing' {
        $closed = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $closed.Start(); $p = ([System.Net.IPEndPoint]$closed.LocalEndpoint).Port; $closed.Stop()
        (Test-NasuniNmcTls -ComputerName localhost -Port $p -TimeoutSeconds 3).Error | Should -Not -BeNullOrEmpty
    }
}

Describe 'SPKI pinning' {
    It 'refuses to send credentials when the pin does not match' {
        $before = (Get-ServerRequest '^POST /api/v1\.2/auth/login/').Count
        $wrong = [Convert]::ToBase64String([byte[]]::new(32))
        { Connect-Local -Pin $wrong } | Should -Throw '*pin mismatch*No credentials were sent*'
        (Get-ServerRequest '^POST /api/v1\.2/auth/login/').Count | Should -Be $before
    }
    It 'connects when the pin matches' {
        (Connect-Local -Pin $script:Pki.SpkiSha256).PinnedSpki | Should -BeTrue
    }
    It 'enforces the pin on the HTTP client itself, not only in the preflight' {
        InModuleScope Nasuni.Nmc -Parameters @{ Port = $script:Port; Ca = $script:Pki.CaPemPath; Good = $script:Pki.SpkiSha256 } {
            param($Port, $Ca, $Good)
            $uri = "https://localhost:$Port/api/v1.2/volumes/"
            $wrong = [Convert]::ToBase64String([byte[]]::new(32))
            $bad = New-NmcHttpClient -TrustedCaCertificatePath $Ca -RevocationMode NoCheck -PinnedSpkiSha256 $wrong
            try { { Invoke-NmcHttp -Client $bad -Method GET -Uri $uri } | Should -Throw } finally { $bad.Dispose() }
            $ok = New-NmcHttpClient -TrustedCaCertificatePath $Ca -RevocationMode NoCheck -PinnedSpkiSha256 $Good
            try { (Invoke-NmcHttp -Client $ok -Method GET -Uri $uri).StatusCode | Should -BeLessThan 500 } finally { $ok.Dispose() }
        }
    }
    It 'still rejects an untrusted chain when the pin matches' {
        InModuleScope Nasuni.Nmc -Parameters @{ Port = $script:Port; Good = $script:Pki.SpkiSha256 } {
            param($Port, $Good)
            $c = New-NmcHttpClient -RevocationMode NoCheck -PinnedSpkiSha256 $Good
            try { { Invoke-NmcHttp -Client $c -Method GET -Uri "https://localhost:$Port/api/v1.2/volumes/" } | Should -Throw } finally { $c.Dispose() }
        }
    }
}

Describe 'Real transport end to end' {
    BeforeAll { Connect-Local | Out-Null }

    It 'logs in over TLS with valid JSON and pages a list' {
        $login = (Get-ServerRequest '^POST /api/v1\.2/auth/login/')[-1]
        ($login.Body | ConvertFrom-Json).password | Should -BeExactly $script:CanaryPassword
        $before = (Get-ServerRequest '^GET /api/v1\.2/volumes/').Count
        $vols = @(Get-NasuniVolumes -PageSize 2)
        $vols.Count | Should -Be 5
        (Get-ServerRequest '^GET /api/v1\.2/volumes/').Count - $before | Should -Be 3
        (Get-ServerRequest '^GET /api/v1\.2/volumes/')[-1].Authorization | Should -Be 'Token local-token-123456'
    }
    It 'Invoke-NasuniRequest -All pages, and without -All returns the raw page' {
        @(Invoke-NasuniRequest -Path /volumes/ -All -PageSize 2).Count | Should -Be 5
        (Invoke-NasuniRequest -Path /volumes/ -Query @{ limit = 1; offset = 0 }).Paging.total | Should -Be 5
        { Invoke-NasuniRequest -Method PATCH -Path /volumes/v1/ -All } | Should -Throw '*only to GET*'
    }
    It 'sends a PATCH only after confirmation' {
        $before = (Get-ServerRequest '^PATCH ').Count
        Invoke-NasuniRequest -Method PATCH -Path /volumes/v1/ -Body @{ name = 'x' } -WhatIf
        (Get-ServerRequest '^PATCH ').Count | Should -Be $before
        (Invoke-NasuniRequest -Method PATCH -Path /volumes/v1/ -Body @{ name = 'x' } -Confirm:$false).message.status | Should -Be 'pending'
        (Get-ServerRequest '^PATCH ').Count | Should -Be ($before + 1)
    }
    It 'reads Retry-After from a real 429 response' {
        InModuleScope Nasuni.Nmc {
            $r = Invoke-NmcHttp -Client $script:NmcState.HttpClient -Method GET -Uri ($script:NmcState.BaseUri + '/throttle/')
            $r.StatusCode | Should -Be 429
            [double]$r.RetryAfter | Should -Be 2
        }
    }
    It 'does not follow redirects and exposes Location (303 on a message)' {
        InModuleScope Nasuni.Nmc {
            $r = Invoke-NmcHttp -Client $script:NmcState.HttpClient -Method GET -Uri ($script:NmcState.BaseUri + '/messages/m1/')
            $r.StatusCode | Should -Be 303
            $r.Location | Should -Match '/api/v1\.2/volumes/v1/$'
        }
        (Wait-NasuniMessage -MessageId m1).status | Should -Be 'synced'
    }
    It 'logs out on Disconnect-Nasuni' {
        $before = (Get-ServerRequest '^POST /api/v1\.2/auth/logout/').Count
        Disconnect-Nasuni
        (Get-ServerRequest '^POST /api/v1\.2/auth/logout/').Count | Should -Be ($before + 1)
        (Get-NasuniConnection).Connected | Should -BeFalse
    }
}

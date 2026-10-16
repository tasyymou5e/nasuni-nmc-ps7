# Test-only PKI and a minimal HTTPS "NMC" served over a real TLS handshake on localhost.
# Used to test certificate validation, SPKI pinning, private-CA trust and the real
# HttpClient transport without any external network.
Set-StrictMode -Version Latest

function New-TestPki {
    param([string]$Directory)
    $now = [datetimeoffset]::UtcNow
    $sha256 = [System.Security.Cryptography.HashAlgorithmName]::SHA256
    $X509 = 'System.Security.Cryptography.X509Certificates'

    $caKey = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
    $caReq = New-Object "$X509.CertificateRequest" -ArgumentList 'CN=Nasuni.Nmc Test CA', $caKey, $sha256
    $caReq.CertificateExtensions.Add((New-Object "$X509.X509BasicConstraintsExtension" -ArgumentList $true, $false, 0, $true))
    $caReq.CertificateExtensions.Add((New-Object "$X509.X509KeyUsageExtension" -ArgumentList ([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]'KeyCertSign, CrlSign'), $true))
    $ca = $caReq.CreateSelfSigned($now.AddDays(-1), $now.AddDays(30))

    $leafKey = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
    $leafReq = New-Object "$X509.CertificateRequest" -ArgumentList 'CN=localhost', $leafKey, $sha256
    $san = New-Object "$X509.SubjectAlternativeNameBuilder"
    $san.AddDnsName('localhost')
    $leafReq.CertificateExtensions.Add($san.Build())
    $eku = [System.Security.Cryptography.OidCollection]::new()
    $null = $eku.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    $leafReq.CertificateExtensions.Add((New-Object "$X509.X509EnhancedKeyUsageExtension" -ArgumentList $eku, $false))
    $leafReq.CertificateExtensions.Add((New-Object "$X509.X509BasicConstraintsExtension" -ArgumentList $false, $false, 0, $false))
    $serial = [byte[]]::new(16); [System.Security.Cryptography.RandomNumberGenerator]::Fill($serial); $serial[0] = $serial[0] -band 0x7F
    $leafPublic = $leafReq.Create($ca, $now.AddHours(-1), $now.AddDays(7), $serial)
    $leaf = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::CopyWithPrivateKey($leafPublic, $leafKey)

    $caPem = Join-Path -Path $Directory -ChildPath 'test-ca.pem'
    $caDer = Join-Path -Path $Directory -ChildPath 'test-ca.cer'
    [System.IO.File]::WriteAllText($caPem, $ca.ExportCertificatePem())
    [System.IO.File]::WriteAllBytes($caDer, $ca.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))

    $leafCertPem = Join-Path -Path $Directory -ChildPath 'leaf.crt'
    $leafKeyPem = Join-Path -Path $Directory -ChildPath 'leaf.key'
    [System.IO.File]::WriteAllText($leafCertPem, $leafPublic.ExportCertificatePem())
    [System.IO.File]::WriteAllText($leafKeyPem, $leafKey.ExportPkcs8PrivateKeyPem())
    if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($leafKeyPem, [System.IO.UnixFileMode]'UserRead, UserWrite') }

    [pscustomobject]@{
        LeafCertPemPath = $leafCertPem
        LeafKeyPemPath  = $leafKeyPem
        CaPemPath  = $caPem
        CaDerPath  = $caDer
        Pfx        = $leaf.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12)
        SpkiSha256 = [Convert]::ToBase64String([System.Security.Cryptography.SHA256]::HashData($leafPublic.PublicKey.ExportSubjectPublicKeyInfo()))
    }
}

function Start-TestTlsServer {
    # MaxLifetimeMinutes: tests keep the 5-minute safety stop so a crashed run never leaves a
    # listener behind; the demo passes 0 (run until the process exits).
    param([byte[]]$Pfx, [hashtable]$Data, [ValidateRange(0, 100000)][int]$MaxLifetimeMinutes = 5)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $state = [hashtable]::Synchronized(@{
            Stop       = $false
            Port       = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            Requests   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
            Errors     = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            Handshakes = 0
            Ciphers    = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            Throttled  = 0
            Data       = $Data
            MessageSeq = 0
        })

    $job = Start-ThreadJob -ArgumentList $Pfx, $listener, $state, $MaxLifetimeMinutes -ScriptBlock {
        param($pfx, $listener, $state, $lifetime)
        # Thread job: no module here, so inline the .NET 8/9-compatible PKCS#12 load (see Import-NasuniCertificate).
        $loader = 'System.Security.Cryptography.X509Certificates.X509CertificateLoader' -as [type]
        $cert = if ($loader) { $loader::LoadPkcs12($pfx, $null) } else { [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, [string]$null) }
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $deadline = if ($lifetime -gt 0) { [datetime]::UtcNow.AddMinutes($lifetime) } else { [datetime]::MaxValue }
        while (-not $state.Stop -and [datetime]::UtcNow -lt $deadline) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 10; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false)
                $ssl.ReadTimeout = 5000; $ssl.WriteTimeout = 5000
                $ssl.AuthenticateAsServer($cert, $false, [System.Security.Authentication.SslProtocols]'Tls12, Tls13', $false)
                $state.Handshakes++
                $state.Ciphers.Enqueue([string]$ssl.NegotiatedCipherSuite)

                $reader = [System.IO.StreamReader]::new($ssl, $utf8, $false, 4096, $true)
                $requestLine = $reader.ReadLine()
                if (-not $requestLine) { continue }
                $headers = @{}
                while ($line = $reader.ReadLine()) {
                    $i = $line.IndexOf(':')
                    if ($i -gt 0) { $headers[$line.Substring(0, $i).Trim().ToLowerInvariant()] = $line.Substring($i + 1).Trim() }
                }
                $len = if ($headers.ContainsKey('content-length')) { [int]$headers['content-length'] } else { 0 }
                $body = ''
                if ($len -gt 0) {
                    $buf = [char[]]::new($len); $read = 0
                    while ($read -lt $len) { $n = $reader.Read($buf, $read, $len - $read); if ($n -le 0) { break }; $read += $n }
                    $body = [string]::new($buf, 0, $read)
                }
                $method, $target = ($requestLine -split ' ')[0, 1]
                $state.Requests.Enqueue([pscustomobject]@{ Method = $method; Target = $target; Authorization = $headers['authorization']; Body = $body })

                $status = 404; $reason = 'Not Found'; $json = '{"error":"not found"}'; $extra = ''
                $uri = [uri]"https://localhost$target"
                $q = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
                $path = $uri.AbsolutePath
                $strip = { param($o) $c = [ordered]@{}; foreach ($k in $o.Keys) { if (-not ([string]$k).StartsWith('__')) { $c[$k] = $o[$k] } }; $c }
                $dataMode = $null -ne $state.Data
                if ($dataMode) {
                    if ($method -eq 'POST' -and $path -eq '/api/v1.2/auth/login/') {
                        $status = 200; $reason = 'OK'; $json = (@{ token = 'local-token-123456'; expires = [datetime]::UtcNow.AddHours(1).ToString('o') } | ConvertTo-Json -Compress)
                    }
                    elseif ($method -eq 'POST' -and $path -eq '/api/v1.2/auth/logout/') { $status = 200; $reason = 'OK'; $json = '{}' }
                    elseif ($method -eq 'GET' -and $path -match '^/api/v1\.2/messages/([^/]+)/$') {
                        $status = 200; $reason = 'OK'; $json = (@{ id = $Matches[1]; status = 'synced' } | ConvertTo-Json -Compress)
                    }
                    elseif ($state.Data.ContainsKey($path)) {
                        $entry = $state.Data[$path]
                        if ($method -eq 'GET' -and $entry -is [System.Collections.IList]) {
                            $live = @($entry | Where-Object { -not $_.ContainsKey('__deleted') })
                            $limit = if ($q['limit']) { [int]$q['limit'] } else { 50 }; $offset = if ($q['offset']) { [int]$q['offset'] } else { 0 }
                            $page = @($live | Select-Object -Skip $offset -First $limit | ForEach-Object { & $strip $_ })
                            $status = 200; $reason = 'OK'
                            $json = (@{ Paging = @{ total = $live.Count; limit = $limit; offset = $offset; next = $null }; items = $page } | ConvertTo-Json -Compress -Depth 10)
                        }
                        elseif ($entry.ContainsKey('__deleted')) { $status = 404; $reason = 'Not Found' }
                        elseif ($method -eq 'GET') { $status = 200; $reason = 'OK'; $json = ((& $strip $entry) | ConvertTo-Json -Compress -Depth 10) }
                        elseif ($method -in 'PATCH', 'PUT') {
                            $b = $body | ConvertFrom-Json -AsHashtable
                            foreach ($k in $b.Keys) { $entry[$k] = $b[$k] }
                            $state.MessageSeq++
                            $status = 202; $reason = 'Accepted'; $json = (@{ message = @{ id = "m-$($state.MessageSeq)"; status = 'pending' } } | ConvertTo-Json -Compress)
                        }
                        elseif ($method -eq 'DELETE') {
                            $entry['__deleted'] = $true
                            $entry['__action'] = $q['action']
                            $state.MessageSeq++
                            $status = 202; $reason = 'Accepted'; $json = (@{ message = @{ id = "m-$($state.MessageSeq)"; status = 'pending' } } | ConvertTo-Json -Compress)
                        }
                    }
                }
                if (-not $dataMode) { switch -Regex ("$method $($uri.AbsolutePath)") {
                    '^POST /api/v1\.2/auth/login/$' {
                        $status = 200; $reason = 'OK'
                        $json = (@{ token = 'local-token-123456'; expires = [datetime]::UtcNow.AddHours(1).ToString('o') } | ConvertTo-Json -Compress)
                    }
                    '^POST /api/v1\.2/auth/logout/$' { $status = 200; $reason = 'OK'; $json = '{}' }
                    '^GET /api/v1\.2/volumes/$' {
                        $limit = [int]$q['limit']; $offset = [int]$q['offset']; $total = 5
                        $items = @(for ($k = $offset; $k -lt [math]::Min($total, $offset + $limit); $k++) { @{ guid = "v$k" } })
                        $status = 200; $reason = 'OK'
                        $json = (@{ Paging = @{ total = $total; limit = $limit; offset = $offset; next = $null }; items = $items } | ConvertTo-Json -Compress -Depth 5)
                    }
                    '^PATCH /api/v1\.2/volumes/v1/$' {
                        $status = 202; $reason = 'Accepted'
                        $json = '{"message":{"id":"m1","status":"pending"}}'
                    }
                    '^GET /api/v1\.2/throttle/$' {
                        $state.Throttled++
                        $status = 429; $reason = 'Too Many Requests'; $json = '{"detail":"Request throttled."}'; $extra = "Retry-After: 2`r`n"
                    }
                    '^GET /api/v1\.2/messages/m1/$' {
                        $status = 303; $reason = 'See Other'; $json = ''
                        $extra = "Location: https://localhost:$($state.Port)/api/v1.2/volumes/v1/`r`n"
                    }
                } }
                $bytes = $utf8.GetBytes($json)
                $head = "HTTP/1.1 $status $reason`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n$extra`r`n"
                $ssl.Write($utf8.GetBytes($head)); $ssl.Write($bytes); $ssl.Flush()
            }
            catch { $state.Errors.Enqueue($_.Exception.Message) }
            finally { $client.Dispose() }
        }
        $listener.Stop()
    }
    [pscustomobject]@{ State = $state; Job = $job; Listener = $listener }
}

function Stop-TestTlsServer {
    param($Server)
    $Server.State.Stop = $true
    $null = Wait-Job -Job $Server.Job -Timeout 10
    Remove-Job -Job $Server.Job -Force
}

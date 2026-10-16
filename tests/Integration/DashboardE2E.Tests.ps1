# End to end: the real dashboard process (Pode, HTTPS) against a fake NMC over TLS.
BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath '../LocalTlsServer.ps1')
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../src/Nasuni.Nmc.Dashboard/Nasuni.Nmc.Dashboard.psm1') -Force

    $script:Dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nmc-e2e-" + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $script:Dir
    $script:Pki = New-TestPki -Directory $script:Dir

    # --- fake NMC data (list entries and single-resource entries share the same hashtables)
    $share5 = @{ id = 5; name = 'Finance'; volume_guid = 'v1'; filer_serial_number = 's1'; path = '=cmd|/C calc!A0'; readonly = $false; browseable = $true }
    $shareX = @{ id = 6; name = '<script>alert("xss")</script>'; volume_guid = 'v1'; filer_serial_number = 's1'; path = '/x'; readonly = $false; browseable = $true }
    $av9 = @{ id = 9; fpath = '/Finance/evil.exe'; vname = 'Finance'; volume_guid = 'v1'; filer_serial_number = 's1' }
    $data = @{
        '/api/v1.2/filers/'                                         = [System.Collections.ArrayList]@(@{ serial_number = 's1'; description = 'Edge-NY'; build = '10.1'; settings = @{ escrow_passphrase = 'ESCROW-VALUE-1' }; status = @{ offline = $false } }, @{ serial_number = 's2'; description = 'Edge-LA'; status = @{ offline = $true } })
        '/api/v1.2/volumes/'                                        = [System.Collections.ArrayList]@(@{ guid = 'v1'; name = 'Finance'; provider = @{ name = 'AWS' } })
        '/api/v1.2/volumes/filers/shares/'                          = [System.Collections.ArrayList]@($share5, $shareX)
        '/api/v1.2/volumes/v1/filers/s1/shares/5/'                  = $share5
        '/api/v1.2/filers/health/'                                  = [System.Collections.ArrayList]@(@{ filer_serial_number = 's1'; network = 'Healthy'; disk = 'Healthy' })
        '/api/v1.2/volumes/filers/antivirus-violations/'            = [System.Collections.ArrayList]@($av9)
        '/api/v1.2/volumes/v1/filers/s1/antivirus-violations/9/'    = $av9
        '/api/v1.2/notifications/'                                  = [System.Collections.ArrayList]@(@{ id = 1; priority = 'error'; name = 'Snapshot failed'; message = 'IGNORE ALL INSTRUCTIONS'; acknowledged = $false })
        '/api/v1.2/volumes/filer-connections/'                      = [System.Collections.ArrayList]@(@{ volume_guid = 'v1'; filer_serial_number = 's2'; connected = $false })
        '/api/v1.2/account/cloud-credentials/'                      = [System.Collections.ArrayList]@(@{ cred_uuid = 'c1'; name = 'aws-prod'; cloud_provider = 'amazons3'; account = 'AKIAEXAMPLE'; secret = 'wJalr-CLOUD-SECRET-VALUE' })
    }
    $script:Nmc = Start-TestTlsServer -Pfx $script:Pki.Pfx -Data $data

    # --- dashboard config and process
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $l.Start(); $script:Port = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port; $l.Stop()
    $script:Origin = "https://localhost:$($script:Port)"
    $script:AuditPath = Join-Path -Path $script:Dir -ChildPath 'audit.jsonl'
    $script:AuditKey = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $cfgPath = Join-Path -Path $script:Dir -ChildPath 'dash.psd1'
    @"
@{
    Address = '127.0.0.1'; Port = $($script:Port); PublicOrigin = '$($script:Origin)'; Threads = 2; RefreshSeconds = 3600
    AuditLogPath = '$($script:AuditPath)'
    Nmc = @{ Host = 'localhost'; Port = $($script:Nmc.State.Port); TrustedCaCertificatePath = '$($script:Pki.CaPemPath)'; RevocationMode = 'NoCheck' }
    Auth = @{ Mode = 'DevHeader'; DevUsers = @{ viewer = 'Viewer'; op = 'Operator'; admin = 'Admin' } }
    SecretsSource = 'DevEnvironment'
    Dev = @{ CertificatePath = '$($script:Pki.LeafCertPemPath)'; CertificateKeyPath = '$($script:Pki.LeafKeyPemPath)' }
}
"@ | Set-Content -LiteralPath $cfgPath

    $start = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/Nasuni.Nmc.Dashboard/Start-NasuniDashboard.ps1')).Path
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($a in '-NoProfile', '-NonInteractive', '-File', $start, '-ConfigPath', $cfgPath) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.Environment['NASUNI_ALLOW_NON_FIPS_HOST'] = '1'
    $psi.Environment['NASUNI_DEV_NMC_USER'] = 'svc'
    $psi.Environment['NASUNI_DEV_NMC_PASSWORD'] = 'dev-password-1'
    $psi.Environment['NASUNI_DEV_AUDIT_KEY_B64'] = [Convert]::ToBase64String($script:AuditKey)
    $script:Proc = [System.Diagnostics.Process]::Start($psi)
    $script:ProcOut = $script:Proc.StandardOutput.ReadToEndAsync()
    $script:ProcErr = $script:Proc.StandardError.ReadToEndAsync()

    function New-DashClient {
        $h = [System.Net.Http.SocketsHttpHandler]::new()
        $policy = [System.Security.Cryptography.X509Certificates.X509ChainPolicy]::new()
        $policy.TrustMode = [System.Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        $ca = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new(); $ca.ImportFromPemFile($script:Pki.CaPemPath)
        $policy.CustomTrustStore.AddRange($ca)
        $policy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $h.SslOptions.CertificateChainPolicy = $policy
        $h.AllowAutoRedirect = $false
        $h.UseCookies = $true
        $h.CookieContainer = [System.Net.CookieContainer]::new()
        $c = [System.Net.Http.HttpClient]::new($h, $true)
        $c.Timeout = [timespan]::FromSeconds(60)
        $c
    }
    function Invoke-Dash {
        param($Client, [string]$Method = 'GET', [string]$Path, [string]$User, [hashtable]$Form, [string]$Origin = $script:Origin, [string]$FetchSite)
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), "$($script:Origin)$Path")
        if ($User) { $req.Headers.Add('X-Dev-User', $User) }
        if ($Method -ne 'GET' -and $Origin) { $req.Headers.Add('Origin', $Origin) }
        if ($FetchSite) { $req.Headers.Add('Sec-Fetch-Site', $FetchSite) }
        if ($Form) {
            $pairs = [System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string, string]]]::new()
            foreach ($k in $Form.Keys) { $pairs.Add([System.Collections.Generic.KeyValuePair[string, string]]::new($k, [string]$Form[$k])) }
            $req.Content = [System.Net.Http.FormUrlEncodedContent]::new($pairs)
        }
        $resp = $Client.Send($req)
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $body; Headers = $resp.Headers; ContentHeaders = $resp.Content.Headers }
    }
    function Get-Csrf([string]$Html) {
        $m = [regex]::Match($Html, 'name="pode\.csrf" value="([^"]+)"')
        if (-not $m.Success) { throw 'No CSRF token in page.' }
        [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
    }
    function Get-NmcWrites { , @($script:Nmc.State.Requests.ToArray() | Where-Object { $_.Method -in 'PATCH', 'DELETE', 'PUT' }) }

    # Wait for the dashboard to come up and load its first snapshot.
    $script:Viewer = New-DashClient
    $deadline = [datetime]::UtcNow.AddSeconds(90)
    $ready = $false
    while ([datetime]::UtcNow -lt $deadline -and -not $script:Proc.HasExited) {
        try { $r = Invoke-Dash -Client $script:Viewer -Path '/' -User viewer; if ($r.Status -eq 200 -and $r.Body -match 'Data as of') { $ready = $true; break } } catch { }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) {
        if (-not $script:Proc.HasExited) { $script:Proc.Kill($true) }
        throw "Dashboard did not start. stdout: $($script:ProcOut.Result) stderr: $($script:ProcErr.Result)"
    }
}

AfterAll {
    if ($script:Proc -and -not $script:Proc.HasExited) { $script:Proc.Kill($true); $null = $script:Proc.WaitForExit(10000) }
    if ($script:Nmc) { Stop-TestTlsServer -Server $script:Nmc }
    if ($script:Dir) { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Dashboard over HTTPS' {
    Context 'Authentication and headers' {
        It 'rejects an unauthenticated request' {
            (Invoke-Dash -Client (New-DashClient) -Path '/').Status | Should -Be 401
        }
        It 'serves the overview with strict security headers and a hardened session cookie' {
            $r = Invoke-Dash -Client (New-DashClient) -Path '/' -User viewer
            $r.Status | Should -Be 200
            $csp = ($r.Headers.GetValues('Content-Security-Policy') -join ';')
            $csp | Should -Match "script-src 'none'"
            $csp | Should -Match "frame-ancestors 'none'"
            ($r.Headers.GetValues('Strict-Transport-Security') -join '') | Should -Match 'max-age=31536000'
            $cookie = $r.Headers.GetValues('Set-Cookie') -join ' | '
            $cookie | Should -Match 'HttpOnly'
            $cookie | Should -Match 'Secure'
            $cookie | Should -Match 'SameSite=Strict'
            $r.Headers.Contains('Server') | Should -BeFalse
        }
        It 'shows live counts from the NMC (2 filers, 1 offline, 1 disconnected, 1 alert)' {
            $b = (Invoke-Dash -Client $script:Viewer -Path '/' -User viewer).Body
            $b | Should -Match '<span class="n">2</span><span>Filers</span>'
            $b | Should -Match '<span class="n">1</span><span>Offline filers</span>'
            $b | Should -Match '<span class="n">1</span><span>Disconnected volume/filer pairs</span>'
            $b | Should -Match '<span class="n">1</span><span>Unacknowledged errors and alerts</span>'
        }
    }

    Context 'Output safety' {
        It 'HTML-encodes NMC data (no script injection)' {
            $b = (Invoke-Dash -Client $script:Viewer -Path '/shares' -User viewer).Body
            $b | Should -Not -Match '<script>alert'
            $b | Should -Match '&lt;script&gt;alert'
        }
        It 'never shows secrets on any page or report' {
            foreach ($p in '/credentials', '/filers', '/reports/credentials.csv', '/reports/filers.csv') {
                (Invoke-Dash -Client $script:Viewer -Path $p -User viewer).Body | Should -Not -MatchExactly 'wJalr-CLOUD-SECRET-VALUE|ESCROW-VALUE-1'
            }
        }
        It 'neutralises formulas in CSV reports' {
            $r = Invoke-Dash -Client $script:Viewer -Path '/reports/shares.csv' -User viewer
            $r.Status | Should -Be 200
            ($r.ContentHeaders.ContentType.MediaType) | Should -Be 'text/csv'
            $r.Body | Should -Match ([regex]::Escape("""'=cmd|/C calc!A0"""))
        }
        It 'returns 404 for unknown or malformed report names' {
            (Invoke-Dash -Client $script:Viewer -Path '/reports/evil.csv' -User viewer).Status | Should -Be 404
            (Invoke-Dash -Client $script:Viewer -Path '/reports/..%2Fconfig.csv' -User viewer).Status | Should -BeIn @(400, 404)
        }
    }

    Context 'Role-based access' {
        It 'hides change links from viewers and shows them to operators' {
            (Invoke-Dash -Client $script:Viewer -Path '/shares' -User viewer).Body | Should -Not -Match '/actions/'
            (Invoke-Dash -Client (New-DashClient) -Path '/shares' -User op).Body | Should -Match '/actions/share-readonly'
        }
        It 'refuses <Path> for <User>' -ForEach @(
            @{ User = 'viewer'; Path = '/actions/share-readonly?volume_guid=v1&filer_serial=s1&share_id=5&readonly=true' }
            @{ User = 'viewer'; Path = '/audit' }
            @{ User = 'op'; Path = '/actions/antivirus-delete?volume_guid=v1&filer_serial=s1&antivirus_id=9' }
            @{ User = 'op'; Path = '/audit' }
        ) {
            (Invoke-Dash -Client (New-DashClient) -Path $Path -User $User).Status | Should -Be 403
        }
    }

    Context 'Change flow' {
        BeforeAll {
            $script:Op = New-DashClient
            $script:ActionPath = '/actions/share-readonly?volume_guid=v1&filer_serial=s1&share_id=5&readonly=true'
            $script:PreviewForm = @{ volume_guid = 'v1'; filer_serial = 's1'; share_id = '5'; readonly = 'true' }
        }
        It 'rejects a POST without a CSRF token, or from another origin' {
            $before = (Get-NmcWrites).Count
            (Invoke-Dash -Client $script:Op -Method POST -Path '/actions/share-readonly/preview' -User op -Form $script:PreviewForm).Status | Should -Be 403
            $page = (Invoke-Dash -Client $script:Op -Path $script:ActionPath -User op).Body
            $form = @{} + $script:PreviewForm; $form['pode.csrf'] = Get-Csrf $page
            (Invoke-Dash -Client $script:Op -Method POST -Path '/actions/share-readonly/preview' -User op -Form $form -Origin 'https://evil.example').Status | Should -Be 403
            (Invoke-Dash -Client $script:Op -Method POST -Path '/actions/share-readonly/preview' -User op -Form $form -Origin '').Status | Should -Be 403
            (Get-NmcWrites).Count | Should -Be $before
        }
        It 'accepts what a real browser sends on a form POST (Origin: null + Sec-Fetch-Site: same-origin) and rejects cross-site' {
            $page = (Invoke-Dash -Client $script:Op -Path $script:ActionPath -User op)
            ($page.Headers.GetValues('Referrer-Policy') -join '') | Should -Be 'same-origin'
            $form = @{} + $script:PreviewForm; $form['pode.csrf'] = Get-Csrf $page.Body
            (Invoke-Dash -Client $script:Op -Method POST -Path '/actions/share-readonly/preview' -User op -Form $form -Origin 'null' -FetchSite 'same-origin').Status | Should -Be 200
            $form['pode.csrf'] = Get-Csrf (Invoke-Dash -Client $script:Op -Path $script:ActionPath -User op).Body
            (Invoke-Dash -Client $script:Op -Method POST -Path '/actions/share-readonly/preview' -User op -Form $form -Origin 'null' -FetchSite 'cross-site').Status | Should -Be 403
        }
        It 'refuses a wrong phrase, consumes the preview, then applies and verifies with the right phrase' {
            $before = (Get-NmcWrites).Count
            $page = (Invoke-Dash -Client $script:Op -Path $script:ActionPath -User op).Body
            $form = @{} + $script:PreviewForm; $form['pode.csrf'] = Get-Csrf $page
            $preview = Invoke-Dash -Client $script:Op -Method POST -Path '/actions/share-readonly/preview' -User op -Form $form
            $preview.Status | Should -Be 200
            $preview.Body | Should -Match 'from False to True'
            $pendingId = [regex]::Match($preview.Body, 'name="pending_id" value="([^"]+)"').Groups[1].Value

            $wrong = Invoke-Dash -Client $script:Op -Method POST -Path '/actions/execute' -User op -Form @{ pending_id = $pendingId; confirm = 'finance'; 'pode.csrf' = (Get-Csrf $preview.Body) }
            $wrong.Status | Should -Be 400
            $wrong.Body | Should -Match 'does not match'
            $fresh = Get-Csrf (Invoke-Dash -Client $script:Op -Path $script:ActionPath -User op).Body
            $replay = Invoke-Dash -Client $script:Op -Method POST -Path '/actions/execute' -User op -Form @{ pending_id = $pendingId; confirm = 'Finance'; 'pode.csrf' = $fresh }
            $replay.Status | Should -Be 400
            $replay.Body | Should -Match 'No matching pending'
            (Get-NmcWrites).Count | Should -Be $before

            $page = (Invoke-Dash -Client $script:Op -Path $script:ActionPath -User op).Body
            $form['pode.csrf'] = Get-Csrf $page
            $preview = Invoke-Dash -Client $script:Op -Method POST -Path '/actions/share-readonly/preview' -User op -Form $form
            $pendingId = [regex]::Match($preview.Body, 'name="pending_id" value="([^"]+)"').Groups[1].Value
            $ok = Invoke-Dash -Client $script:Op -Method POST -Path '/actions/execute' -User op -Form @{ pending_id = $pendingId; confirm = 'Finance'; 'pode.csrf' = (Get-Csrf $preview.Body) }
            $ok.Status | Should -Be 200
            $ok.Body | Should -Match 'applied and verified'
            $writes = @(Get-NmcWrites)
            $writes.Count | Should -Be ($before + 1)
            $writes[-1].Method | Should -Be 'PATCH'
            ($writes[-1].Body | ConvertFrom-Json).readonly | Should -BeTrue
        }
        It 'lets an admin delete an infected file only after typing DELETE and the path' {
            $admin = New-DashClient
            $page = (Invoke-Dash -Client $admin -Path '/actions/antivirus-delete?volume_guid=v1&filer_serial=s1&antivirus_id=9' -User admin).Body
            $preview = Invoke-Dash -Client $admin -Method POST -Path '/actions/antivirus-delete/preview' -User admin -Form @{ volume_guid = 'v1'; filer_serial = 's1'; antivirus_id = '9'; 'pode.csrf' = (Get-Csrf $page) }
            $preview.Body | Should -Match 'PERMANENTLY DELETE'
            $pendingId = [regex]::Match($preview.Body, 'name="pending_id" value="([^"]+)"').Groups[1].Value
            $ok = Invoke-Dash -Client $admin -Method POST -Path '/actions/execute' -User admin -Form @{ pending_id = $pendingId; confirm = 'DELETE /Finance/evil.exe'; 'pode.csrf' = (Get-Csrf $preview.Body) }
            $ok.Body | Should -Match 'applied and verified'
            ($script:Nmc.State.Requests.ToArray() | Where-Object Method -EQ 'DELETE' | Select-Object -Last 1).Target | Should -Match 'action=delete_file'
        }
        It 'records every attempt in a verifiable audit chain, visible to admins' {
            $chain = Test-DashAuditChain -Path $script:AuditPath -Key $script:AuditKey
            $chain.Valid | Should -BeTrue
            $chain.Count | Should -Be 4
            $entries = Read-DashAudit -Path $script:AuditPath
            $entries.result | Should -Be @('refused', 'refused', 'success', 'success')
            $entries[0].error | Should -Match 'does not match'
            $entries[2].action | Should -Be 'share-readonly'
            $entries[3].action | Should -Be 'antivirus-delete'
            (Invoke-Dash -Client (New-DashClient) -Path '/audit' -User admin).Body | Should -Match 'Chain verified: 4 records'
        }
    }

    Context 'Reports page' {
        It 'queues a live report, runs it in the background, and lets only the requester download it' {
            $v = New-DashClient
            $page = Invoke-Dash -Client $v -Path '/reports' -User viewer
            $page.Status | Should -Be 200
            $page.Body | Should -Match 'Run a live report'
            $page.Headers.Contains('X-Request-Id') | Should -BeTrue
            $q = Invoke-Dash -Client $v -Method POST -Path '/reports/run' -User viewer -Form @{ report = 'shares'; 'pode.csrf' = (Get-Csrf $page.Body) }
            $q.Status | Should -Be 302
            $href = $null
            $deadline = [datetime]::UtcNow.AddSeconds(60)
            while (-not $href -and [datetime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 500
                $m = [regex]::Match((Invoke-Dash -Client $v -Path '/reports' -User viewer).Body, 'href="(/reports/jobs/[0-9a-f]{32})"')
                if ($m.Success) { $href = $m.Groups[1].Value }
            }
            $href | Should -Not -BeNullOrEmpty
            $csv = Invoke-Dash -Client $v -Path $href -User viewer
            $csv.Status | Should -Be 200
            $csv.Body | Should -Match '"shareid","Volume_GUID"'
            $csv.Body | Should -Match ([regex]::Escape('"''=cmd|/C calc!A0"'))
            (Invoke-Dash -Client (New-DashClient) -Path $href -User op).Status | Should -Be 404
            (Invoke-Dash -Client (New-DashClient) -Path $href -User admin).Status | Should -Be 200
            # Refused-confirmation records have no 'action' field: test for the property (strict mode).
            @(Read-DashAudit -Path $script:AuditPath | Where-Object { $_.PSObject.Properties['action'] -and $_.action -eq 'report-run' }).Count | Should -Be 1
        }
        It 'rejects unknown reports and bad parameters' {
            $v = New-DashClient
            $page = Invoke-Dash -Client $v -Path '/reports' -User viewer
            (Invoke-Dash -Client $v -Method POST -Path '/reports/run' -User viewer -Form @{ report = 'path-info'; 'pode.csrf' = (Get-Csrf $page.Body) }).Status | Should -Be 400
        }
    }
}

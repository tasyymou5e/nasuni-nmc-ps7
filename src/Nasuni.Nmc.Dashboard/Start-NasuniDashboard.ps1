#Requires -Version 7.4
# ENTRY: dashboard server. Request path: endpoint (HTTPS) -> security headers -> session ->
# CSRF -> request-id -> same-origin check -> auth (OIDC) -> route -> endware (cookie fix, request log).
# Runspaces: routes use the operator NMC account; the 'refresh' and 'report-runner' timers use the
# read-only account. Shared data lives in Pode state (in memory only, never saved).
<#
.SYNOPSIS
    Starts the Nasuni NMC dashboard (Pode 2.14.1, HTTPS only).
.DESCRIPTION
    Security model:
      - HTTPS only (TLS 1.2/1.3); certificate issued by Vault PKI and re-issued before expiry.
      - OIDC sign-in (OAuth2 + PKCE); IdP groups map to Viewer / Operator / Admin.
      - Session cookie: HttpOnly, Secure, SameSite=Strict, 15-minute sliding expiry.
      - CSRF tokens on every form, plus a same-origin check on every unsafe request.
      - Strict CSP (no scripts at all), HSTS, no framing, no referrer leakage.
      - Reads come from a cached snapshot taken with the read-only NMC account; changes use
        the operator account through preview -> typed confirmation -> execute -> verify -> audit.
      - Secrets (NMC accounts, session secret, audit HMAC key, OIDC client secret) come from Vault.
.PARAMETER ConfigPath
    PowerShell data file; see dashboard-config.example.psd1.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ConfigPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$nmcModule = (Resolve-Path (Join-Path -Path $root -ChildPath '../Nasuni.Nmc/Nasuni.Nmc.psd1')).Path
$dashModule = (Resolve-Path (Join-Path -Path $root -ChildPath 'Nasuni.Nmc.Dashboard.psm1')).Path
Import-Module Pode -RequiredVersion 2.14.1
Import-Module $nmcModule -Force
Import-Module $dashModule -Force

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$isDev = $env:NASUNI_ALLOW_NON_FIPS_HOST -eq '1' -and $env:NASUNI_ENVIRONMENT -ne 'Production'
foreach ($k in 'Address', 'Port', 'PublicOrigin', 'Nmc', 'Auth', 'SecretsSource', 'AuditLogPath') {
    if (-not $config.ContainsKey($k)) { throw "Config is missing '$k'." }
}
$loopback = $config.Address -in @('127.0.0.1', '::1')
# Container exception (development only). Inside a container the server must listen on 0.0.0.0 to be
# reachable, so loopback-only dev features are allowed there ONLY when all of these hold:
#   - NASUNI_CONTAINER=1 (set by the image, never by config);
#   - Address is 0.0.0.0;
#   - the config states Dev.PublishedToHostLoopbackOnly = $true (compose publishes to 127.0.0.1 only).
# DEBUG NOTE (See docs/DOCKER.md): if the demo container refuses to start with a "loopback" error,
# one of these three is missing.
if (-not $loopback -and $env:NASUNI_CONTAINER -eq '1' -and $config.Address -eq '0.0.0.0' -and
    $config.ContainsKey('Dev') -and $config.Dev.ContainsKey('PublishedToHostLoopbackOnly') -and $config.Dev.PublishedToHostLoopbackOnly) {
    $loopback = $true
    Write-Warning 'CONTAINER DEV MODE: listening on 0.0.0.0 inside the container. Publish the port to 127.0.0.1 on the host ONLY.'
}
# Demo mode only: plain HTTP on a loopback address, for local previews in a browser that does
# not trust the test CA. Refused unless development mode is on and the address is loopback.
$devHttp = $config.ContainsKey('Dev') -and $config.Dev.ContainsKey('Http') -and $config.Dev.Http
if ($devHttp -and (-not $isDev -or -not $loopback)) { throw 'Dev.Http is only allowed in development mode on a loopback address.' }
$originPattern = if ($devHttp) { '^http://(localhost|127\.0\.0\.1):\d+$' } else { '^https://[^/\s]+$' }
if ($config.PublicOrigin -notmatch $originPattern) { throw "PublicOrigin must be like 'https://dash.corp.example' (no path)." }
$threads = if ($config.ContainsKey('Threads')) { [int]$config.Threads } else { 4 }
$rateShare = if ($config.ContainsKey('RateShare')) { [double]$config.RateShare } else { 0.6 }
$perRunspaceShare = [math]::Max(0.05, $rateShare / ($threads + 1))

function ConvertFrom-SecureToPlain([securestring]$s) { [System.Net.NetworkCredential]::new('', $s).Password }

#region Secrets and certificate ------------------------------------------------------
switch ($config.SecretsSource) {
    'Vault' {
        $v = $config.Vault
        $auth = @{}
        foreach ($k in 'Address', 'Namespace', 'AuthMethod', 'CertRole', 'ClientCertificateThumbprint', 'ClientCertificatePath', 'ClientKeyPath', 'RoleId', 'SecretIdPath', 'TrustedCaCertificatePath', 'RevocationMode') {
            if ($v.ContainsKey($k) -and $v[$k]) { $auth[$k] = $v[$k] }
        }
        $credArgs = @{ VaultAddress = $auth.Address; Mount = $v.Mount; AuthMethod = $auth.AuthMethod }
        foreach ($k in 'Namespace', 'CertRole', 'ClientCertificateThumbprint', 'ClientCertificatePath', 'ClientKeyPath', 'RoleId', 'SecretIdPath', 'TrustedCaCertificatePath', 'RevocationMode') { if ($auth.ContainsKey($k)) { $credArgs[$k] = $auth[$k] } }
        $credRo = Get-NasuniVaultCredential @credArgs -SecretPath $v.ReadOnlySecretPath
        $credOps = Get-NasuniVaultCredential @credArgs -SecretPath $v.OperatorSecretPath
        $sessionSecret = ConvertFrom-SecureToPlain (Get-NasuniVaultSecret -Vault $auth -Mount $v.Mount -SecretPath $v.SessionSecretPath -Field 'secret')
        $auditKey = [Convert]::FromBase64String((ConvertFrom-SecureToPlain (Get-NasuniVaultSecret -Vault $auth -Mount $v.Mount -SecretPath $v.AuditKeyPath -Field 'key')))
        $oidcSecret = if ($config.Auth.Mode -eq 'Oidc') { ConvertFrom-SecureToPlain (Get-NasuniVaultSecret -Vault $auth -Mount $v.Mount -SecretPath $v.OidcSecretPath -Field 'client_secret') } else { $null }
        $hostName = ([uri]$config.PublicOrigin).Host
        $cert = New-NasuniVaultPkiCertificate -Vault $auth -PkiMount $v.PkiMount -Role $v.PkiRole -CommonName $hostName -TtlHours $v.CertTtlHours
    }
    'DevEnvironment' {
        if (-not $isDev) { throw 'SecretsSource=DevEnvironment is only allowed with NASUNI_ALLOW_NON_FIPS_HOST=1 outside Production.' }
        Write-Warning 'DEVELOPMENT MODE: secrets from environment variables, not Vault. Never use this in production.'
        $u = $env:NASUNI_DEV_NMC_USER; $p = $env:NASUNI_DEV_NMC_PASSWORD
        if (-not $u -or -not $p) { throw 'Set NASUNI_DEV_NMC_USER and NASUNI_DEV_NMC_PASSWORD.' }
        $sp = [securestring]::new(); foreach ($ch in $p.ToCharArray()) { $sp.AppendChar($ch) }; $sp.MakeReadOnly()
        $credRo = [pscredential]::new($u, $sp); $credOps = $credRo
        $sessionSecret = [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        $auditKey = if ($env:NASUNI_DEV_AUDIT_KEY_B64) { [Convert]::FromBase64String($env:NASUNI_DEV_AUDIT_KEY_B64) } else { [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32) }
        $oidcSecret = $null
        $cert = $null
        if (-not $devHttp) {
            $cert = Import-NasuniCertificate -PemCertificatePath $config.Dev.CertificatePath -PemKeyPath $config.Dev.CertificateKeyPath   # .NET 8 and 9 compatible
        }
    }
    default { throw "SecretsSource must be 'Vault' or 'DevEnvironment'." }
}
if ($auditKey.Length -lt 32) { throw 'The audit HMAC key must be at least 32 bytes.' }
#endregion

$authMode = $config.Auth.Mode
if ($authMode -in @('DevHeader', 'DevLogin') -and (-not $isDev -or -not $loopback)) {
    throw "Auth.Mode=$authMode is only allowed in development mode on a loopback address."
}
if ($authMode -notin @('Oidc', 'DevHeader', 'DevLogin')) { throw "Auth.Mode must be 'Oidc' (or 'DevHeader'/'DevLogin' for local development)." }

Start-PodeServer -Threads $threads -StatusPageExceptions Hide {
    if ($devHttp) {
        Write-Warning "DEMO MODE: plain HTTP on $($config.Address). Never use this outside a local preview."
        Add-PodeEndpoint -Address $config.Address -Port $config.Port -Protocol Http
    }
    else {
        Add-PodeEndpoint -Address $config.Address -Port $config.Port -Protocol Https -X509Certificate $cert -SslProtocol Tls12, Tls13
    }
    New-PodeLoggingMethod -Terminal | Enable-PodeErrorLogging

    Import-PodeModule -Path $nmcModule
    Import-PodeModule -Path $dashModule

    # Shared, in-memory state. Never call Save-PodeState: it would write secrets to disk.
    $null = Set-PodeState -Name 'config' -Value $config
    $null = Set-PodeState -Name 'cred-ro' -Value $credRo
    $null = Set-PodeState -Name 'cred-ops' -Value $credOps
    $null = Set-PodeState -Name 'audit-key' -Value $auditKey
    $null = Set-PodeState -Name 'rate-share' -Value $perRunspaceShare
    $null = Set-PodeState -Name 'snapshot' -Value @{ At = $null; Errors = @('Data has not been loaded yet.') }
    # Report jobs: a ConcurrentDictionary shared by every runspace (routes add, the runner timer updates).
    $null = Set-PodeState -Name 'report-jobs' -Value ([System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new())
    $null = Set-PodeState -Name 'report-settings' -Value @{
        Directory      = $(if ($config.ContainsKey('ReportDirectory')) { $config.ReportDirectory } else { Join-Path -Path (Split-Path -Path $config.AuditLogPath -Parent) -ChildPath 'reports' })
        RetentionHours = $(if ($config.ContainsKey('ReportRetentionHours')) { [int]$config.ReportRetentionHours } else { 24 })
        MaxPerUser     = $(if ($config.ContainsKey('MaxReportJobsPerUser')) { [int]$config.MaxReportJobsPerUser } else { 3 })
    }

    #region Security headers, sessions, CSRF, origin check
    # DEBUG NOTES (See docs/TROUBLESHOOTING.md, "Pode"):
    #  - This server block runs in the script scope: use $config directly. $using: is invalid here.
    #  - Route, timer and middleware blocks run in separate runspaces. They cannot see script
    #    variables or functions defined in this file; use Get-PodeState and the imported modules.
    #  - Each runspace has its own Nasuni.Nmc module state, so its own NMC connection and token.
    #  - Write-PodeHtmlResponse does NOT escape strings. Every value must go through ConvertTo-DashHtml.
    Set-PodeSecurity -Type Strict -UseHsts
    Set-PodeSecurityContentSecurityPolicy -Default 'self' -Scripts 'none' -Style 'self' -Image 'self' -FormAction 'self' -FrameAncestor 'none' -BaseUri 'none' -Object 'none'
    Set-PodeSecurityStrictTransportSecurity -Duration 31536000 -IncludeSubDomains
    # DEBUG NOTE (See docs/TROUBLESHOOTING.md, "Origin: null"): Pode's Strict preset sets
    # Referrer-Policy: no-referrer, and browsers then send `Origin: null` on form POSTs.
    # The same-origin check rejected EVERY form submission in a real browser (403). The
    # same-origin policy still sends nothing to other sites.
    Set-PodeSecurityReferrerPolicy -Type Same-Origin
    Hide-PodeSecurityServer

    # TODO(roadmap#9): sessions are in memory. A restart signs users out, and only one instance is supported.
    Enable-PodeSessionMiddleware -Secret $sessionSecret -Duration 900 -Extend -HttpOnly -Secure
    # DEBUG NOTE (See docs/TROUBLESHOOTING.md): symptom without this fix is CSRF 403s from .NET/curl clients,
    # because they drop the cookie, which loses the session.
    # Pode 2.14 cannot set SameSite, and it writes a fractional Max-Age, which RFC 6265 forbids
    # (some clients then drop the cookie). Fix both before the response is sent.
    Add-PodeEndware -ScriptBlock {
        $h = $WebEvent.Response.Headers
        $vals = @($h['Set-Cookie'])
        if ($vals.Count -and $vals[0]) {
            $h.Remove('Set-Cookie')
            foreach ($val in $vals) {
                $fixed = [regex]::Replace([string]$val, '(?i)(Max-Age=)(\d+)\.\d+', '$1$2')
                if ($fixed -notmatch '(?i);\s*SameSite=') { $fixed = "$fixed; SameSite=Strict" }
                $h.Add('Set-Cookie', $fixed)
            }
        }
    }
    Enable-PodeCsrfMiddleware
    # Every response carries X-Request-Id; the same id is in the request log line, so a user
    # can quote it and an admin can find the request (and any error) in the logs.
    Add-PodeMiddleware -Name 'request-id' -ScriptBlock {
        $WebEvent.Metadata['RequestId'] = [guid]::NewGuid().ToString('N').Substring(0, 12)
        $WebEvent.Metadata['Started'] = [System.Diagnostics.Stopwatch]::StartNew()
        Set-PodeHeader -Name 'X-Request-Id' -Value $WebEvent.Metadata['RequestId']
        return $true
    }
    Add-PodeEndware -ScriptBlock {
        try {
            $code = [int]$WebEvent.Response.StatusCode
            $ms = if ($WebEvent.Metadata['Started']) { $WebEvent.Metadata['Started'].ElapsedMilliseconds } else { $null }
            $user = if ($WebEvent.Auth -and $WebEvent.Auth.User) { $WebEvent.Auth.User.Name } else { $null }
            $level = if ($code -ge 500) { 'Error' } elseif ($code -ge 400) { 'Info' } else { 'Debug' }
            Write-DashLog -Level $level -Message 'HTTP request' -Data @{ requestId = $WebEvent.Metadata['RequestId']; method = $WebEvent.Method; path = $WebEvent.Path; status = $code; ms = $ms; user = $user }
        }
        catch { $null = $_ }   # logging must never break a response
    }
    Add-PodeMiddleware -Name 'same-origin' -ScriptBlock {
        if ($WebEvent.Method -in @('post', 'put', 'patch', 'delete')) {
            $origin = Get-PodeHeader -Name 'Origin'
            $site = Get-PodeHeader -Name 'Sec-Fetch-Site'
            $expected = (Get-PodeState -Name 'config').PublicOrigin
            # 'null' is treated as no Origin; the browser's Sec-Fetch-Site header then decides.
            if ($origin -eq 'null') { $origin = $null }
            $ok = ($origin -and $origin -eq $expected) -or (-not $origin -and $site -eq 'same-origin')
            if (-not $ok) { Set-PodeResponseStatus -Code 403 -NoErrorPage; return $false }
        }
        return $true
    }
    #endregion

    #region Authentication
    # TODO(roadmap#3): OIDC is untested against a real IdP (groups claim, PKCE, logout).
    if ($authMode -eq 'Oidc') {
        $a = $config.Auth
        $scheme = New-PodeAuthScheme -OAuth2 -ClientId $a.ClientId -ClientSecret $oidcSecret -AuthoriseUrl $a.AuthoriseUrl -TokenUrl $a.TokenUrl `
            -UserUrl $a.UserUrl -Scope $a.Scopes -RedirectUrl "$($config.PublicOrigin)/login" -UsePKCE
        $scheme | Add-PodeAuth -Name 'Login' -FailureUrl '/denied' -SuccessUrl '/' -ScriptBlock {
            # DEBUG NOTE: Pode calls this with ($user, $accessToken, $refreshToken, $response).
            # Only $user is declared; the rest land in $args. PSScriptAnalyzer ignores
            # SuppressMessage attributes on anonymous script blocks, so declaring unused
            # parameters here fails the lint gate. (See docs/TROUBLESHOOTING.md, "Pode callbacks")
            param($user)
            $cfg = (Get-PodeState -Name 'config').Auth
            $groups = @(Get-DashValue -InputObject $user -Path $cfg.GroupsClaim)
            $role = Resolve-DashRole -Groups $groups -RoleMap $cfg.RoleMap
            if (-not $role) { return @{ Message = 'Your account is not in a dashboard group.' } }
            $name = [string](Get-DashValue -InputObject $user -Path $cfg.NameClaim)
            return @{ User = @{ Name = $name; Role = $role } }
        }
        Add-PodeRoute -Method Get -Path '/login' -Authentication 'Login' -Login
        Add-PodeRoute -Method Post -Path '/logout' -Authentication 'Login' -Logout
        Add-PodeRoute -Method Get -Path '/denied' -ScriptBlock {
            Write-PodeHtmlResponse -StatusCode 403 -Value (Format-DashPage -Title 'Access denied' -BodyHtml '<p>Your account is not allowed to use this dashboard.</p>')
        }
    }
    elseif ($authMode -eq 'DevLogin') {
        # Local demo only: pick a development user on a sign-in page (any password is ignored).
        $scheme = New-PodeAuthScheme -Form
        $scheme | Add-PodeAuth -Name 'Login' -FailureUrl '/login' -SuccessUrl '/' -ScriptBlock {
            param($username)
            $map = (Get-PodeState -Name 'config').Auth.DevUsers
            if ($map.ContainsKey($username)) { return @{ User = @{ Name = $username; Role = $map[$username] } } }
            return @{ Message = 'Unknown development user' }
        }
        Add-PodeRoute -Method Get -Path '/login' -Authentication 'Login' -Login -ScriptBlock {
            $map = (Get-PodeState -Name 'config').Auth.DevUsers
            $options = ($map.Keys | Sort-Object | ForEach-Object { "<option value=""$(ConvertTo-DashHtml $_)"">$(ConvertTo-DashHtml $_) ($(ConvertTo-DashHtml $map[$_]))</option>" }) -join ''
            $body = "<p class=""note"">Local demo sign-in. Production uses your identity provider (OIDC).</p><form method=""post"" action=""/login""><input type=""hidden"" name=""pode.csrf"" value=""$(ConvertTo-DashHtml (New-PodeCsrfToken))""><p><label>User <select name=""username"">$options</select></label></p><input type=""hidden"" name=""password"" value=""demo""><button type=""submit"">Sign in</button></form>"
            Write-PodeHtmlResponse -Value (Format-DashPage -Title 'Sign in' -BodyHtml $body)
        }
        Add-PodeRoute -Method Post -Path '/login' -Authentication 'Login' -Login
        Add-PodeRoute -Method Post -Path '/logout' -Authentication 'Login' -Logout
    }
    else {
        # DEBUG NOTE: a custom scheme must return @{ Message; Code = 401 } on failure.
        # Returning $null makes Pode answer 500 instead of 401. (See docs/TROUBLESHOOTING.md)
        $scheme = New-PodeAuthScheme -Custom -ScriptBlock {
            $u = Get-PodeHeader -Name 'X-Dev-User'
            if ($u) { return @($u) }
            return @{ Message = 'Authentication required'; Code = 401 }
        }
        $scheme | Add-PodeAuth -Name 'Login' -Sessionless -ScriptBlock {
            param($u)
            $map = (Get-PodeState -Name 'config').Auth.DevUsers
            if ($map.ContainsKey($u)) { return @{ User = @{ Name = $u; Role = $map[$u] } } }
            return @{ Message = 'Unknown development user' }
        }
        Add-PodeRoute -Method Post -Path '/logout' -Authentication 'Login' -ScriptBlock { Move-PodeResponseUrl -Url '/' }
    }
    #endregion

    #region Data refresh (read-only account, timer runspace only)
    # DEBUG NOTE (See docs/TROUBLESHOOTING.md): symptom of refreshing inline was change requests stalling for about
    # 30 s, waiting on the per-runspace login rate limit after switching accounts.
    # Routes never refresh inline: that would switch their runspace's NMC connection between
    # accounts and burn the login rate limit. They set 'refresh-requested', and this timer
    # (which checks every 5 s) does the work with the read-only account.
    $null = Set-PodeState -Name 'refresh-requested' -Value $false
    Add-PodeTimer -Name 'refresh' -Interval 5 -OnStart -ScriptBlock {
        $cfg = Get-PodeState -Name 'config'
        $every = if ($cfg.ContainsKey('RefreshSeconds')) { [int]$cfg.RefreshSeconds } else { 60 }
        $current = Get-PodeState -Name 'snapshot'
        $due = -not $current.ContainsKey('Taken') -or ([datetime]::UtcNow - $current.Taken).TotalSeconds -ge $every
        if (-not $due -and -not (Get-PodeState -Name 'refresh-requested')) { return }
        $null = Set-PodeState -Name 'refresh-requested' -Value $false
        try {
            Connect-DashNmc -Nmc $cfg.Nmc -Credential (Get-PodeState -Name 'cred-ro') -ReadOnly -RateShare (Get-PodeState -Name 'rate-share')
            $snap = Get-DashSnapshot
        }
        catch {
            $old = Get-PodeState -Name 'snapshot'
            $snap = @{} + $old
            $snap.Errors = @("Refresh failed: $(Protect-NasuniSensitiveData -InputObject $_.Exception.Message)") + @($old.Errors)
        }
        $snap.Taken = [datetime]::UtcNow
        # Replacing the whole value is a single reference swap; readers see the old or the new snapshot.
        $null = Set-PodeState -Name 'snapshot' -Value $snap
    }
    #endregion

    # Report runner: one job at a time, read-only account, own runspace (see Pages.ps1 notes).
    Add-PodeTimer -Name 'report-runner' -Interval 3 -ScriptBlock {
        $jobs = Get-PodeState -Name 'report-jobs'
        $settings = Get-PodeState -Name 'report-settings'
        try { Remove-DashExpiredReportJob -Jobs $jobs -RetentionHours $settings.RetentionHours -Confirm:$false } catch { Write-DashLog -Level Warning -Message 'Report cleanup failed' -Data @{ error = $_.Exception.Message } }
        $next = @($jobs.Values | Where-Object { $_.Status -eq 'queued' } | Sort-Object { $_.CreatedUtc } | Select-Object -First 1)
        if ($next.Count -eq 0) { return }
        $cfg = Get-PodeState -Name 'config'
        Invoke-DashReportJob -Job $next[0] -Directory $settings.Directory -Nmc $cfg.Nmc -Credential (Get-PodeState -Name 'cred-ro') -RateShare (Get-PodeState -Name 'rate-share')
    }

    Add-PodeStaticRoute -Path '/static' -Source (Join-Path -Path $root -ChildPath 'public')

    #region Pages
    Add-PodeRoute -Method Get -Path '/' -Authentication 'Login' -ScriptBlock {
        $u = $WebEvent.Auth.User
        if (-not (Test-DashPermission -Role $u.Role -Permission Read)) { Set-PodeResponseStatus -Code 403 -NoErrorPage; return }
        $snap = Get-PodeState -Name 'snapshot'
        $csrf = New-PodeCsrfToken
        Write-PodeHtmlResponse -Value (Format-DashPage -Title 'Overview' -BodyHtml (Format-DashOverviewBody -Snapshot $snap -Role $u.Role -CsrfToken $csrf) -UserName $u.Name -Role $u.Role -CsrfToken $csrf -SnapshotAt $snap.At)
    }

    foreach ($section in @('filers', 'volumes', 'shares', 'antivirus', 'notifications', 'connections', 'credentials', 'health')) {
        Add-PodeRoute -Method Get -Path "/$section" -Authentication 'Login' -ArgumentList $section -ScriptBlock {
            param($name)
            $u = $WebEvent.Auth.User
            if (-not (Test-DashPermission -Role $u.Role -Permission Read)) { Set-PodeResponseStatus -Code 403 -NoErrorPage; return }
            $snap = Get-PodeState -Name 'snapshot'
            $title = (Get-DashSectionDefinition)[$name].Title
            Write-PodeHtmlResponse -Value (Format-DashPage -Title $title -BodyHtml (Format-DashSectionBody -Name $name -Snapshot $snap -Role $u.Role) -UserName $u.Name -Role $u.Role -CsrfToken (New-PodeCsrfToken) -SnapshotAt $snap.At)
        }
    }

    Add-PodeRoute -Method Get -Path '/reports' -Authentication 'Login' -ScriptBlock {
        $u = $WebEvent.Auth.User
        if (-not (Test-DashPermission -Role $u.Role -Permission Read)) { Set-PodeResponseStatus -Code 403 -NoErrorPage; return }
        $jobs = @((Get-PodeState -Name 'report-jobs').Values)
        $msg = if ($WebEvent.Query['queued']) { 'Report queued. Reload this page to see when it is ready.' } else { $null }
        $csrf = New-PodeCsrfToken
        Write-PodeHtmlResponse -Value (Format-DashPage -Title 'Reports' -BodyHtml (Format-DashReportsBody -CsrfToken $csrf -User $u.Name -Role $u.Role -Jobs $jobs -Message $msg) -UserName $u.Name -Role $u.Role -CsrfToken $csrf)
    }

    Add-PodeRoute -Method Post -Path '/reports/run' -Authentication 'Login' -ScriptBlock {
        $u = $WebEvent.Auth.User
        if (-not (Test-DashPermission -Role $u.Role -Permission Read)) { Set-PodeResponseStatus -Code 403 -NoErrorPage; return }
        $jobs = Get-PodeState -Name 'report-jobs'
        $settings = Get-PodeState -Name 'report-settings'
        $name = [string]$WebEvent.Data['report']
        try {
            $params = ConvertTo-DashReportParameter -Name $name -Data $WebEvent.Data
            $active = @($jobs.Values | Where-Object { $_.User -eq $u.Name -and $_.Status -in @('queued', 'running') }).Count
            if ($active -ge $settings.MaxPerUser) { throw "You already have $active report(s) queued or running. Wait for them to finish." }
        }
        catch {
            Write-PodeHtmlResponse -StatusCode 400 -Value (Format-DashPage -Title 'Report not queued' -BodyHtml "<p class=""bad"">$(ConvertTo-DashHtml $_.Exception.Message)</p><p><a href=""/reports"">Back to reports</a></p>" -UserName $u.Name -Role $u.Role)
            return
        }
        $job = New-DashReportJob -Name $name -Parameters $params -User $u.Name
        $null = $jobs.TryAdd($job.Id, $job)
        $cfg = Get-PodeState -Name 'config'
        Write-DashAudit -Path $cfg.AuditLogPath -Key (Get-PodeState -Name 'audit-key') -Entry ([ordered]@{ user = $u.Name; role = $u.Role; action = 'report-run'; target = $name; params = $params; result = 'queued'; job = $job.Id })
        Move-PodeResponseUrl -Url '/reports?queued=1'
    }

    Add-PodeRoute -Method Get -Path '/reports/jobs/:id' -Authentication 'Login' -ScriptBlock {
        $u = $WebEvent.Auth.User
        $id = [string]$WebEvent.Parameters['id']
        $job = $null
        if ($id -notmatch '^[0-9a-f]{32}$' -or -not (Get-PodeState -Name 'report-jobs').TryGetValue($id, [ref]$job)) { Set-PodeResponseStatus -Code 404 -NoErrorPage; return }
        # Someone else's job is reported as 404, not 403, so job ids cannot be probed.
        if (-not (Test-DashJobAccess -Job $job -User $u.Name -Role $u.Role)) { Set-PodeResponseStatus -Code 404 -NoErrorPage; return }
        if ($job.Status -ne 'done' -or -not (Test-Path -LiteralPath $job.File)) { Set-PodeResponseStatus -Code 404 -NoErrorPage; return }
        $fileName = 'nasuni-{0}-{1}.csv' -f $job.Name, $job.FinishedUtc.ToString('yyyyMMdd-HHmm')
        Set-PodeHeader -Name 'Content-Disposition' -Value ('attachment; filename="{0}"' -f $fileName)
        Write-PodeTextResponse -Value ([System.IO.File]::ReadAllText($job.File)) -ContentType 'text/csv; charset=utf-8'
    }

    Add-PodeRoute -Method Get -Path '/reports/:name' -Authentication 'Login' -ScriptBlock {
        $u = $WebEvent.Auth.User
        if (-not (Test-DashPermission -Role $u.Role -Permission Read)) { Set-PodeResponseStatus -Code 403 -NoErrorPage; return }
        $file = [string]$WebEvent.Parameters['name']
        $name = $file -replace '\.csv$', ''
        $sections = Get-DashSectionDefinition
        if ($file -notmatch '^[a-z]+\.csv$' -or -not $sections.Contains($name)) { Set-PodeResponseStatus -Code 404 -NoErrorPage; return }
        $snap = Get-PodeState -Name 'snapshot'
        $rows = @($snap[$sections[$name].Key])
        $cols = Get-DashSectionColumn -Section $sections[$name] -Rows $rows -ForCsv
        $csv = (@(ConvertTo-DashCsvRow -Rows $rows -Columns $cols) | ConvertTo-Csv -NoTypeInformation -UseQuotes Always) -join "`r`n"
        Set-PodeHeader -Name 'Content-Disposition' -Value "attachment; filename=""nasuni-$name-$([datetime]::UtcNow.ToString('yyyyMMdd-HHmm')).csv"""
        Write-PodeTextResponse -Value $csv -ContentType 'text/csv; charset=utf-8'
    }

    Add-PodeRoute -Method Post -Path '/refresh' -Authentication 'Login' -ScriptBlock {
        $u = $WebEvent.Auth.User
        if (-not (Test-DashPermission -Role $u.Role -Permission Refresh)) { Set-PodeResponseStatus -Code 403 -NoErrorPage; return }
        $null = Set-PodeState -Name 'refresh-requested' -Value $true
        Move-PodeResponseUrl -Url '/'
    }

    Add-PodeRoute -Method Get -Path '/audit' -Authentication 'Login' -ScriptBlock {
        $u = $WebEvent.Auth.User
        if (-not (Test-DashPermission -Role $u.Role -Permission Audit)) { Set-PodeResponseStatus -Code 403 -NoErrorPage; return }
        $cfg = Get-PodeState -Name 'config'
        $key = Get-PodeState -Name 'audit-key'
        $chain = Test-DashAuditChain -Path $cfg.AuditLogPath -Key $key
        $entries = Read-DashAudit -Path $cfg.AuditLogPath -Last 200
        Write-PodeHtmlResponse -Value (Format-DashPage -Title 'Audit log' -BodyHtml (Format-DashAuditBody -Chain $chain -Entries $entries) -UserName $u.Name -Role $u.Role -CsrfToken (New-PodeCsrfToken))
    }
    #endregion

    #region Changes: form -> preview -> typed confirmation -> execute -> verify -> audit
    Add-PodeRoute -Method Get -Path '/actions/:action' -Authentication 'Login' -ScriptBlock {
        $u = $WebEvent.Auth.User
        $action = [string]$WebEvent.Parameters['action']
        try {
            $def = Get-DashActionDefinition -Name $action
            if (-not (Test-DashPermission -Role $u.Role -Permission $def.Permission)) { Set-PodeResponseStatus -Code 403 -NoErrorPage; return }
            $params = Get-DashActionParameter -Action $action -Data $WebEvent.Query
        }
        catch { Write-PodeHtmlResponse -StatusCode 400 -Value (Format-DashPage -Title 'Invalid request' -BodyHtml "<p>$(ConvertTo-DashHtml $_.Exception.Message)</p>" -UserName $u.Name -Role $u.Role); return }
        $csrf = New-PodeCsrfToken
        Write-PodeHtmlResponse -Value (Format-DashPage -Title $def.Title -BodyHtml (Format-DashActionFormBody -Action $action -Params $params -CsrfToken $csrf) -UserName $u.Name -Role $u.Role -CsrfToken $csrf)
    }

    Add-PodeRoute -Method Post -Path '/actions/:action/preview' -Authentication 'Login' -ScriptBlock {
        $u = $WebEvent.Auth.User
        $action = [string]$WebEvent.Parameters['action']
        try {
            $def = Get-DashActionDefinition -Name $action
            if (-not (Test-DashPermission -Role $u.Role -Permission $def.Permission)) { Set-PodeResponseStatus -Code 403 -NoErrorPage; return }
            $params = Get-DashActionParameter -Action $action -Data $WebEvent.Data
            $cfg = Get-PodeState -Name 'config'
            Connect-DashNmc -Nmc $cfg.Nmc -Credential (Get-PodeState -Name 'cred-ops') -RateShare (Get-PodeState -Name 'rate-share')
            $pending = New-DashActionPreview -Action $action -Params $params -User $u.Name -Role $u.Role
        }
        catch { Write-PodeHtmlResponse -StatusCode 400 -Value (Format-DashPage -Title 'Preview failed' -BodyHtml "<p>$(ConvertTo-DashHtml (Protect-NasuniSensitiveData -InputObject $_.Exception.Message))</p>" -UserName $u.Name -Role $u.Role); return }
        $WebEvent.Session.Data.Pending = $pending
        $csrf = New-PodeCsrfToken
        Write-PodeHtmlResponse -Value (Format-DashPage -Title "Confirm: $($pending.Title)" -BodyHtml (Format-DashPreviewBody -Pending $pending -CsrfToken $csrf) -UserName $u.Name -Role $u.Role -CsrfToken $csrf)
    }

    Add-PodeRoute -Method Post -Path '/actions/execute' -Authentication 'Login' -ScriptBlock {
        $u = $WebEvent.Auth.User
        $pending = $null
        if ($WebEvent.Session.Data.ContainsKey('Pending')) { $pending = $WebEvent.Session.Data.Pending }
        $null = $WebEvent.Session.Data.Remove('Pending')   # single use, whatever happens next
        $cfg = Get-PodeState -Name 'config'
        try {
            Connect-DashNmc -Nmc $cfg.Nmc -Credential (Get-PodeState -Name 'cred-ops') -RateShare (Get-PodeState -Name 'rate-share')
            $result = Invoke-DashAction -Pending $pending -PendingId ([string]$WebEvent.Data['pending_id']) -TypedPhrase ([string]$WebEvent.Data['confirm']) `
                -User $u.Name -Role $u.Role -AuditPath $cfg.AuditLogPath -AuditKey (Get-PodeState -Name 'audit-key') -Confirm:$false
        }
        catch {
            $code = if ($_.Exception -is [System.UnauthorizedAccessException]) { 403 } else { 400 }
            # Refused confirmations (wrong phrase, replay, expiry, wrong user or role) are audited too.
            $refusal = [ordered]@{ user = $u.Name; role = $u.Role; result = 'refused'; error = $_.Exception.Message }
            if ($pending) { $refusal.action = $pending.Action; $refusal.target = $pending.Target }
            Write-DashAudit -Path $cfg.AuditLogPath -Key (Get-PodeState -Name 'audit-key') -Entry $refusal
            Write-PodeHtmlResponse -StatusCode $code -Value (Format-DashPage -Title 'Change not applied' -BodyHtml "<p class=""bad"">$(ConvertTo-DashHtml $_.Exception.Message)</p><p>Nothing was changed.</p>" -UserName $u.Name -Role $u.Role)
            return
        }
        $null = Set-PodeState -Name 'refresh-requested' -Value $true
        $cls = if ($result.Verified) { 'ok' } else { 'bad' }
        Write-PodeHtmlResponse -StatusCode $(if ($result.Success) { 200 } else { 502 }) -Value (Format-DashPage -Title 'Change result' -BodyHtml "<p class=""$cls"">$(ConvertTo-DashHtml $result.Message)</p><p><a href=""/"">Back to overview</a></p>" -UserName $u.Name -Role $u.Role)
    }
    #endregion

    # TODO(roadmap#4): renewal by restart is untested against live Vault PKI.
    #region Certificate renewal (Vault mode)
    if ($config.SecretsSource -eq 'Vault') {
        $renewDays = if ($config.Vault.ContainsKey('RenewBeforeDays')) { [int]$config.Vault.RenewBeforeDays } else { 7 }
        $null = Set-PodeState -Name 'cert-not-after' -Value $cert.NotAfter.ToUniversalTime()
        Add-PodeTimer -Name 'cert-renewal' -Interval 3600 -ArgumentList $renewDays -ScriptBlock {
            param($days)
            if ((Get-PodeState -Name 'cert-not-after') -lt [datetime]::UtcNow.AddDays($days)) { Restart-PodeServer }
        }
    }
    #endregion
}

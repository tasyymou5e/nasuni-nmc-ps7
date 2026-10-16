# FILE: Private/Request.ps1. Layer 2: the single request pipeline.
#   Invoke-NmcRequest   rate limit -> auth -> send -> classify -> retry / re-login / circuit breaker
#   Request-NmcToken    login (never gated by ShouldProcess, so -WhatIf cannot block it)
#   Get-NmcPagedItem    offset paging with a duplicate-page guard
#   New-NasuniApiError  every failure becomes a NasuniApiException with a correlation id, and is
#                       counted and logged in one place (see Get-NasuniDiagnostic)
# Retry policy: GET is retried on network errors and 5xx; writes only on 429 (never duplicated).

function New-NasuniApiError {
    # Builds a NasuniApiException with a redacted, truncated body.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an exception object only')]
    [CmdletBinding()]
    [OutputType([NasuniApiException])]
    param([string]$Message, [int]$StatusCode, [string]$Method, [string]$Endpoint, [string]$CorrelationId, [string]$Body)
    $safeBody = Protect-NmcText -Text $Body
    if ($safeBody -and $safeBody.Length -gt 1000) { $safeBody = $safeBody.Substring(0, 1000) + '...' }
    $text = '{0} ({1} {2} -> HTTP {3}, correlation {4})' -f (Protect-NmcText -Text $Message), $Method, $Endpoint, $StatusCode, $CorrelationId
    if ($safeBody) { $text += ": $safeBody" }
    # Single place where every API failure is counted and logged, so Get-NasuniDiagnostic and
    # the log file always hold the correlation id a user sees in an error message.
    $script:NmcState.Stats.Failures++
    $script:NmcState.Stats.LastErrorUtc = [datetime]::UtcNow.ToString('o')
    $script:NmcState.Stats.LastCorrelationId = $CorrelationId
    Write-NmcLog -Level Warning -Message 'NMC API error' -Data @{ method = $Method; path = $Endpoint; status = $StatusCode; correlationId = $CorrelationId; error = (Protect-NmcText -Text $Message) }
    [NasuniApiException]::new($text, $StatusCode, $Method, $Endpoint, $CorrelationId, $safeBody)
}

function Assert-NmcConnected {
    [CmdletBinding()]
    param()
    if (-not $script:NmcState.BaseUri -or -not $script:NmcState.HttpClient) {
        throw 'Not connected. Run Connect-Nasuni first.'
    }
}

function Request-NmcToken {
    <#
    .SYNOPSIS
        Logs in with the stored credential and keeps the token in memory.
    .NOTES
        This step is never subject to ShouldProcess, so -WhatIf on a cmdlet no longer
        suppresses the login (that was a bug in the original module).
    #>
    [CmdletBinding()]
    param()

    Assert-NmcConnected
    if (-not $script:NmcState.Credential) { throw 'No credential available. Run Connect-Nasuni again.' }

    $cred = $script:NmcState.Credential
    $plain = [System.Net.NetworkCredential]::new('', $cred.Password).Password
    try {
        $body = @{ username = $cred.UserName; password = $plain } | ConvertTo-Json -Compress
    }
    finally { $plain = $null }

    $response = Invoke-NmcRequest -Method POST -Path '/auth/login/' -BodyJson $body -NoAuth
    $body = $null
    if (-not $response -or -not (($null -ne $response.PSObject.Properties['token'])) -or [string]::IsNullOrWhiteSpace($response.token)) {
        throw 'NMC login succeeded but no token was returned.'
    }

    $script:NmcState.Token = [string]$response.token
    Register-NmcRedaction -Value $script:NmcState.Token
    $expires = [datetimeoffset]::MinValue
    if (($null -ne $response.PSObject.Properties['expires']) -and
        [datetimeoffset]::TryParse([string]$response.expires, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expires)) {
        $script:NmcState.TokenExpiresUtc = $expires.UtcDateTime
    }
    else {
        # No usable expiry, so assume a short lifetime and refresh early.
        $script:NmcState.TokenExpiresUtc = [datetime]::UtcNow.AddMinutes(30)
    }
    Write-NmcLog -Level Info -Message 'NMC token acquired' -Data @{ host = $script:NmcState.Host; expiresUtc = $script:NmcState.TokenExpiresUtc.ToString('o') }
}

function Invoke-NmcRequest {
    <#
    .SYNOPSIS
        The single request pipeline: rate limit, auth, retry, circuit breaker, errors.
    .DESCRIPTION
        - GET requests are retried on network errors and 5xx (up to MaxAttempts).
        - Writes are retried only on 429. The server did not process those, so a retry
          can't duplicate a POST.
        - 401 triggers one re-login and retry.
        - ReadOnly connections reject every non-GET except the internal login and logout.
        - After 5 consecutive failures the circuit opens for 30 seconds and calls fail fast.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query,
        [string]$BodyJson,
        [switch]$NoAuth,
        [ValidateRange(1, 10)][int]$MaxAttempts = 5,
        [switch]$IncludeStatus
    )

    Assert-NmcConnected
    Assert-NmcPath -Path $Path

    # Login and logout change no NMC data, so they are allowed on read-only connections
    # (otherwise read-only sessions could never revoke their token on Disconnect-Nasuni).
    $isLogin = $NoAuth -and $Method -eq 'POST' -and $Path -eq '/auth/login/'
    $isLogout = -not $NoAuth -and $Method -eq 'POST' -and $Path -eq '/auth/logout/'
    if ($script:NmcState.ReadOnly -and $Method -ne 'GET' -and -not $isLogin -and -not $isLogout) {
        throw "Connection is read-only; $Method $Path was refused."
    }
    if ([datetime]::UtcNow -lt $script:NmcState.CircuitOpenUntilUtc) {
        throw "NMC circuit breaker is open until $($script:NmcState.CircuitOpenUntilUtc.ToString('o')) after repeated failures."
    }

    $uri = [uri]($script:NmcState.BaseUri + $Path + (ConvertTo-NmcQueryString -Query $Query))
    $class = Get-NmcRateClass -Method $Method -Path $Path
    $reauthed = $false

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (-not $NoAuth -and (-not $script:NmcState.Token -or [datetime]::UtcNow.AddMinutes(5) -ge $script:NmcState.TokenExpiresUtc)) {
            Request-NmcToken
        }
        Wait-NmcRateLimit -Class $class

        $correlationId = [guid]::NewGuid().ToString()
        $headers = @{ Accept = 'application/json'; 'X-Correlation-Id' = $correlationId }
        if (-not $NoAuth) { $headers.Authorization = "Token $($script:NmcState.Token)" }

        $httpArgs = @{ Client = $script:NmcState.HttpClient; Method = $Method; Uri = $uri; Headers = $headers }
        if ($PSBoundParameters.ContainsKey('BodyJson')) { $httpArgs.BodyJson = $BodyJson }

        $script:NmcState.Stats.Requests++
        if ($attempt -gt 1) { $script:NmcState.Stats.Retries++ }
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $resp = Invoke-NmcHttp @httpArgs
        }
        catch {
            $script:NmcState.ConsecutiveFailures++
            if ($script:NmcState.ConsecutiveFailures -ge 5) { $script:NmcState.CircuitOpenUntilUtc = [datetime]::UtcNow.AddSeconds(30) }
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            Write-NmcLog -Level Warning -Message 'NMC request failed at transport level' -Data @{ method = $Method; path = $Path; attempt = $attempt; error = $inner.Message; correlationId = $correlationId }
            if ($inner -is [System.Security.Authentication.AuthenticationException]) {
                throw (New-NasuniApiError -Message "TLS validation failed: $($inner.Message)" -StatusCode 0 -Method $Method -Endpoint $Path -CorrelationId $correlationId)
            }
            if ($Method -eq 'GET' -and $attempt -lt $MaxAttempts) {
                Start-Sleep -Milliseconds ([int]((Get-NmcRetryDelay -Attempt $attempt) * 1000))
                continue
            }
            throw (New-NasuniApiError -Message "Transport error: $($inner.Message)" -StatusCode 0 -Method $Method -Endpoint $Path -CorrelationId $correlationId)
        }

        $status = $resp.StatusCode
        # Debug trace for every request: enable with Set-NasuniLogging -Level Debug or NASUNI_LOG_LEVEL=Debug.
        Write-NmcLog -Level Debug -Message 'NMC request' -Data @{ method = $Method; path = $Path; query = ($Query | ConvertTo-Json -Compress); status = $status; ms = $timer.ElapsedMilliseconds; attempt = $attempt; correlationId = $correlationId }
        if ($status -eq 429) { $script:NmcState.Stats.Throttled++ }
        if ($status -ge 200 -and $status -lt 400) {
            $script:NmcState.ConsecutiveFailures = 0
            $data = $null
            if (-not [string]::IsNullOrWhiteSpace($resp.Body)) {
                try { $data = $resp.Body | ConvertFrom-Json -Depth 64 }
                catch {
                    # Redirects are never followed, so a 3xx body is not the API payload (often an
                    # HTML stub); the caller acts on StatusCode and Location instead (Wait-NasuniMessage).
                    if ($status -lt 300) { throw (New-NasuniApiError -Message 'Response was not valid JSON' -StatusCode $status -Method $Method -Endpoint $Path -CorrelationId $correlationId -Body $resp.Body) }
                    $data = $null
                }
            }
            if ($IncludeStatus) {
                $location = if (($null -ne $resp.PSObject.Properties['Location'])) { $resp.Location } else { $null }
                return [pscustomobject]@{ StatusCode = $status; Data = $data; Location = $location }
            }
            return $data
        }

        if ($status -eq 401 -and -not $NoAuth -and -not $reauthed) {
            $reauthed = $true
            $script:NmcState.Token = $null
            Write-NmcLog -Level Info -Message 'NMC returned 401; re-authenticating once' -Data @{ path = $Path; correlationId = $correlationId }
            continue
        }

        if ($status -eq 429 -and $attempt -lt $MaxAttempts) {
            $delay = Get-NmcRetryDelay -StatusCode 429 -Body $resp.Body -RetryAfter $resp.RetryAfter -Attempt $attempt
            Write-NmcLog -Level Warning -Message 'NMC throttled request (429)' -Data @{ path = $Path; waitSeconds = $delay; attempt = $attempt }
            Start-Sleep -Milliseconds ([int]($delay * 1000))
            continue
        }

        if ($status -ge 500) {
            $script:NmcState.ConsecutiveFailures++
            if ($script:NmcState.ConsecutiveFailures -ge 5) { $script:NmcState.CircuitOpenUntilUtc = [datetime]::UtcNow.AddSeconds(30) }
            if ($Method -eq 'GET' -and $attempt -lt $MaxAttempts) {
                Start-Sleep -Milliseconds ([int]((Get-NmcRetryDelay -StatusCode $status -Attempt $attempt) * 1000))
                continue
            }
        }

        throw (New-NasuniApiError -Message 'NMC API request failed' -StatusCode $status -Method $Method -Endpoint $Path -CorrelationId $correlationId -Body $resp.Body)
    }
    throw (New-NasuniApiError -Message "Gave up after $MaxAttempts attempts" -StatusCode 0 -Method $Method -Endpoint $Path -CorrelationId '')
}

function Get-NmcPagedItem {
    <#
    .SYNOPSIS
        Streams every item from a paged NMC list endpoint.
    .DESCRIPTION
        NMC v1.2 lists return { Paging = { total, next, offset, limit }, items = [...] }.
        Pages are walked by offset until a page comes back empty, offset reaches total,
        or Paging.next is null. A page with no new items (detected by a SHA-256 of each
        item) stops the loop, so a misbehaving server can't make it loop forever.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query = @{},
        [ValidateRange(1, 1000)][int]$PageSize = 200,
        [ValidateRange(0, [int]::MaxValue)][int]$MaxItems = 0
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $offset = 0
    $emitted = 0
    $pages = 0

    while ($true) {
        $q = @{} + $Query
        $q.limit = $PageSize
        $q.offset = $offset
        $page = Invoke-NmcRequest -Method GET -Path $Path -Query $q
        $pages++

        # DEBUG NOTE (See docs/TROUBLESHOOTING.md, "Strict mode"): use .PSObject.Properties['name'] to test for a property.
        # Under Set-StrictMode Latest, .PSObject.Properties.Name throws on an empty object ({}).
        if ($null -eq $page -or -not (($null -ne $page.PSObject.Properties['items']))) {
            if ($null -ne $page) { $page }
            return
        }
        $items = @($page.items)
        if ($items.Count -eq 0) { return }

        $new = 0
        foreach ($item in $items) {
            $json = $item | ConvertTo-Json -Compress -Depth 32
            $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($json)))
            if ($seen.Add($hash)) {
                $item
                $new++
                $emitted++
                if ($MaxItems -gt 0 -and $emitted -ge $MaxItems) { return }
            }
        }
        if ($new -eq 0) {
            Write-NmcLog -Level Warning -Message 'Paging returned only duplicate items; stopping' -Data @{ path = $Path; offset = $offset }
            return
        }

        $offset += $items.Count
        Write-NmcLog -Level Debug -Message 'Paging progress' -Data @{ path = $Path; fetched = $emitted; offset = $offset }
        $paging = if (($null -ne $page.PSObject.Properties['Paging'])) { $page.Paging } else { $page }
        $total = if ($paging -and ($null -ne $paging.PSObject.Properties['total'])) { $paging.total } else { $null }
        $hasNextProp = $paging -and ($null -ne $paging.PSObject.Properties['next'])
        if ($null -ne $total -and $offset -ge [long]$total) { return }
        if ($null -eq $total -and $hasNextProp -and $null -eq $paging.next) { return }
        if ($pages -ge 100000) { throw "Paging safety limit reached for $Path." }
    }
}

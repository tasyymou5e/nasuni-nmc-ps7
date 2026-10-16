# FILE: Private/RateLimit.ps1. Token buckets for the documented NMC limits (auth 10/min,
# writes 1/s, reads 5/s), scaled by RateShare, plus the retry-delay policy for 429 and 5xx.

function Get-NmcRateClass {
    # Maps a request to the NMC documented rate-limit class.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path)
    if ($Path -like '/auth/*') { return 'Auth' }
    if ($Method -eq 'GET') { return 'Read' }
    'Write'
}

# TODO(roadmap#11): RateShare is a static per-process split; a shared limiter would use the NMC budget better.
function Wait-NmcRateLimit {
    <#
    .SYNOPSIS
        Token-bucket limiter for the documented NMC limits.
    .DESCRIPTION
        NMC v1.2 limits: auth 10/min, POST/PUT/PATCH/DELETE 1/s, other requests 5/s.
        RateShare (0..1] lets several processes (MCP server, dashboard) split the budget.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Auth', 'Read', 'Write')][string]$Class)

    $limits = @{
        Auth  = @{ Capacity = 10.0; PerSecond = 10.0 / 60.0 }
        Read  = @{ Capacity = 5.0; PerSecond = 5.0 }
        Write = @{ Capacity = 1.0; PerSecond = 1.0 }
    }
    $share = [math]::Max(0.05, [math]::Min(1.0, [double]$script:NmcState.RateShare))
    $rate = $limits[$Class].PerSecond * $share
    $capacity = [math]::Max(1.0, [math]::Floor($limits[$Class].Capacity * $share))

    if (-not $script:NmcState.Buckets.ContainsKey($Class)) {
        $script:NmcState.Buckets[$Class] = @{ Tokens = $capacity; Stamp = [System.Diagnostics.Stopwatch]::StartNew() }
    }
    $bucket = $script:NmcState.Buckets[$Class]

    while ($true) {
        $elapsed = $bucket.Stamp.Elapsed.TotalSeconds
        $bucket.Stamp.Restart()
        $bucket.Tokens = [math]::Min($capacity, $bucket.Tokens + ($elapsed * $rate))
        if ($bucket.Tokens -ge 1.0) {
            $bucket.Tokens -= 1.0
            return
        }
        $waitMs = [int][math]::Ceiling(((1.0 - $bucket.Tokens) / $rate) * 1000)
        Start-Sleep -Milliseconds ([math]::Max(10, $waitMs))
    }
}

function Get-NmcRetryDelay {
    <#
    .SYNOPSIS
        Works out how long to wait before retrying.
    .DESCRIPTION
        For 429: the NMC body hint "Expected available in N seconds", then Retry-After,
        then 30 s (same order as the original NasuniPoshApi), plus a 1 s margin.
        Otherwise: exponential backoff 2^attempt with up to 1 s jitter, capped at 30 s.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [int]$StatusCode,
        [string]$Body,
        [string]$RetryAfter,
        [Parameter(Mandatory)][int]$Attempt
    )

    if ($StatusCode -eq 429) {
        if ($Body -match 'Expected available in (\d+(?:\.\d+)?)\s*seconds') {
            return [double]([math]::Ceiling([double]$Matches[1]) + 1)
        }
        $parsed = 0.0
        if ($RetryAfter -and [double]::TryParse($RetryAfter, [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            return [double]([math]::Ceiling($parsed) + 1)
        }
        return [double]30
    }
    $jitter = [System.Random]::Shared.NextDouble()
    [math]::Min(30.0, [math]::Pow(2, $Attempt) + $jitter)
}

#Requires -Version 7.4
# MODULE: Nasuni.Nmc. PowerShell 7 client for the Nasuni Management Console API v1.2.
# Layout:  Private/  transport (Http), pipeline (Request), RateLimit, Logging, endpoint dispatch,
#                    report plumbing
#          Public/   Connect/Disconnect, Vault, TLS/FIPS checks, Invoke-NasuniRequest, Wait-NasuniMessage,
#                    redaction, reports, bulk engine + plan builders, diagnostics, and
#                    Endpoints.Generated.ps1 (118 cmdlets built from Data/Endpoints.psd1)
# State:   $script:NmcState (connection, token, buckets, circuit breaker, log settings, stats).
#          It is per runspace: each Pode runspace or job has its own connection.
# Docs:    docs/ARCHITECTURE.md, docs/TROUBLESHOOTING.md, docs/MIGRATION.md, docs/ROADMAP.md
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Raised for every non-success NMC/Vault response so callers can branch on
# StatusCode without parsing message text (the PS7 text-matching bug in the
# original module's async polling is why this exists).
class NasuniApiException : System.Exception {
    [int]    $StatusCode
    [string] $Method
    [string] $Endpoint
    [string] $CorrelationId
    [string] $ResponseBody

    NasuniApiException([string]$message, [int]$statusCode, [string]$method,
        [string]$endpoint, [string]$correlationId, [string]$responseBody) : base($message) {
        $this.StatusCode = $statusCode
        $this.Method = $method
        $this.Endpoint = $endpoint
        $this.CorrelationId = $correlationId
        $this.ResponseBody = $responseBody
    }
}

# Module state. Secrets live only here, in memory; nothing is persisted.
$script:NmcState = [ordered]@{
    BaseUri            = $null      # https://<host>/api/v1.2
    Host               = $null
    Credential         = $null      # PSCredential, kept for one 401 re-login
    Token              = $null
    TokenExpiresUtc    = [datetime]::MinValue
    ReadOnly           = $false
    HttpClient         = $null
    TrustedCaPath      = $null
    PinnedSpkiSha256   = $null
    RateShare          = 1.0        # fraction of the NMC rate limit this process may use
    Buckets            = @{}
    ConsecutiveFailures = 0
    CircuitOpenUntilUtc = [datetime]::MinValue
    # Logging: level from NASUNI_LOG_LEVEL (Debug|Info|Warning|Error), optional JSON-lines file from
    # NASUNI_LOG_FILE, and a ring of recent entries for Get-NasuniDiagnostic.
    LogLevel           = $(if ($env:NASUNI_LOG_LEVEL -in @('Debug', 'Info', 'Warning', 'Error')) { $env:NASUNI_LOG_LEVEL } else { 'Warning' })
    LogFile            = $(if ($env:NASUNI_LOG_FILE) { $env:NASUNI_LOG_FILE } else { $null })
    RecentLog          = [System.Collections.Generic.Queue[string]]::new()
    Stats              = @{ Requests = 0; Retries = 0; Throttled = 0; Failures = 0; LastErrorUtc = $null; LastCorrelationId = $null }
    RedactValues       = [System.Collections.Generic.List[string]]::new()
}

$script:NmcEndpoints = $null
$script:NmcCommandEndpoints = $null

$script:FipsApprovedSuites = @(
    'TLS_AES_128_GCM_SHA256', 'TLS_AES_256_GCM_SHA384',
    'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256', 'TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384',
    'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256', 'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384',
    'TLS_DHE_RSA_WITH_AES_128_GCM_SHA256', 'TLS_DHE_RSA_WITH_AES_256_GCM_SHA384'
)

foreach ($folder in 'Private', 'Public') {
    $dir = Join-Path $PSScriptRoot $folder
    if (Test-Path $dir) {
        foreach ($file in Get-ChildItem -Path $dir -Filter '*.ps1' -File) {
            . $file.FullName
        }
    }
}

# Refuse to load on a non-FIPS host unless explicitly overridden for development.
# The override is ignored when NASUNI_ENVIRONMENT=Production.
$fips = Test-NasuniFipsHost
if (-not $fips.IsFipsHost) {
    $override = $env:NASUNI_ALLOW_NON_FIPS_HOST -eq '1'
    $isProd = $env:NASUNI_ENVIRONMENT -eq 'Production'
    if ($override -and -not $isProd) {
        Write-Warning ('Nasuni.Nmc: host is NOT in FIPS mode ({0}). Loaded only because NASUNI_ALLOW_NON_FIPS_HOST=1. Do not use in production.' -f ($fips.Evidence -join '; '))
    }
    else {
        throw ('Nasuni.Nmc: host is not in FIPS-approved mode ({0}). Enable FIPS mode, or for development only set NASUNI_ALLOW_NON_FIPS_HOST=1.' -f ($fips.Evidence -join '; '))
    }
}

$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    if ($script:NmcState.HttpClient) { $script:NmcState.HttpClient.Dispose() }
}

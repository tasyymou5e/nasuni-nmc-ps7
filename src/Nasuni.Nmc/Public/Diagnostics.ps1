# Debugging aids: logging control and a one-shot diagnostic snapshot.

function Set-NasuniLogging {
    <#
    .SYNOPSIS
        Changes the log level and/or log file for this PowerShell session.
    .DESCRIPTION
        Levels: Debug (every request with timing, paging, retries, bulk items),
        Info, Warning (default), Error. Logs are JSON lines on stderr, and in -Path too
        when given (chmod 600). Secrets are redacted before anything is written.
        The same settings come from NASUNI_LOG_LEVEL and NASUNI_LOG_FILE at import.
    .EXAMPLE
        Set-NasuniLogging -Level Debug -Path ./nasuni-debug.jsonl
    .EXAMPLE
        Set-NasuniLogging -Path $null      # stop writing to a file
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')][string]$Level,
        [AllowNull()][AllowEmptyString()][string]$Path
    )
    if (-not $PSCmdlet.ShouldProcess('Nasuni.Nmc logging', 'Change settings')) { return }
    if ($PSBoundParameters.ContainsKey('Level')) { $script:NmcState.LogLevel = $Level }
    if ($PSBoundParameters.ContainsKey('Path')) { $script:NmcState.LogFile = if ($Path) { $Path } else { $null } }
    [pscustomobject]@{ Level = $script:NmcState.LogLevel; Path = $script:NmcState.LogFile }
}

function Get-NasuniDiagnostic {
    <#
    .SYNOPSIS
        Collects what you need to debug a problem, without secrets: runtime and FIPS state,
        connection, rate-limit and circuit-breaker state, request counters, and recent log entries.
    .DESCRIPTION
        Safe to paste into a ticket: the token, password and Vault tokens are never included,
        and the log entries were redacted when they were written.
    .PARAMETER Last
        How many recent log entries to include (1-200).
    .EXAMPLE
        Get-NasuniDiagnostic | ConvertTo-Json -Depth 5 | Set-Content diag.json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([ValidateRange(1, 200)][int]$Last = 50)
    $module = Get-Module Nasuni.Nmc
    $buckets = @{}
    foreach ($k in $script:NmcState.Buckets.Keys) { $buckets[$k] = [math]::Round([double]$script:NmcState.Buckets[$k].Tokens, 2) }
    $entries = @($script:NmcState.RecentLog.ToArray() | Select-Object -Last $Last | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $_ } })
    [pscustomobject][ordered]@{
        TimestampUtc     = [datetime]::UtcNow.ToString('o')
        ModuleVersion    = if ($module) { [string]$module.Version } else { $null }
        PowerShell       = $PSVersionTable.PSVersion.ToString()
        DotNet           = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        OS               = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        Fips             = Test-NasuniFipsHost
        DevOverride      = $env:NASUNI_ALLOW_NON_FIPS_HOST -eq '1'
        Environment      = $env:NASUNI_ENVIRONMENT
        Connection       = Get-NasuniConnection
        CircuitOpenUntil = if ($script:NmcState.CircuitOpenUntilUtc -gt [datetime]::UtcNow) { $script:NmcState.CircuitOpenUntilUtc.ToString('o') } else { $null }
        ConsecutiveFailures = $script:NmcState.ConsecutiveFailures
        RateBucketTokens = $buckets
        Stats            = [pscustomobject]$script:NmcState.Stats
        Logging          = [pscustomobject]@{ Level = $script:NmcState.LogLevel; File = $script:NmcState.LogFile }
        RecentLog        = $entries
    }
}

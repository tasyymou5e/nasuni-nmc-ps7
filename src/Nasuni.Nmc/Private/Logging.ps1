# FILE: Private/Logging.ps1. Redaction and structured logging.
#   Protect-NmcText        strips tokens, passwords and Vault tokens from any text
#   Register-NmcRedaction  adds a live secret (the current token) to the redaction list
#   Write-NmcLog           JSON lines to stderr, the optional log file and the in-memory ring
# Debug: Set-NasuniLogging -Level Debug [-Path file], or NASUNI_LOG_LEVEL / NASUNI_LOG_FILE.

function Protect-NmcText {
    <#
    .SYNOPSIS
        Redacts secrets from text before it is logged or surfaced in an error.
    .DESCRIPTION
        Removes values registered with Register-NmcRedaction (tokens, Vault tokens) and
        anything that looks like an Authorization header, a token/password JSON field
        or an X-Vault-Token header.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $out = $Text
    foreach ($secret in $script:NmcState.RedactValues) {
        if ($secret.Length -ge 6) { $out = $out.Replace($secret, '***') }
    }
    $out = $out -replace '(?i)(Authorization\s*[:=]\s*)(Token|Bearer)\s+[^\s"'',}]+', '$1$2 ***'
    $out = $out -replace '(?i)("?(password|passwd|secret_id|client_token|token)"?\s*[:=]\s*")[^"]*(")', '$1***$3'
    $out = $out -replace '(?i)(X-Vault-Token\s*[:=]\s*)[^\s"'',}]+', '$1***'
    $out
}

function Register-NmcRedaction {
    # Adds a secret value to the redaction list (in-memory only).
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value.Length -ge 6 -and -not $script:NmcState.RedactValues.Contains($Value)) {
        $script:NmcState.RedactValues.Add($Value)
    }
}

$script:NmcLogRank = @{ Debug = 0; Info = 1; Warning = 2; Error = 3 }

function Write-NmcLog {
    <#
    .SYNOPSIS
        Writes a structured, redacted JSON log line.
    .DESCRIPTION
        Destinations:
          - stderr (always), so stdout stays clean for pipelines and the MCP stdio protocol;
          - the file in NASUNI_LOG_FILE / Set-NasuniLogging -Path (JSON lines, chmod 600);
          - an in-memory ring of the last 200 entries (Info and above, or everything at Debug),
            read with Get-NasuniDiagnostic. Errors are kept even when the console level is higher.
        Every entry passes through Protect-NmcText, so tokens and passwords never reach any sink.
        Logging never throws: a failing log file must not break an API call.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')][string]$Level = 'Info',
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data
    )

    $levelRank = $script:NmcLogRank[$Level]
    $consoleRank = $script:NmcLogRank[$script:NmcState.LogLevel]
    $ringRank = [math]::Min($consoleRank, 1)
    if ($levelRank -lt $consoleRank -and $levelRank -lt $ringRank) { return }

    $entry = [ordered]@{
        ts    = [datetime]::UtcNow.ToString('o')
        level = $Level
        msg   = $Message
        pid   = $PID
    }
    if ($Data) { $entry.data = $Data }
    $line = Protect-NmcText -Text ($entry | ConvertTo-Json -Compress -Depth 6)

    $ring = $script:NmcState.RecentLog
    $ring.Enqueue($line)
    while ($ring.Count -gt 200) { $null = $ring.Dequeue() }

    if ($levelRank -lt $consoleRank) { return }
    try { [Console]::Error.WriteLine($line) } catch { $null = $_ }
    $file = $script:NmcState.LogFile
    if ($file) {
        try {
            $isNew = -not (Test-Path -LiteralPath $file)
            [System.IO.File]::AppendAllText($file, $line + "`n", [System.Text.UTF8Encoding]::new($false))
            if ($isNew -and -not $IsWindows) { [System.IO.File]::SetUnixFileMode($file, [System.IO.UnixFileMode]'UserRead, UserWrite') }
        }
        catch { $null = $_ }
    }
}

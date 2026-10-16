#Requires -Version 7.4
# ENTRY: MCP server process. It loads the config (no secrets), imports the modules quietly (stdout must
# stay clean), builds the tool catalog, and reads JSON-RPC lines from stdin until EOF.
<#
.SYNOPSIS
    Starts the read-only Nasuni NMC MCP server on stdio.
.DESCRIPTION
    Stdout carries only JSON-RPC messages. Everything else (logs, warnings) goes to stderr
    or is suppressed. The config file holds no secrets: the NMC credential comes from
    HashiCorp Vault at the first tool call.

    Claude Desktop / Claude Code config:
      { "command": "pwsh", "args": ["-NoProfile", "-NonInteractive", "-File", "<path>/Start-NasuniMcpServer.ps1", "-ConfigPath", "<path>/mcp-config.psd1"] }
.PARAMETER ConfigPath
    PowerShell data file. See mcp-config.example.psd1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ConfigPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

try {
    $config = Import-PowerShellDataFile -LiteralPath $ConfigPath
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Nasuni.Nmc/Nasuni.Nmc.psd1') -Force 3>$null
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Nasuni.Nmc.Mcp.psm1') -Force 3>$null
    $count = Initialize-McpServer -Config $config
    [Console]::Error.WriteLine(('{{"ts":"{0}","level":"Info","msg":"nasuni-nmc-readonly MCP server ready","data":{{"tools":{1}}}}}' -f [datetime]::UtcNow.ToString('o'), $count))
}
catch {
    [Console]::Error.WriteLine("nasuni-nmc-readonly: startup failed: $($_.Exception.Message)")
    exit 1
}

Start-McpStdioLoop

#Requires -Version 7.4
# ENTRY: container entrypoint. Modes:
#   dashboard  production dashboard. Config: NASUNI_DASHBOARD_CONFIG (default /etc/nasuni/dashboard-config.psd1)
#   mcp        read-only MCP server on stdio (run with docker run -i). Config: NASUNI_MCP_CONFIG
#   demo       local demo (fake NMC and dashboard, development only; demo image target)
#   diag       prints Get-NasuniDiagnostic as JSON (FIPS state, versions) and exits
param([ValidateSet('dashboard', 'mcp', 'demo', 'diag')][string]$Mode = 'dashboard')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

switch ($Mode) {
    'dashboard' {
        $cfg = if ($env:NASUNI_DASHBOARD_CONFIG) { $env:NASUNI_DASHBOARD_CONFIG } else { '/etc/nasuni/dashboard-config.psd1' }
        if (-not (Test-Path -LiteralPath $cfg)) { [Console]::Error.WriteLine("Dashboard config not found at $cfg. Mount it read-only (see docs/DOCKER.md)."); exit 2 }
        & /app/src/Nasuni.Nmc.Dashboard/Start-NasuniDashboard.ps1 -ConfigPath $cfg
    }
    'mcp' {
        $cfg = if ($env:NASUNI_MCP_CONFIG) { $env:NASUNI_MCP_CONFIG } else { '/etc/nasuni/mcp-config.psd1' }
        if (-not (Test-Path -LiteralPath $cfg)) { [Console]::Error.WriteLine("MCP config not found at $cfg."); exit 2 }
        & /app/src/Nasuni.Nmc.Mcp/Start-NasuniMcpServer.ps1 -ConfigPath $cfg
    }
    'demo' {
        if (-not (Test-Path -LiteralPath /app/tools/Start-DashboardDemo.ps1)) { [Console]::Error.WriteLine('This image has no demo. Build with --target demo.'); exit 2 }
        $port = if ($env:DEMO_PORT) { [int]$env:DEMO_PORT } else { 8765 }
        & /app/tools/Start-DashboardDemo.ps1 -Port $port -Address 0.0.0.0
    }
    'diag' {
        Import-Module /app/src/Nasuni.Nmc/Nasuni.Nmc.psd1 -WarningAction SilentlyContinue
        Get-NasuniDiagnostic | ConvertTo-Json -Depth 5
    }
}

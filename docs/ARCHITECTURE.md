# Architecture

```
                   ┌──────────────── HashiCorp Vault (Enterprise FIPS) ────────────────┐
                   │ nmc-ro  nmc-ops  session secret  audit HMAC key  OIDC secret  PKI │
                   └───────▲───────────────────▲───────────────────────────────▲──────┘
                           │                   │                               │
 Claude ── stdio ──► Nasuni.Nmc.Mcp       Nasuni.Nmc.Dashboard (Pode, HTTPS)    CLI / scheduled jobs
                     GET-only tools       routes: ops account (confirmed changes)
                     + list/run_report    timers: ro account (snapshot, report jobs)
                           │                   │                               │
                           └───────────────────┴──────── Nasuni.Nmc ───────────┘
                                                            │
       cmdlet ─► Invoke-NmcEndpoint ─► Invoke-NmcRequest ─► Invoke-NmcHttp ─► NMC API v1.2
       (generated)  (paging, ShouldProcess,  (rate limit, auth, retry,   (TLS 1.2/1.3, OS chain
                     async wait)              circuit breaker, logging)   validation, FIPS suites)
```

## Modules

| Module | Role | Key files |
|---|---|---|
| `Nasuni.Nmc` | API client, Vault, FIPS/TLS checks, reports, bulk engine, diagnostics | `Private/Request.ps1` (pipeline), `Private/Http.ps1` (transport), `Public/Endpoints.Generated.ps1` (118 cmdlets), `Public/Reports.ps1`, `Public/Bulk*.ps1` |
| `Nasuni.Nmc.Mcp` | Read-only MCP server | `Nasuni.Nmc.Mcp.psm1`, `Start-NasuniMcpServer.ps1` |
| `Nasuni.Nmc.Dashboard` | Dashboard logic (Pode-independent) plus the Pode wiring | `Nasuni.Nmc.Dashboard.psm1`, `Pages.ps1`, `Start-NasuniDashboard.ps1` |

## Cross-cutting rules

- **One network seam:** only `Invoke-NmcHttp` sends requests. Tests mock it, or point it at the local TLS fake.
- **Secrets:** they come from Vault and live in memory only. `Protect-NmcText` redacts logs and errors, and `Protect-NasuniSensitiveData` redacts data that reaches any output.
- **Every failure is traceable:** each request has a correlation id, carried in `NasuniApiException`. Dashboard responses carry `X-Request-Id`. Both appear in the logs and in `Get-NasuniDiagnostic`.
- **Writes are deliberate:**
  - ShouldProcess runs once per change, and login is never gated by it.
  - Writes are retried only on 429.
  - Async changes are waited to completion and read back.
  - Every change is audited (HMAC-chained) in the dashboard.
- **Least privilege:** MCP and the dashboard's data timers use the read-only NMC account. Only confirmed dashboard changes use the operator account.
- **Strict mode everywhere.** PowerShell pitfalls hit during development are listed in `docs/TROUBLESHOOTING.md` and marked `DEBUG NOTE` in the code.

## Debugging quick reference

```powershell
Set-NasuniLogging -Level Debug -Path ./debug.jsonl   # or NASUNI_LOG_LEVEL=Debug NASUNI_LOG_FILE=...
Get-NasuniDiagnostic | ConvertTo-Json -Depth 5        # runtime, FIPS, connection, breaker, counters, recent log
Test-NasuniNmcTls -ComputerName nmc.corp.example      # TLS preflight: suite, certificate, pin
```

| Component | Where it logs |
|---|---|
| Dashboard | Every request is logged as `HTTP request` with `requestId`. 5xx responses are logged at Error. Report jobs log start, finish and retry |
| MCP | Every tool call is logged with its duration to stderr. Claude Desktop keeps stderr in its MCP log |

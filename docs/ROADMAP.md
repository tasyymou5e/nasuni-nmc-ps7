# Roadmap: work needed before and after production

Each item names its code location. The code carries a matching `TODO(roadmap#N)` comment. To list them:

```bash
grep -rn "TODO(roadmap" src build tests
```

Everything so far has been verified on macOS against fakes: a fake NMC (in-process, and over real TLS), mocked Vault, and dev-only sign-in. **P0 items must be done before production use.**

## P0: validate against real systems

| # | Item | Why | How / where |
|---|---|---|---|
| 1 | **Run read-only against a real (non-production) NMC.** | Field names for filer health and the `status.*` fields on volume/filer settings are not in the published spec. Reports, overview tiles and the unprotected-data alert assume `status.accessible_data`, `status.data_not_yet_protected`, `status.last_snapshot` and similar names. | `Connect-Nasuni -ReadOnly`, then every report via `Export-NasuniReportBundle -Name (Get-NasuniReportList).Name`. Diff the columns against the old scripts' CSVs. Fix paths in `Reports.ps1` and `Pages.ps1` |
| 2 | **Run the FIPS gates on real FIPS hosts.** | Only the non-FIPS dev path has run. | Enable the `fips` CI job (self-hosted RHEL 9 `fips=1` and a Windows FIPS GPO runner). Record CMVP certificate numbers in the SSP. Confirm `Test-NasuniNmcTls` against the NMC shows an approved suite. `Test-NasuniFipsHost.ps1` |
| 3 | **Test OIDC sign-in with the real IdP.** | Only the dev sign-ins (DevHeader, DevLogin) are exercised. The groups claim, PKCE, the redirect URL and logout are untested. | Register the app in Entra ID (or your IdP). Confirm `GroupsClaim` comes back in the user-info response; Entra may need Graph or token-claim configuration. `Start-NasuniDashboard.ps1` (Oidc branch) |
| 4 | **Test Vault Enterprise (FIPS build) live.** | Cert/AppRole login, KV reads, PKI issuance and the hourly renewal restart are mocked in tests. | Create roles and policies from `deploy/vault-policy.hcl`, run `Get-NasuniVaultCredential` and `New-NasuniVaultPkiCertificate`, and let a short-TTL certificate trigger `Restart-PodeServer` |
| 5 | **Scan the dashboard's server-side TLS.** | The dashboard's TLS suites come from the OS crypto policy, because Pode cannot set them. | `testssl.sh https://dash:8443`. On RHEL use `update-crypto-policies --set FIPS`; on Windows, the SChannel FIPS policy |
| 6 | **Push to a remote and let CI run.** | The workflow has never run, and Linux and Windows runners have not executed the suite. | `.github/workflows/ci.yml` |

## P1: functionality and operations

| # | Item | Notes |
|---|---|---|
| 7 | **Port the Edge Data API scripts.** | Three folder-size reports and two Data API examples (`/mobileapi/1`, a separate per-appliance API). Needs its own token handling (Vault-sourced), TLS policy and tests. `Reports.ps1` (the `path-info` report is the stopgap) |
| 8 | **Dashboard UI for bulk plans.** | Upload CSV → plan preview (items and skipped) → approval → execute with journal → resume. Add a **second approver** for destructive plans. Engine: `Bulk.ps1`; UI: `Pages.ps1` |
| 9 | **Durable sessions and report jobs.** | Sessions and report jobs are in memory: a restart signs everyone out and forgets job history, and only one dashboard instance is supported. Use a Pode session-storage backend and persist job metadata. `Start-NasuniDashboard.ps1` |
| 10 | **Forward and anchor the audit log.** | Send audit JSONL to the SIEM (syslog over TLS), and periodically anchor the last HMAC externally (SIEM or WORM storage), so deleting the whole file is detectable too. `Write-DashAudit` |
| 11 | **Share the rate limit across processes.** | `RateShare` is a static split (MCP 0.4 / dashboard 0.6), and inside the dashboard it is divided per runspace. A shared limiter (for example a small local token service) would use the budget better. `RateLimit.ps1` |
| 12 | **Remote MCP transport.** | stdio only today. For a shared server, add Streamable HTTP with OAuth and per-user audit. `Nasuni.Nmc.Mcp.psm1` |
| 13 | **Release packaging.** | Authenticode-sign the modules (AllSigned policy), SBOM (CycloneDX), publish to an internal PSResourceGet feed, and pin Pode via `RequiredModules` |
| 14 | **Service units.** | systemd unit and Windows service wrapper for the dashboard (run as a dedicated low-privilege account), with log rotation for `NASUNI_LOG_FILE`. `deploy/` |

## P2: improvements

| # | Item | Notes |
|---|---|---|
| 15 | **Auto-refresh job status.** | Allowed by the CSP: `<meta http-equiv="refresh">` on the Reports page while jobs are queued. `Format-DashReportsBody` |
| 16 | **GFL before/after report.** | The original DisableGFL script recorded GFL state before and after, and took a snapshot. Add an optional `-Snapshot` and a state report to `New-NasuniGlobalLockPlan` |
| 17 | **Health-specific overview tile.** | Count unhealthy filers once the real health field names are known (see #1). `Format-DashOverviewBody` |
| 18 | **Display time zones.** | Times are UTC throughout; make the display time zone a per-user preference |
| 19 | **Notification acknowledgement.** | Not in the v1.2 API. Revisit when Nasuni adds it |

## Known limitations (by design, documented)

- **Read-only reports:** `path-info` and `shares-with-sizes` need a non-read-only connection (they refresh path info with a POST), so they are not offered through MCP or dashboard report jobs.
- **Development modes:** `DevHeader`, `DevLogin` and `Dev.Http` are refused outside development mode and loopback addresses.
- **Windows FIPS check:** .NET on Windows does not block MD5 in FIPS mode, so the Windows check reads the policy setting rather than probing.

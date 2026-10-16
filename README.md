# Nasuni.Nmc for PowerShell 7

A hardened PowerShell 7 client for the Nasuni Management Console (NMC) API v1.2, and a read-only MCP server built on it.

The NMC API reference is at https://docs.api.nasuni.com/api/nmc/v120/. This project replaces the TLS-bypassing, page-one-only patterns in the nasuni-labs `NasuniPoshApi` and `nasuni-api-utilities` repos.

| Component | Status |
|---|---|
| `src/Nasuni.Nmc`: API module. 118 endpoint cmdlets generated from the documented v1.2 spec, plus connection, Vault, TLS and FIPS commands | Built and tested |
| `src/Nasuni.Nmc.Mcp`: read-only MCP server (stdio) | Built and tested |
| `src/Nasuni.Nmc.Dashboard`: HTTPS web dashboard (Pode 2.14.1; no third-party JavaScript) | Built and tested |
| Ports of the 86 nasuni-api-utilities scripts: 25 named reports and 15 bulk-plan builders on a plan/dry-run/execute/resume engine. See [docs/MIGRATION.md](docs/MIGRATION.md) | Built and tested (Edge Data API scripts not yet ported) |

## Security model

- **TLS validation is always on.** There is no `-SkipCertificateCheck`, no `TrustAllCertsPolicy`, and nothing changes `ServicePointManager`. Only TLS 1.2 and 1.3 are allowed. On Linux the client is limited to FIPS-approved AES-GCM suites; on Windows, SChannel's FIPS policy applies. Three optional controls tighten this further:
  - `-TrustedCaCertificatePath` trusts only your private CA.
  - `-PinnedSpkiSha256` pins the NMC public key, and is checked *before* credentials are sent.
  - `-RevocationMode` defaults to `Online`, and fails closed.
- **FIPS mode:** the module refuses to load unless the OS crypto provider is in FIPS mode. See below.
- **Secrets:**
  - NMC credentials come from HashiCorp Vault (KV v2), using TLS client-certificate or AppRole auth. The Vault token is revoked right after the read.
  - The NMC token lives only in memory.
  - Logs are JSON on stderr, with tokens, passwords and Vault tokens redacted.
- **Writes:**
  - Every write cmdlet supports `-WhatIf`/`-Confirm`, and deletes use `ConfirmImpact = High`.
  - `-WhatIf` never blocks login or reads.
  - Writes are retried only on 429, so a POST can never be duplicated.
  - The antivirus delete has no default action.
- **Robustness:**
  - Paging walks every page, with protection against duplicate pages.
  - Requests follow the documented NMC rate limits (5/s reads, 1/s writes, 10/min auth). `RateShare` splits that budget between processes.
  - A 401 triggers one re-login. GETs back off and retry on 5xx, and a circuit breaker stops repeated failures.
  - Async messages are polled to completion: 303 counts as success, and 404 is reported as expired.
- **MCP server:** read-only is enforced in three layers:
  1. The NMC account read from Vault is a read-only account.
  2. The server offers GET tools only.
  3. The connection is opened with `-ReadOnly`, so the HTTP layer rejects any non-GET.

  Tool output is capped, size-limited and labelled as untrusted data.

## FIPS 140-2 / 140-3

PowerShell 7 and .NET have no cryptography of their own; they use the operating system's validated module. Compliance therefore means running on a FIPS-mode host and using only approved algorithms. The module enforces both.

| Host | Validated module | Enable | Check |
|---|---|---|---|
| RHEL 9 | OpenSSL 3 FIPS provider | `fips-mode-setup --enable`, then reboot | `/proc/sys/crypto/fips_enabled` is 1, and MD5 is refused |
| Windows Server 2022/2025 | CNG / SChannel | GPO *System cryptography: Use FIPS compliant algorithms* | `HKLM\...\Lsa\FipsAlgorithmPolicy\Enabled` is 1 |
| Vault | Vault Enterprise FIPS build | Enterprise license, HSM seal | Vault build string contains `+fips1403` |

- **Record the certificates:** add the CMVP certificate numbers for your exact OS builds to your SSP. Windows CNG may still be certified under FIPS 140-2 for your build; check the CMVP listing for 140-3.
- **Check the appliance:** `Test-NasuniNmcTls -ComputerName <nmc>` reports the negotiated suite. If your NMC cannot negotiate an approved suite, end-to-end FIPS is not possible, and that is a Nasuni-side issue.
- **Development override:** on a non-FIPS dev machine, set `NASUNI_ALLOW_NON_FIPS_HOST=1`. This is ignored when `NASUNI_ENVIRONMENT=Production`.

## Quick start

```powershell
Import-Module ./src/Nasuni.Nmc/Nasuni.Nmc.psd1
Test-NasuniNmcTls -ComputerName nmc.corp.example        # preflight check, and gives you the SPKI pin
$cred = Get-NasuniVaultCredential -VaultAddress https://vault.corp:8200 -Mount kv -SecretPath nasuni/nmc-ops `
          -AuthMethod Cert -CertRole nasuni-ops -ClientCertificatePath ./vault.crt -ClientKeyPath ./vault.key
Connect-Nasuni -ComputerName nmc.corp.example -Credential $cred -PinnedSpkiSha256 '<pin>'
Get-NasuniVolumes | Measure-Object                      # every page, not just the first
Set-NasuniShare -VolumeGuid $g -FilerSerial $s -ShareId 12 -Body @{ readonly = $true } -WhatIf
Remove-NasuniAntivirusViolation -VolumeGuid $g -FilerSerial $s -AntivirusId 42 -Action ignore_violation -Wait
```

`Invoke-NasuniRequest` reaches any endpoint through the same pipeline.

## MCP server (Claude Desktop / Claude Code)

Copy `src/Nasuni.Nmc.Mcp/mcp-config.example.psd1` and fill it in. It holds no secrets. Then add:

```json
{ "mcpServers": { "nasuni-nmc": {
    "command": "pwsh",
    "args": ["-NoProfile", "-NonInteractive", "-File", "/opt/nasuni-nmc-ps7/src/Nasuni.Nmc.Mcp/Start-NasuniMcpServer.ps1",
             "-ConfigPath", "/etc/nasuni/mcp-config.psd1"] } } }
```

## Dashboard

Pode 2.14.1 serves server-rendered pages over HTTPS. There is no JavaScript at all (CSP `script-src 'none'`). Pode.Web was not used: it was last updated in 2023 and bundles front-end libraries just as old.

- **Pages:** overview tiles, then filers, volumes, shares, antivirus violations, notifications, volume connections, filer health, cloud credentials (metadata only) and audit log (Admin only). Every list has a CSV report; formulas are neutralised and secrets redacted.
- **Sign-in and roles:** OIDC with PKCE. IdP groups map to Viewer (read), Operator (share read-only flag, ignore an antivirus violation, refresh) or Admin (also delete infected files, read the audit log).
- **Changes:** form, then preview (reads the current state), then type the confirmation phrase exactly, then execute, read back to verify, and audit. A preview is single-use, expires after 5 minutes, and must be confirmed by the same user.
- **Audit:** every attempt is recorded, including refused confirmations, in an HMAC-SHA256 hash chain. The Audit page verifies the chain.
- **Hardening:** HSTS, `frame-ancestors 'none'`, and a session cookie that is `Secure; HttpOnly; SameSite=Strict`. CSRF tokens plus a same-origin check protect every POST. There is no `Server` header.
- **Least privilege:** a timer reads data with the read-only NMC account. Only confirmed changes use the operator account.

```bash
pwsh -NoProfile -File src/Nasuni.Nmc.Dashboard/Start-NasuniDashboard.ps1 -ConfigPath /etc/nasuni/dashboard-config.psd1
```

`dashboard-config.example.psd1` documents every setting. All secrets come from Vault: NMC accounts, the session secret, the audit HMAC key, the OIDC client secret and the TLS certificate (via Vault PKI, re-issued before expiry).

## Build gates

```powershell
./build/build.ps1                  # Generate check, Parse, Lint (default + custom security rules), Pester with coverage
./build/build.ps1 -Task Format     # auto-fix formatting in place
```

- **Custom lint rules** (`build/Rules/NasuniSecurityRules.psm1`) fail the build on any of these:
  - TLS bypasses
  - `ConvertTo-SecureString -AsPlainText`
  - `Invoke-Expression` / `Add-Type`
  - MD5/SHA1
  - `GetHashCode()`
  - `[string]$Password` parameters
  - `0..(Count-1)` loops
- **CI** (`.github/workflows/ci.yml`) runs the gates on Linux, Windows and macOS, plus live TLS rejection tests, gitleaks, and an optional job on self-hosted FIPS-mode runners.
- **Regenerating cmdlets:** after changing `Data/Endpoints.psd1`, run `build/New-EndpointCmdlets.ps1`.

## Docker

`docker compose up --build demo` runs the demo on Docker Desktop at http://localhost:8765. Production, MCP-in-a-container and Linux test runs are covered in [docs/DOCKER.md](docs/DOCKER.md).

## Architecture, roadmap and debugging

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): components, request path, and cross-cutting rules.
- [docs/ROADMAP.md](docs/ROADMAP.md): what must be done before production (P0) and next (P1/P2). The code carries matching `TODO(roadmap#N)` markers.
- Debugging: `Set-NasuniLogging -Level Debug -Path ./debug.jsonl` and `Get-NasuniDiagnostic`. Dashboard responses carry `X-Request-Id`.
- Dashboard Reports page: runs any of the 23 read-only reports as a background job on the read-only account. Only the requester and Admins can download a job's CSV, which expires after `ReportRetentionHours`.

## Troubleshooting

[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) records every non-obvious problem found during development, each with its symptom, cause, fix and code location. The code carries matching `DEBUG NOTE` comments; run `grep -rn "DEBUG NOTE" src build tests` to list them.

## License

MIT. This is new code, and the design ideas come from the MIT-licensed nasuni-labs repositories. Nothing is copied from `local-nasuni-management-mcp-server`, which has no license.

# Troubleshooting and debug notes

Every entry below is a real problem found while building and testing this project. Each one lists the symptom you'll see, the cause, the fix, and where it lives in the code. The code at each location carries a `DEBUG NOTE` comment pointing back here. To find them all:

```bash
grep -rn "DEBUG NOTE" src build tests
```

## PowerShell language traps

### Dynamic scope
- **Symptom:** with Cert auth, `New-NasuniVaultPkiCertificate` requested a certificate from the Vault *login* role, not the PKI role.
- **Cause:** a script block passed into a function and run there looks variables up through the call stack. The PKI block read `$Role`, but `Invoke-NmcVaultSession` had its own `$role`, and PowerShell variable names ignore case.
- **Fix:** action blocks receive everything through an explicit `$Arguments` hashtable (`param($session, $a)`). `Get-DashSnapshot` passes `$MaxNotifications` the same way.
- **Where:** `src/Nasuni.Nmc/Public/Get-NasuniVaultCredential.ps1` (`Invoke-NmcVaultSession`); regression test in `tests/Unit/Vault.Tests.ps1`.
- **Rule:** never let a script block that is passed to another function read outside variables. PSScriptAnalyzer's "parameter declared but not used" warning is often the first sign.

### GetNewClosure
- **Symptom:** `The term 'X' is not recognized` when a closure calls a module's private function.
- **Cause:** inside a module, `.GetNewClosure()` binds the block to a new dynamic module, so it can't see the original module's private functions.
- **Fix:** don't use closures that call functions; call a named module function instead (`Get-DashAntivirusLink`). The one closure left, `Get-NmcVaultSettingReader`, uses only captured data.

### Array wrapping
- **Symptom:** the dashboard showed 1 blank row instead of N items, and CSV exports had one empty line.
- **Cause:** `Protect-NasuniSensitiveData` returns `, $array`, which emits the array as one object. `@(Protect-...)` wrapped it in a second array.
- **Fix:** assign first, then wrap: `$x = Protect-...; @($x)`.
- **Where:** `Get-DashSnapshot`; regression test with two items in `tests/Unit/Dashboard.Tests.ps1`.
- **Second occurrence:** `Get-NmcVolumeFilerItem` returned `, $result`, so every volume/filer report showed one row. Rule: only `Protect-NasuniSensitiveData` uses the leading-comma return. Everything else returns plainly and lets callers use `@()`.

### Strict mode
- **Symptom:** `The property 'Name' cannot be found on this object` when the NMC returns `{}`, or when MCP gets `params: {}`.
- **Cause:** under `Set-StrictMode -Version Latest`, `.PSObject.Properties.Name` throws on an object with no properties.
- **Fix:** test with `$null -ne $obj.PSObject.Properties['name']`, and list names with `@($obj.PSObject.Properties | ForEach-Object Name)`.
- **Where:** `Request.ps1`, `Wait-NasuniMessage.ps1`, `Nasuni.Nmc.Mcp.psm1`, `Get-NasuniVaultCredential.ps1`.
- **Related:** `$hashtable.MissingKey` also throws under strict mode ("property cannot be found"). Read optional keys as `$hashtable['MissingKey']`, which returns `$null`. **Where:** report parameters in `Reports.ps1`.
- **Related:** `$null.Count` also throws under strict mode. Functions that may return 0 or 1 items should `return , @(...)`.

### Empty results
- **Symptom:** a dashboard list page returned HTTP 500 when its section was empty (for example, no antivirus violations).
- **Cause:** `$rows = if (...) { @(...) } else { @() }` assigns `$null` when the branch yields an empty array, because the pipeline unrolls it. Under strict mode, `.Count` then throws.
- **Related:** a `Mandatory` array parameter rejects an empty array at binding unless it has `[AllowEmptyCollection()]` (`Format-DashTable -Columns`).
- **Fix:** `$rows = @(if (...) { ... })`. **Where:** `Format-DashSectionBody` in `Pages.ps1`; the test now renders every section empty.

### .NET 8 vs .NET 9
- **Symptom:** on PowerShell 7.4, `Unable to find type [System.Security.Cryptography.X509Certificates.X509CertificateLoader]`. The local TLS server, the dev certificate and Vault PKI all fail, so roughly 30 tests fail. The same tests pass on PowerShell 7.5.
- **Cause:** `X509CertificateLoader` is new in .NET 9 (PowerShell 7.5). The module targets 7.4 (.NET 8). Development happened on 7.5, so nothing caught it until the Linux container ran 7.4.
- **Fix:** `Import-NasuniCertificate` picks the loader at runtime. Never call `X509CertificateLoader` directly.
- **Prevention:** run the suite on the minimum supported version too: the `test` Docker target (7.4) and the CI matrix.

### Task results
- **Symptom:** `Test-NasuniNmcTls` output had no `CertificateValid` property.
- **Cause:** `.GetAwaiter().GetResult()` on a non-generic `Task` emits a `VoidTaskResult` object, so the function returned an array.
- **Fix:** `$null = ...GetAwaiter().GetResult()`.

### Nullable values
- **Symptom:** parsing a 429 response's `Retry-After` header crashed with `The property 'Value' cannot be found`.
- **Cause:** PowerShell unwraps `Nullable<T>`, so `RetryAfter.Delta` is already a `TimeSpan` or `$null`, and `.Value` does not exist.
- **Fix:** compare with `$null`, then cast. **Where:** `Invoke-NmcHttp` in `Http.ps1`.

### Parameter and alias names that differ only in case
- **Symptom:** 7 folder-path cmdlets failed to load with `MetadataException: The parameter 'Path' ... conflicts with the parameter alias`.
- **Cause:** parameter names and aliases ignore case, so the parameter `Path` and its alias `path` collide.
- **Fix:** the generator renames it to `-FolderPath` (alias `path`). **Where:** `$paramNameMap` in `build/New-EndpointCmdlets.ps1`.

### TLS validation callbacks
- **Issue:** a PowerShell script block used as `RemoteCertificateValidationCallback` runs on a thread pool thread with no runspace, and fails or crashes.
- **Fix:** no callbacks are used. The OS validates the chain. Private-CA trust uses `X509ChainPolicy` with `CustomRootTrust`, and SPKI pinning runs as a separate preflight handshake in `Test-NasuniNmcTls`. **Where:** `New-NmcSslClientOption`.

## Pode 2.14.1

| Symptom | Cause | Fix / location |
|---|---|---|
| `A Using variable cannot be retrieved` at startup | `$using:` is invalid in the top-level `Start-PodeServer` block | Use script variables directly there. `$using:` only works in route, timer and middleware blocks |
| Route can't see a function or variable from the start script | Routes, timers and middleware run in separate runspaces | Put shared code in a module loaded with `Import-PodeModule`. Put shared data in `Set-PodeState` |
| Each runspace logs in to the NMC separately | Module state (`$script:NmcState`) is per runspace | Expected. `Connect-DashNmc` keeps one connection per runspace, and `RateShare` is divided across runspaces |
| Raw HTML injected into a page | `Write-PodeHtmlResponse -Value <string>` does **not** escape | All values go through `ConvertTo-DashHtml` or `Format-DashTable` |
| Session cookie has no `SameSite` | Pode 2.14 has no SameSite option | Endware in `Start-NasuniDashboard.ps1` appends `SameSite=Strict` |
| CSRF 403s from .NET or curl clients; browsers work | Pode writes `Max-Age=899.9998`, but RFC 6265 requires an integer, so strict clients drop the cookie and lose the session | The same endware rounds Max-Age down to an integer |
| Unauthenticated request returns **500**, not 401 | A custom auth scheme returned `$null` | Return `@{ Message = '...'; Code = 401 }` |
| Change requests stalled ~30 s | The route refreshed the snapshot inline, switching its runspace between the read-only and operator NMC accounts; the third login per minute waited on the per-runspace auth limit (2/min) | Routes set the `refresh-requested` state; only the timer refreshes, using the read-only account |
| Every form POST returns 403 in a real browser; .NET/curl clients work | Pode's `Strict` preset sets `Referrer-Policy: no-referrer`, so browsers send `Origin: null` on form navigations and the same-origin check rejected them. Found by running the live demo; the E2E tests set Origin by hand | `Set-PodeSecurityReferrerPolicy -Type Same-Origin`; the check treats `Origin: null` as absent and relies on `Sec-Fetch-Site: same-origin`. Test: `DashboardE2E` sends browser-style headers |
| Lint: unused `accessToken` / `refreshToken` / `response` / `options` | Pode's callback signatures pass more arguments than are used, and PSScriptAnalyzer **ignores** SuppressMessage on anonymous script blocks | Declare only the parameters used; the extra arguments fall into `$args` |

## Pester 6 and the tests

- **`$Host`, `$Args`, `$Input`, `$PID`:** automatic variables. Used as `-ForEach` keys they are silently read-only or overridden. The tests use `Server` and `ToolArgs` instead.
- **`<name>` in `It` titles:** treated as a data placeholder. A literal `<token>` threw "variable not set".
- **`Should -Match`:** ignores case. `'ESCROW'` matched the field *name* `escrow_passphrase` and gave a false alarm. Use `-MatchExactly` on secret values.
- **Mock bodies under strict mode:** unbound parameters such as `$BodyJson` throw. Read them with `Get-Variable -Name BodyJson -ValueOnly -ErrorAction Ignore`. `$PSBoundParameters` inside a Mock body is not the mocked command's bound parameters.
- **`BeforeEach` / `AfterEach` at file root:** rejected by Pester 6. Wrap them in a `Describe`.
- **`Export-Csv` with mixed objects:** columns come from the first object only, and later objects' extra properties are silently dropped. Select the union of property names first.
- **`timeout` command:** macOS has no `timeout`. A command line that uses it fails silently with no output.

## Platform and FIPS

- **Windows: MD5 still works in FIPS mode.** .NET (Core) on Windows does not block MD5 even with the FIPS policy on. `Test-NasuniFipsHost` therefore checks the policy registry value on Windows, and uses the MD5-refusal probe only on Linux (OpenSSL FIPS provider).
- **Cipher-suite policy is Linux-only.** `CipherSuitesPolicy` is supported only on Linux. On Windows, SChannel's FIPS policy governs which suites are allowed. The dashboard's server-side suites come from the OS policy (RHEL `update-crypto-policies --set FIPS`).
- **Private-CA certificates fail with `RevocationMode Online`.** This is by design (fail closed). If your internal CA publishes no CRL or OCSP, set `RevocationMode = 'Offline'` or `'NoCheck'` explicitly in config, and record that decision.

## Demo

- **Symptom:** after about 5 minutes, every overview section shows `Transport error: Connection refused`, then `NMC circuit breaker is open until ...`.
- **Cause:** the fake NMC used by the demo is a test helper with a 5-minute safety stop. Once it stopped listening, the dashboard behaved as designed: it opened the circuit breaker after 5 failures so a down NMC is not hammered, and showed each section's error with its correlation id.
- **Fix:** the demo starts the fake NMC with `-MaxLifetimeMinutes 0`. With a real NMC this same screen means the NMC is unreachable. Check `Test-NasuniNmcTls -ComputerName <nmc>` and `Get-NasuniDiagnostic`, which shows `CircuitOpenUntil` and the recent errors. The breaker closes after 30 s and the next refresh recovers on its own.

## Data-safety findings

- **The NMC returns secrets in clear text.** Cloud credential `secret`, `escrow_passphrase` and SNMP `v3_password` are returned as-is. Every MCP tool result, dashboard page, CSV export and audit record passes through `Protect-NasuniSensitiveData`. If a new endpoint adds a secret field under a different name, extend `Test-NmcSensitiveFieldName`.
- **CSV injection.** Values beginning with `= + - @`, tab or CR are prefixed with `'` (`ConvertTo-DashCsvSafe`).

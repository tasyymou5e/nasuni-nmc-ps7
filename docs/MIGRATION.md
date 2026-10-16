# Migrating from nasuni-api-utilities

This maps every script in [nasuni-labs/nasuni-api-utilities](https://github.com/nasuni-labs/nasuni-api-utilities) to its replacement in `Nasuni.Nmc`.

**What changes everywhere:**
- **Sign-in:** there is no token file and no hard-coded password. Run `Connect-Nasuni`, with credentials from `Get-NasuniVaultCredential` or `Get-Credential`.
- **TLS:** certificates are always validated.
- **Paging:** every list is fully paged.
- **Writes:** writes are rate-limited, retried only when that is safe, and waited to completion.

**Reports** keep the original CSV column names, so spreadsheets and the share and export import CSVs still work. Each report reads every page, quotes every value, neutralises spreadsheet formulas, redacts secrets, and writes files readable only by their owner.

```powershell
Get-NasuniReportList                                   # every report and the script it replaces
Export-NasuniReport -Name shares -Path ./shares.csv
```

**Bulk changes** all follow one workflow: build a plan (the NMC is only read), review it, dry-run it (the default), then execute. The journal makes the run resumable.

```powershell
$plan = New-NasuniSharePropertyPlan -FilerSerial NEA-NY-01 -Set @{ readonly = $true }
$plan.Items   | Format-Table Key, Summary      # what will change
$plan.Skipped | Format-Table Key, Reason       # what was left alone, and why
Invoke-NasuniBulkPlan -Plan $plan -JournalPath ./ro.jsonl              # dry run
Invoke-NasuniBulkPlan -Plan $plan -JournalPath ./ro.jsonl -Execute     # asks once, then runs
# After a failure, fix the cause and run the same command again: finished items are skipped.
Export-NasuniBulkPlan -Plan $plan -Path ./ro-plan.json                 # for approval / later
```

## API_Basics

| Script | Replacement |
|---|---|
| AllowUntrustedSSLCerts.ps1 | **Removed by design.** Use `-TrustedCaCertificatePath` for a private CA, or `-PinnedSpkiSha256` |
| GetToken.ps1, GetTokenCredPrompt.ps1 | `Connect-Nasuni -Credential (Get-Credential)`, or with `Get-NasuniVaultCredential`. The token stays in memory and is never written to a file |
| BetterErrorHandling.ps1 | Built in. Errors are `NasuniApiException`, with `StatusCode`, `Endpoint` and `CorrelationId` |

## Access_Points

| Script | Replacement |
|---|---|
| Exports/CreateExport.ps1 | `New-NasuniExport -VolumeGuid -FilerSerial -Body @{...} -Wait` |
| Exports/CreateExportHostOption.ps1 | `New-NasuniNfsHostOption ... -Wait` |
| Exports/CreateExportHostOptionsFromCSV.ps1 | `New-NasuniExportHostOptionPlan -CsvPath`. Ambiguous or unmatched exports are skipped; the original reused the previous row's export id |
| Exports/CreateExportsFromCSV.ps1 | `New-NasuniExportCreatePlan -CsvPath` (the `nfs-exports` report format) |
| Exports/ExportAllNFSExportsToCSV.ps1 | `Export-NasuniReport -Name nfs-exports` |
| Exports/UpdateAccessModeForAllExports.ps1 | `New-NasuniExportPropertyPlan -Set @{ access_mode = 'no_root_squash' }`. Exports already set are skipped |
| Exports/UpdateExport.ps1, UpdateExportHostOption.ps1 | `Set-NasuniExport`, `Set-NasuniNfsHostOption` |
| FTP_Directories/ExportAllFtpDirectoriesToCSV.ps1 | `Export-NasuniReport -Name ftp-directories` |
| Shares/CreateShare.ps1 | `New-NasuniShare -Body @{...} -Wait` |
| Shares/CreateSharesFromCSV.ps1 | `New-NasuniShareCreatePlan -CsvPath` (the `shares` report format; the body is a real object, so quotes and backslashes are safe) |
| Shares/DeleteShare.ps1 | `Remove-NasuniShare` (asks for confirmation) |
| Shares/DeleteSharesFromCSV.ps1 | `New-NasuniShareDeletePlan -CsvPath`. The share id and the name must both match before anything is deleted |
| Shares/ExportAllSharesToCSV.ps1, ListShares.ps1 | `Export-NasuniReport -Name shares` |
| Shares/ExportCifsClientsToCSV.ps1 | `Export-NasuniReport -Name cifs-clients` |
| Shares/ExportCifsLocksToCSV.ps1 | `Export-NasuniReport -Name cifs-locks [-Parameters @{ FilerSerial = '...' }]` |
| Shares/ReplicateMissingShares.ps1 | `New-NasuniShareReplicationPlan -SourceFilerSerial -DestinationFilerSerial` (compared per volume, by exact name) |
| Shares/SetBlockFilesForAllSharesOnaFiler.ps1 | `New-NasuniSharePropertyPlan -FilerSerial X -BlockFiles 'Thumbs.db','.DS_Store'` |
| Shares/SetFilerSharesToReadOnly.ps1 | `New-NasuniSharePropertyPlan -FilerSerial X -Set @{ readonly = $true }` |
| Shares/SetHideUnreadableForAllShares.ps1 | `New-NasuniSharePropertyPlan -Set @{ hide_unreadable = $true }` |
| Shares/SetMacSupportForAllShares.ps1 | `New-NasuniSharePropertyPlan -Set @{ fruit_enabled = $true }` |
| Shares/SetPreviousVersionsForAllShares.ps1 | `New-NasuniSharePropertyPlan -Set @{ enable_previous_vers = $true }` |
| Shares/UpdateSharePermissions.ps1 | `New-NasuniSharePermissionPlan -CsvPath` |

## Cyber_Resilience

| Script | Replacement |
|---|---|
| Antivirus/ExportAntivirusViolationsToCSV.ps1 | `Export-NasuniReport -Name antivirus-violations` |
| Antivirus/IgnoreOrDeleteAvViolations.ps1 | `Remove-NasuniAntivirusViolation -Action <required>` (no default; the original defaulted to deleting the file) |
| Antivirus/UpdateAllAntivirusViolations.ps1 | `New-NasuniAntivirusPlan -Action ignore_violation [-VolumeGuid] [-PathLike]`. With zero violations the plan is empty; the original sent DELETEs with empty ids |
| Ransomware/BlockIpOnAllNEAs.ps1, BlockIpOnAnNEA.ps1 | `New-NasuniClientBlockPlan -IpAddress X -Block [-FilerSerial]` |
| Ransomware/UnblockIpOnAllNEAs.ps1, UnblockIpOnAnNEA.ps1 | `New-NasuniClientBlockPlan -IpAddress X -Unblock` |
| Ransomware/DetectAndBlockIpOnAllNEAs.ps1 | `Get-NasuniRansomwareAttackIp -Minutes 5 \| New-NasuniClientBlockPlan -Block` (IPs de-duplicated, already-blocked filers skipped) |
| Ransomware/ExportBlockedIpsToCSV.ps1 | `Export-NasuniReport -Name blocked-clients` |

## Operations, Paths, Quotas

| Script | Replacement |
|---|---|
| Operations/ConcatenateNMCMessages.ps1 | Not needed: `messages` reads every page. To merge old files, use `Import-Csv a.csv, b.csv \| Sort-Object send_time -Unique` |
| Operations/DeleteSyncErrors.ps1 | `New-NasuniMessageCleanupPlan -Code <code> [-Status failure]` |
| Operations/ExportEAStatusToCSV.ps1 | `Export-NasuniReport -Name filer-status` |
| Operations/ExportEaVolumeSettings.ps1 | `Export-NasuniReportBundle -Directory ./out` (the same 10 CSVs; volume settings are read once) |
| Operations/ExportHealthToCSV.ps1 | `Export-NasuniReport -Name health` |
| Operations/ExportMessagesToCSV.ps1 | `Export-NasuniReport -Name messages` (oldest first, sorted by date) |
| Operations/ExportNotificationsToCSV.ps1 | `Export-NasuniReport -Name notifications` |
| Operations/GetMessage.ps1 | `Get-NasuniMessage -MessageId`, or `Wait-NasuniMessage` |
| Operations/ListCloudCredentials.ps1 | `Get-NasuniCloudCredentials \| Protect-NasuniSensitiveData` |
| Operations/SetEscrowPassphrase.ps1 | `Set-NasuniFiler -Body @{ settings = @{ escrow_passphrase = ... } }`. Read the value from Vault (`Get-NasuniVaultSecret`), never from the script |
| Operations/UpdateCloudCredentials.ps1 | `Set-NasuniFilerCloudCredential` (secret from Vault; bulk plans holding secrets are refused on export) |
| Operations/UploadEncryptionKey.ps1 | `Add-NasuniFilerEncryptionKey` |
| Paths/BringPathIntoCache.ps1 | `Invoke-NasuniCachePath -Wait` |
| Paths/CreateFolder.ps1 | `New-NasuniDirectoryPath -Wait` |
| Paths/SetPinning.ps1, DisablePinning.ps1 | `Set-NasuniPinnedFolder`, `Disable-NasuniPinnedFolder` |
| Paths/SetAutoCache.ps1, DisableAutoCache.ps1 | `Set-NasuniAutoCachedFolder`, `Disable-NasuniAutoCachedFolder` |
| Paths/GetPathInfo.ps1 | `Export-NasuniReport -Name path-info -Parameters @{ Paths = ... }`, or `Update-NasuniPathInfo -Wait` + `Get-NasuniPathInfo` |
| Paths/ExportAutoCacheFoldersToCSV.ps1 | `Export-NasuniReport -Name auto-cache-folders` |
| Paths/ExportPinnedFoldersToCSV.ps1 | `Export-NasuniReport -Name pinned-folders` |
| Paths/GFL/EnableGFLOnMultiplePaths.ps1, SetGFLandMode.ps1, SetGFLandModeForMultiplePaths.ps1 | `New-NasuniGlobalLockPlan -VolumeGuid -Path/-CsvPath -Mode`. Execute with `-RetryMessagePattern 'snapshot is taking place'` |
| Paths/GFL/DisableGFL.ps1, DisableGFLOnMultiplePaths.ps1 | `New-NasuniGlobalLockPlan ... -Disable`. Afterwards, `Request-NasuniSnapshot` if you want the original's post-change snapshot |
| Quotas/ExportFolderQuotasToCSV.ps1 | `Export-NasuniReport -Name folder-quotas` |
| Quotas/SetQuota.ps1 | `New-NasuniFolderQuota -Body @{ type; path; limit }` |
| Quotas/UpdateQuota.ps1 | `New-NasuniFolderQuotaPlan -VolumeGuid -Path -Limit` (an error unless exactly one quota matches) |

## Reporting_and_Chargeback, Volume_Auditing, Volumes

| Script | Replacement |
|---|---|
| CheckAllUnprotectedAndAlert.ps1 | `Test-NasuniUnprotectedDataAlert -StatePath -Days 3`. It returns the rows to alert on; send them by your own channel. The original's timer never aged, so it never alerted |
| VolumeUnprotectedDataAlert.ps1 | `Get-NasuniReport -Name unprotected-data -Parameters @{ MinBytes = 21474836480 }` |
| ShowIngestProgress.ps1 | `Export-NasuniReport -Name ingest-progress` |
| ExportVolumeDetailToCSV.ps1 | `Export-NasuniReport -Name volume-detail` |
| ExportQoSForAllFilers.ps1 | `Export-NasuniReport -Name qos` (filers without rules produce no rows) |
| CsvPathReport.ps1 | `Export-NasuniReport -Name path-info -Parameters @{ InputCsv = './paths.csv' }`. It waits on each refresh instead of sleeping 5 s. Needs a connection without `-ReadOnly` |
| ExportAllSharesAndSizes.ps1 | `Export-NasuniReport -Name shares-with-sizes` (refreshes once and polls; the original re-POSTed on every retry) |
| ExportTopLevelFolderSizesToCSV.ps1, ExportVolumeTopLevelFolderSizesToCsv.ps1, SubfolderSizeReport.ps1 | **Not ported yet.** These use the Edge Appliance Data API (`/mobileapi/1`), a separate API. Use `path-info` for known folders in the meantime |
| Volume_Auditing/ExportVolumeAuditingToCSV.ps1 | `Export-NasuniReport -Name volume-auditing` (now includes VolumeGuid) |
| Volume_Auditing/SetAuditForAllVolumesAndFilers.ps1, SetVolumeAuditing.ps1 | `New-NasuniVolumeAuditPlan -Auditing @{...}` (offline filers and matching pairs are skipped) |
| Volumes/CreateVolume.ps1 | `New-NasuniVolume -Body @{...} -Wait` |
| Volumes/ExportVolumeSnapAndSyncScheduleToCSV.ps1 | `Export-NasuniReport -Name snapshot-sync-schedule` |
| Volumes/ExportVolumesToCSV.ps1, ListVolumes.ps1 | `Export-NasuniReport -Name volumes` |
| Volumes/SetVolumeRemoteAccess.ps1 | `Set-NasuniVolume -Body @{ remote_access = @{...} } -Wait` |

## Data_API

| Script | Replacement |
|---|---|
| DataAPI-GetToken.ps1, DataAPI-ListFolderContents.ps1 | **Not ported yet** (Edge Appliance Data API, out of the NMC scope) |

## Column-name changes

The column names are the originals, with these fixes:
- **folder-quotas:** the stray space in `" VolumeGuid"` is gone.
- **volumes:** the leading spaces in `" bucket name"` and `" AV enabled"` are gone.
- **volume-detail:** the spaces after commas in the header are gone.
- **qos:** the leading space before the `Start` value is gone.
- **nfs-exports:** host options are listed as `host_option_id: …; allowed_hosts: …`, separated by ` | `. The original's `read_ondly` typo is corrected to `readonly`.
- **shares, hosts_allow:** values are `;`-separated, as before.

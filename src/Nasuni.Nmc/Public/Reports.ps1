# Named reports, ported from the nasuni-labs/nasuni-api-utilities export scripts.
# Column names match the originals so existing spreadsheets and import CSVs keep working;
# the original bugs (single page, 0..-1 loops, broken URLs, stale lookups, hand-built CSV)
# are not carried over. See docs/MIGRATION.md.
#
# DEBUG NOTE (See docs/TROUBLESHOOTING.md, "Strict mode"): optional keys are read with $p['Key'];
# $p.Key on a hashtable without that key THROWS under Set-StrictMode -Version Latest.
# DEBUG NOTE (See docs/TROUBLESHOOTING.md, "Dynamic scope"): report blocks receive everything
# through param($p). Lookups (volume/filer names) are attached to items as _volume_name /
# _filer_name before columns are built, so no column block reads an outer variable.

function Add-NmcLookupField {
    # Returns a copy of the item with _volume_name, _filer_name and _owner_serial attached.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][object]$Item, [Parameter(Mandatory)][hashtable]$Lookup,
        [string]$VolumePath = 'volume_guid', [string]$FilerPath = 'filer_serial_number')
    $o = [ordered]@{}
    if ($null -ne $Item) { foreach ($p in $Item.PSObject.Properties) { $o[$p.Name] = $p.Value } }
    $vg = [string](Get-NmcValue $Item $VolumePath)
    $fs = [string](Get-NmcValue $Item $FilerPath)
    $o['_volume_name'] = if ($vg -and $Lookup.Volumes.ContainsKey($vg)) { $Lookup.Volumes[$vg] } else { $null }
    $o['_filer_name'] = if ($fs -and $Lookup.Filers.ContainsKey($fs)) { $Lookup.Filers[$fs] } else { $null }
    $o['_owner_serial'] = if ($vg -and $Lookup.Owners.ContainsKey($vg)) { $Lookup.Owners[$vg] } else { $null }
    [pscustomobject]$o
}

function Get-NmcVolumeFilerItem {
    <#
    .SYNOPSIS
        Every volume x connected-filer settings entry (GET /volumes/{guid}/filers/, all pages),
        with _volume_name, _filer_name and _volume_guid attached. Cached in $Cache when given,
        so a report bundle reads it once.
    #>
    [CmdletBinding()]
    param([hashtable]$Cache)
    # DEBUG NOTE (See docs/TROUBLESHOOTING.md, "Array wrapping"): return the array plainly (no leading
    # comma); callers wrap with @(). Returning , $result made every caller see ONE row.
    if ($Cache -and $Cache.ContainsKey('VolumeFilers')) { return $Cache.VolumeFilers }
    $lookup = if ($Cache -and $Cache.ContainsKey('Lookup')) { $Cache.Lookup } else { Get-NmcNameLookup }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($vg in @($lookup.Volumes.Keys | Sort-Object)) {
        foreach ($vf in @(Get-NasuniVolumeFilerSettingsList -VolumeGuid $vg)) {
            $o = Add-NmcLookupField -Item $vf -Lookup $lookup -VolumePath '_none' -FilerPath 'filer_serial_number'
            $o._volume_name = $lookup.Volumes[$vg]
            $o | Add-Member -NotePropertyName '_volume_guid' -NotePropertyValue $vg -Force
            $items.Add($o)
        }
    }
    $result = $items.ToArray()
    if ($Cache) { $Cache.Lookup = $lookup; $Cache.VolumeFilers = $result }
    $result
}

function Get-NmcFreshPathInfo {
    <#
    .SYNOPSIS
        Refreshes path info (POST, waited to completion) then reads it (GET). Root paths ('/')
        are supported. Needs a connection without -ReadOnly: the refresh is a POST.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VolumeGuid, [Parameter(Mandatory)][string]$FilerSerial, [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [ValidateRange(5, 3600)][int]$TimeoutSeconds = 300)
    $segments = @($Path.Replace('\', '/').Trim('/') -split '/' | Where-Object { $_ -ne '' })
    if ($segments -contains '.' -or $segments -contains '..') { throw "Path '$Path' may not contain '.' or '..'." }
    $rel = '/volumes/{0}/filers/{1}/path/{2}' -f [uri]::EscapeDataString($VolumeGuid), [uri]::EscapeDataString($FilerSerial),
    (($segments | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    $refresh = Invoke-NmcRequest -Method POST -Path $rel -IncludeStatus
    $msg = if ($null -ne $refresh.Data) { $refresh.Data } else { [pscustomobject]@{ Location = $refresh.Location } }
    $null = $msg | Wait-NasuniMessage -TimeoutSeconds $TimeoutSeconds
    Invoke-NmcRequest -Method GET -Path $rel
}

$script:PathInfoColumns = [ordered]@{
    cache_resident = 'cache_resident'; protected = 'protected'; owner = 'owner'; size = 'size'
    pinning_enabled = 'pinning_enabled'; pinning_mode = 'pinning_mode'; pinning_inherited = 'pinning_inherited'
    autocache_enabled = 'autocache_enabled'; autocache_mode = 'autocache_mode'; autocache_inherited = 'autocache_inherited'
    quota_enabled = 'quota_enabled'; quota_type = 'quota_type'; quota_email = 'quota_email'; quota_usage = 'quota_usage'
    quota_limit = 'quota_limit'; quota_inherited = 'quota_inherited'; global_locking_enabled = 'global_locking_enabled'
    global_locking_inherited = 'global_locking_inherited'; global_locking_mode = 'global_locking_mode'
}

function Merge-NmcColumn {
    # Concatenates ordered column maps; -Prefix rewrites string paths (e.g. '_info.').
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$First,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Second, [string]$Prefix = '')
    $m = [ordered]@{}
    foreach ($k in $First.Keys) { $m[$k] = $First[$k] }
    foreach ($k in $Second.Keys) { $m[$k] = if ($Second[$k] -is [string]) { "$Prefix$($Second[$k])" } else { $Second[$k] } }
    $m
}

function Get-NmcReportDefinition {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $shareCols = [ordered]@{
        shareid = 'id'; Volume_GUID = 'volume_guid'; volume_name = '_volume_name'; filer_serial_number = 'filer_serial_number'; filer_name = '_filer_name'
        share_name = 'name'; path = 'path'; comment = 'comment'; readonly = 'readonly'; browseable = 'browseable'
        authAuthall = 'auth.authall'; authRo_users = 'auth.ro_users'; authRw_users = 'auth.rw_users'; authDeny_users = 'auth.deny_users'
        authRo_groups = 'auth.ro_groups'; authRw_groups = 'auth.rw_groups'; authDeny_groups = 'auth.deny_groups'
        hosts_allow = { param($i) ([string](Get-NmcValue $i 'hosts_allow')).Trim() -replace '\s+', ';' }
        hide_unreadable = 'hide_unreadable'; enable_previous_vers = 'enable_previous_vers'; case_sensitive = 'case_sensitive'
        enable_snapshot_dirs = 'enable_snapshot_dirs'; homedir_support = 'homedir_support'; mobile = 'mobile'; browser_access = 'browser_access'
        aio_enabled = 'aio_enabled'; veto_files = { param($i) ([string](Get-NmcValue $i 'veto_files')) -replace "`r?`n", ';' }
        fruit_enabled = 'fruit_enabled'; smb_encrypt = 'smb_encrypt'
        shared_links_enabled = 'browser_access_settings.shared_links_enabled'; link_force_password = 'browser_access_settings.link_force_password'
        link_allow_rw = 'browser_access_settings.link_allow_rw'; external_share_url = 'browser_access_settings.external_share_url'
        link_expire_limit = 'browser_access_settings.link_expire_limit'; link_authAuthall = 'browser_access_settings.link_auth.authall'
        link_authAllow_groups_ro = 'browser_access_settings.link_auth.allow_groups_ro'; link_authAllow_groups_rw = 'browser_access_settings.link_auth.allow_groups_rw'
        link_authDeny_groups = 'browser_access_settings.link_auth.deny_groups'; link_authAllow_users_ro = 'browser_access_settings.link_auth.allow_users_ro'
        link_authAllow_users_rw = 'browser_access_settings.link_auth.allow_users_rw'; link_authDeny_users = 'browser_access_settings.link_auth.deny_users'
    }
    $auditCols = [ordered]@{
        VolumeName = '_volume_name'; FilerName = '_filer_name'; VolumeGuid = '_volume_guid'; FilerSerialNumber = 'filer_serial_number'
        AuditingEnabled = 'auditing.enabled'; Create = 'auditing.events.create'; Delete = 'auditing.events.delete'; Rename = 'auditing.events.rename'
        Close = 'auditing.events.close'; Security = 'auditing.events.security'; Metadata = 'auditing.events.metadata'; Write = 'auditing.events.write'
        Read = 'auditing.events.read'; PruneAuditLogs = 'auditing.logs.prune_audit_logs'; DaysToKeep = 'auditing.logs.days_to_keep'
        ExcludeByDefault = 'auditing.logs.exclude_by_default'; IncludeTakesPriority = 'auditing.logs.include_takes_priority'
        IncludePatterns = 'auditing.logs.include_patterns'; ExcludePatterns = 'auditing.logs.exclude_patterns'
        SyslogExportEnabled = { param($i) $v = Get-NmcValue $i 'auditing.syslog_export'; if ($null -eq $v) { Get-NmcValue $i 'auditing.logs.syslog_export' } else { $v } }
    }
    $days = 'mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'
    $schedCols = [ordered]@{ VolumeName = '_volume_name'; FilerName = '_filer_name'; VolumeGuid = '_volume_guid'; FilerSerialNumber = 'filer_serial_number' }
    foreach ($d in $days) { $schedCols["SnapSched$((Get-Culture).TextInfo.ToTitleCase($d))"] = "snapshot_schedule.days.$d" }
    foreach ($k in 'allday', 'start', 'stop', 'frequency') { $schedCols["SnapSched$((Get-Culture).TextInfo.ToTitleCase($k))"] = "snapshot_schedule.$k" }
    foreach ($d in $days) { $schedCols["SyncSched$((Get-Culture).TextInfo.ToTitleCase($d))"] = "sync_schedule.days.$d" }
    foreach ($k in 'allday', 'start', 'stop', 'frequency') { $schedCols["SyncSched$((Get-Culture).TextInfo.ToTitleCase($k))"] = "sync_schedule.$k" }
    $schedCols['SyncSchedAutocacheAllowed'] = 'sync_schedule.auto_cache_allowed'
    $schedCols['SyncSchedAutocacheMinFileSize'] = 'sync_schedule.auto_cache_min_file_size'

    [ordered]@{
        'shares'                 = @{ Source = 'Access_Points/Shares/ExportAllSharesToCSV.ps1, ListShares.ps1'; Description = 'All SMB shares with permissions and settings (also the input format for the share bulk plans)'
            Rows = { param($p) $lk = Get-NmcNameLookup; foreach ($s in @(Get-NasuniShares)) { ConvertTo-NmcReportRow -Item (Add-NmcLookupField -Item $s -Lookup $lk) -Columns $p.__cols } }; Columns = $shareCols
        }
        'nfs-exports'            = @{ Source = 'Access_Points/Exports/ExportAllNFSExportsToCSV.ps1'; Description = 'All NFS exports with host options'
            Columns = [ordered]@{ exportId = 'id'; Volume_GUID = 'volume_guid'; filer_serial_number = 'filer_serial_number'; export_name = 'name'; path = 'path'; comment = 'comment'
                readonly = 'readonly'; allowed_hosts = 'hostspec'; access_mode = 'access_mode'; perf_mode = 'perf_mode'; sec_options = 'sec_options'
                nfs_host_options = { param($i) (@(Get-NmcValue $i 'nfs_host_options') | Where-Object { $null -ne $_ } | ForEach-Object {
                            'host_option_id: {0}; allowed_hosts: {1}; access_mode: {2}; readonly: {3}; sec_options: {4}; perf_mode: {5}' -f (Get-NmcValue $_ 'id'), (Get-NmcValue $_ 'hostspec'),
                            (Get-NmcValue $_ 'access_mode'), (Get-NmcValue $_ 'readonly'), ((@(Get-NmcValue $_ 'sec_options')) -join ' '), (Get-NmcValue $_ 'perf_mode') }) -join ' | ' }
            }
            Rows = { param($p) foreach ($e in @(Get-NasuniExports)) { ConvertTo-NmcReportRow -Item $e -Columns $p.__cols } }
        }
        'ftp-directories'        = @{ Source = 'Access_Points/FTP_Directories/ExportAllFtpDirectoriesToCSV.ps1'; Description = 'All FTP directories and settings'
            Columns = [ordered]@{ FtpId = 'id'; Volume_GUID = 'volume_guid'; filer_serial_number = 'filer_serial_number'; ftp_name = 'name'; path = 'path'; comment = 'comment'
                readonly = 'readonly'; visibility = 'visibility'; ip_restrictions = 'allow_from'; allowed_users = 'allow_users'; allowed_groups = 'allow_groups'
                allow_anonymous = 'anonymous'; anonymous_only = 'anonymous_only'; Permissions_on_new_files = 'umask'; hide_ownership = 'hide_ownership'
                use_temporary_files_during_upload = 'hidden_stores'
            }
            Rows = { param($p) foreach ($x in @(Get-NasuniFtpDirectories)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'cifs-clients'           = @{ Source = 'Access_Points/Shares/ExportCifsClientsToCSV.ps1'; Description = 'Connected SMB clients on all filers'
            Columns = [ordered]@{ filer_serial_number = 'filer_serial_number'; user = 'user'; client_name = 'client_name'; clientIP = 'client'; shareID = 'share_id' }
            Rows = { param($p) foreach ($x in @(Get-NasuniCifsClients)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'cifs-locks'             = @{ Source = 'Access_Points/Shares/ExportCifsLocksToCSV.ps1'; Description = 'SMB file locks (all filers, or -Parameters @{ FilerSerial = ... })'; Parameters = @('FilerSerial')
            Columns = [ordered]@{ filer_serial_number = 'filer_serial_number'; type = 'type'; ip_address = 'client'; hostname = 'client_name'; share_id = 'share_id'; path = 'path'; user = 'user' }
            Rows = { param($p)
                $locks = if ($p['FilerSerial']) { @(Get-NasuniFilerCifsLocks -FilerSerial $p['FilerSerial']) } else { @(Get-NasuniCifsLocks) }
                foreach ($x in $locks) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'antivirus-violations'   = @{ Source = 'Cyber_Resilience/Antivirus/ExportAntivirusViolationsToCSV.ps1'; Description = 'Antivirus violations with volume and filer names'
            Columns = [ordered]@{ VolumeName = '_volume_name'; VolumeGUID = 'volume_guid'; FilerName = '_filer_name'; FilerSerial = 'filer_serial_number'; VirusName = 'vname'; VirusPath = 'fpath'; ViolationID = 'id' }
            Rows = { param($p) $lk = Get-NmcNameLookup; foreach ($x in @(Get-NasuniAntivirusViolations)) { ConvertTo-NmcReportRow -Item (Add-NmcLookupField -Item $x -Lookup $lk) -Columns $p.__cols } }
        }
        'blocked-clients'        = @{ Source = 'Cyber_Resilience/Ransomware/ExportBlockedIpsToCSV.ps1'; Description = 'IP addresses blocked on filers'
            Columns = [ordered]@{ ipAddress = 'ip_address'; filerSerialNumber = 'filer_serial_number'; blockedDate = 'blocked_date'; blockedByUsername = 'blocked_by_username' }
            Rows = { param($p) foreach ($x in @(Get-NasuniBlockedClients)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'filer-status'           = @{ Source = 'Operations/ExportEAStatusToCSV.ps1'; Description = 'Edge Appliance status, platform, cache, network and remote support'
            Columns = [ordered]@{ Description = 'description'; SerialNumber = 'serial_number'; GUID = 'guid'; build = 'build'
                cpuCores = 'status.platform.cpu.cores'; cpuModel = 'status.platform.cpu.model'; cpuFrequency = 'status.platform.cpu.frequency'; cpuSockets = 'status.platform.cpu.sockets'
                Memory = 'status.platform.memory'; ManagementState = 'management_state'; Offline = 'status.offline'; OsVersion = 'status.osversion'; Uptime = 'status.uptime'
                UpdatesAvailable = 'status.updates.updates_available'; CurrentVersion = 'status.updates.current_version'; NewVersion = 'status.updates.new_version'
                PlatformName = 'status.platform.platform_name'; cacheSize = 'status.platform.cache_status.size'; cacheUsed = 'status.platform.cache_status.used'
                cacheDirty = 'status.platform.cache_status.dirty'; cacheFree = 'status.platform.cache_status.free'; cachePercentUsed = 'status.platform.cache_status.percent_used'
                Hostname = 'settings.network_settings.hostname'; DefaultGateway = 'settings.network_settings.default_gateway'; IpAddresses = 'settings.network_settings.ip_addresses'
                DnsServers = 'settings.network_settings.dns_servers'; SearchDomains = 'settings.network_settings.search_domains'
                RemoteSupportConnected = 'settings.remote_support.connected'; RemoteSupportRunning = 'settings.remote_support.running'
                RemoteSupportEnabled = 'settings.remote_support.enabled'; RemoteSupportTimeout = 'settings.remote_support.timeout'
            }
            Rows = { param($p) foreach ($x in @(Get-NasuniFilers)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'health'                 = @{ Source = 'Operations/ExportHealthToCSV.ps1'; Description = 'Health of every Edge Appliance'
            Columns = [ordered]@{ filer_serial_number = 'filer_serial_number'; filer_name = '_filer_name'; last_updated = 'last_updated'; network = 'network'; filesystem = 'filesystem'
                cpu = 'cpu'; nfs = 'nfs'; memory = 'memory'; services = 'services'; directoryservices = 'directoryservices'; disk = 'disk'; smb = 'smb'
            }
            Rows = { param($p) $lk = Get-NmcNameLookup; foreach ($x in @(Get-NasuniFilerHealthList)) { ConvertTo-NmcReportRow -Item (Add-NmcLookupField -Item $x -Lookup $lk) -Columns $p.__cols } }
        }
        'messages'               = @{ Source = 'Operations/ExportMessagesToCSV.ps1'; Description = 'NMC messages, oldest first'
            Columns = [ordered]@{ id = 'id'; filer_serial_number = 'filer_serial_number'; description = 'description'; code = 'code'; status = 'status'; send_time = 'send_time'
                expiration_time = 'expiration_time'; response_time = 'response_time'; initiated_by = 'initiated_by'; applied_resource_href = 'links.applied_resource.href'
            }
            Rows = { param($p)
                $parse = { param($s) $d = [datetimeoffset]::MinValue; if ([datetimeoffset]::TryParse([string]$s, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { $d } else { [datetimeoffset]::MinValue } }
                foreach ($x in @(Get-NasuniMessages | Sort-Object { & $parse (Get-NmcValue $_ 'send_time') })) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'notifications'          = @{ Source = 'Operations/ExportNotificationsToCSV.ps1'; Description = 'NMC notifications'
            Columns = [ordered]@{ id = 'id'; date = 'date'; priority = 'priority'; name = 'name'; message = 'message'; group = 'group'; acknowledged = 'acknowledged'; sticky = 'sticky'; urgent = 'urgent'; origin = 'origin' }
            Rows = { param($p) foreach ($x in @(Get-NasuniNotifications)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'auto-cache-folders'     = @{ Source = 'Paths/ExportAutoCacheFoldersToCSV.ps1'; Description = 'Auto-cached folders'
            Columns = [ordered]@{ volume_guid = 'volume_guid'; filer_serial_number = 'filer_serial_number'; path = 'path'; 'autocache mode' = 'mode' }
            Rows = { param($p) foreach ($x in @(Get-NasuniAutoCachedFolders)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'pinned-folders'         = @{ Source = 'Paths/ExportPinnedFoldersToCSV.ps1'; Description = 'Pinned folders'
            Columns = [ordered]@{ volume_guid = 'volume_guid'; filer_serial_number = 'filer_serial_number'; path = 'path'; 'pinning mode' = 'mode' }
            Rows = { param($p) foreach ($x in @(Get-NasuniPinnedFolders)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'folder-quotas'          = @{ Source = 'Quotas/ExportFolderQuotasToCSV.ps1'; Description = 'Folder quotas and rules'
            Columns = [ordered]@{ 'Quota ID' = 'id'; VolumeGuid = 'volume_guid'; FilerSerial = 'filer_serial_number'; Path = 'path'; 'Quota Type' = 'type'; 'Quota Limit' = 'limit'; 'Quota Usage' = 'usage'; Email = 'email' }
            Rows = { param($p) foreach ($x in @(Get-NasuniFolderQuotas)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'qos'                    = @{ Source = 'Reporting_and_Chargeback/ExportQoSForAllFilers.ps1'; Description = 'QoS rules of NMC-managed filers (one row per rule)'
            Columns = [ordered]@{ 'Filer Name' = 'description'; 'Filer Serial' = 'serial_number'; Sunday = 'rule.days.sun'; Monday = 'rule.days.mon'; Tuesday = 'rule.days.tue'
                Wednesday = 'rule.days.wed'; Thursday = 'rule.days.thu'; Friday = 'rule.days.fri'; Saturday = 'rule.days.sat'; Start = 'rule.start'; Stop = 'rule.stop'
                Ingress_Limit = 'rule.ingress_limit'; Limit = 'rule.limit'
            }
            Rows = { param($p)
                foreach ($f in @(Get-NasuniFilers | Where-Object { (Get-NmcValue $_ 'management_state') -eq 'nmc' })) {
                    foreach ($r in @(Get-NmcValue $f 'settings.qos.rules') | Where-Object { $null -ne $_ }) {
                        ConvertTo-NmcReportRow -Item ([pscustomobject]@{ description = (Get-NmcValue $f 'description'); serial_number = (Get-NmcValue $f 'serial_number'); rule = $r }) -Columns $p.__cols
                    }
                } }
        }
        'volumes'                = @{ Source = 'Volumes/ExportVolumesToCSV.ps1, ListVolumes.ps1'; Description = 'All volumes and settings'
            Columns = [ordered]@{ name = 'name'; guid = 'guid'; filer_serial_number = 'filer_serial_number'; 'case sensitive' = 'case_sensitive'
                'permissions policy' = 'protocols.permissions_policy'; protocols = 'protocols.protocols'; 'remote access' = 'remote_access.enabled'
                'remote access permissions' = 'remote_access.access_permissions'; 'snapshot retention' = 'snapshot_retention.retain'; quota = 'quota'
                compression = 'cloud_io.compression'; chunk_size = 'cloud_io.chunk_size'; 'authenticated access' = 'auth.authenticated_access'; 'auth policy' = 'auth.policy'
                'auth policy label' = 'auth.policy_label'; 'provider name' = 'provider.name'; 'provider shortname' = 'provider.shortname'; 'provider location' = 'provider.location'
                'provider storage class' = 'provider.storage_class'; 'bucket name' = 'bucket'; 'AV enabled' = 'antivirus_service.enabled'
                'AV days' = { param($i) if ((Get-NmcValue $i 'antivirus_service.enabled') -eq $true) { (('sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat') | ForEach-Object { "${_}:$(Get-NmcValue $i "antivirus_service.days.$_")" }) -join '; ' } }
                'AV check immediately' = 'antivirus_service.check_files_immediately'; 'AV allday' = 'antivirus_service.allday'; 'AV start' = 'antivirus_service.start'
                'AV stop' = 'antivirus_service.stop'; 'AV frequency' = 'antivirus_service.frequency'
            }
            Rows = { param($p) foreach ($x in @(Get-NasuniVolumes)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'volume-detail'          = @{ Source = 'Reporting_and_Chargeback/ExportVolumeDetailToCSV.ps1'; Description = 'Volume size (accessible data) at the owning filer'
            Columns = [ordered]@{ volume_name = '_volume_name'; volume_guid = '_volume_guid'; filer_description = '_filer_name'; filer_serial_number = 'filer_serial_number'
                'accessible data' = 'status.accessible_data'; provider = '_provider'
            }
            Rows = { param($p)
                $lk = Get-NmcNameLookup
                foreach ($v in @(Get-NasuniVolumes)) {
                    $owner = [string](Get-NmcValue $v 'filer_serial_number'); $vg = [string](Get-NmcValue $v 'guid')
                    if (-not $owner -or -not $vg) { continue }
                    $vf = Add-NmcLookupField -Item (Get-NasuniVolumeFilerSettings -VolumeGuid $vg -FilerSerial $owner) -Lookup $lk -VolumePath '_none'
                    $vf._volume_name = $lk.Volumes[$vg]
                    $vf | Add-Member -NotePropertyName _volume_guid -NotePropertyValue $vg -Force
                    $vf | Add-Member -NotePropertyName _provider -NotePropertyValue (Get-NmcValue $v 'provider.name') -Force
                    ConvertTo-NmcReportRow -Item $vf -Columns $p.__cols
                } }
        }
        'volume-auditing'        = @{ Source = 'Volume_Auditing/ExportVolumeAuditingToCSV.ps1'; Description = 'Audit settings per volume and filer'; Columns = $auditCols
            Rows = { param($p) foreach ($x in @(Get-NmcVolumeFilerItem -Cache $p.__cache)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'snapshot-sync-schedule' = @{ Source = 'Volumes/ExportVolumeSnapAndSyncScheduleToCSV.ps1'; Description = 'Snapshot and sync schedules per volume and filer'; Columns = $schedCols
            Rows = { param($p) foreach ($x in @(Get-NmcVolumeFilerItem -Cache $p.__cache)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'file-alerts'            = @{ Source = 'Operations/ExportEaVolumeSettings.ps1 (FileAlertService.csv)'; Description = 'File alert service per volume and filer'
            Columns = [ordered]@{ VolumeName = '_volume_name'; FilerName = '_filer_name'; 'Volume GUID' = '_volume_guid'; FilerSerialNumber = 'filer_serial_number'
                'File Alerts Enabled' = 'file_alerts_service.enabled'; 'File Alert Patterns' = 'file_alerts_service.patterns'
            }
            Rows = { param($p) foreach ($x in @(Get-NmcVolumeFilerItem -Cache $p.__cache)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        'snapshot-access'        = @{ Source = 'Operations/ExportEaVolumeSettings.ps1 (SnapshotDirAccess.csv)'; Description = 'Snapshot directory access per volume and filer'
            Columns = [ordered]@{ VolumeName = '_volume_name'; FilerName = '_filer_name'; 'Volume GUID' = '_volume_guid'; FilerSerialNumber = 'filer_serial_number'; 'Snapshot Access Enabled' = 'snapshot_access' }
            Rows = { param($p) foreach ($x in @(Get-NmcVolumeFilerItem -Cache $p.__cache)) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols } }
        }
        # TODO(roadmap#1): status.* field names are not in the published spec. Verify against a real NMC.
        'ingest-progress'        = @{ Source = 'Reporting_and_Chargeback/ShowIngestProgress.ps1'; Description = 'Data growth, unprotected data and last snapshot per volume and filer'
            Columns = [ordered]@{ volume_name = '_volume_name'; volume_guid = '_volume_guid'; filer_description = '_filer_name'; filer_serial_number = 'filer_serial_number'
                'accessible data' = 'status.accessible_data'; 'unprotected data' = 'status.data_not_yet_protected'; last_snapshot_time = 'status.last_snapshot'
                last_snapshot_version = 'status.last_snapshot_version'; snapshot_status = '_detail.status.snapshot_status'; snapshot_percent = '_detail.status.snapshot_percent'
            }
            Rows = { param($p)
                foreach ($x in @(Get-NmcVolumeFilerItem -Cache $p.__cache)) {
                    $detail = Get-NasuniVolumeFilerSettings -VolumeGuid $x._volume_guid -FilerSerial ([string](Get-NmcValue $x 'filer_serial_number'))
                    $x | Add-Member -NotePropertyName _detail -NotePropertyValue $detail -Force
                    ConvertTo-NmcReportRow -Item $x -Columns $p.__cols
                } }
        }
        'unprotected-data'       = @{ Source = 'Reporting_and_Chargeback/VolumeUnprotectedDataAlert.ps1, CheckAllUnprotectedAndAlert.ps1'; Description = 'Data not yet protected in the cloud, per volume and filer (-Parameters @{ MinBytes = 21474836480 })'; Parameters = @('MinBytes')
            Columns = [ordered]@{ filer_description = '_filer_name'; filer_serial_number = 'filer_serial_number'; volume_name = '_volume_name'; volume_guid = '_volume_guid'; unprotected_data = 'status.data_not_yet_protected' }
            Rows = { param($p)
                $min = if ($p['MinBytes']) { [long]$p['MinBytes'] } else { [long]0 }
                foreach ($x in @(Get-NmcVolumeFilerItem -Cache $p.__cache)) {
                    $u = Get-NmcValue $x 'status.data_not_yet_protected'
                    if ($null -ne $u -and [long]$u -ge $min) { ConvertTo-NmcReportRow -Item $x -Columns $p.__cols }
                } }
        }
        # TODO(roadmap#7): the Edge Data API size reports (TopLevelFolderSizes, SubfolderSize) are not ported; path-info is the stopgap.
        'path-info'              = @{ Source = 'Reporting_and_Chargeback/CsvPathReport.ps1, Paths/GetPathInfo.ps1'; Description = 'Refreshed path info (size, cache, pinning, quota, GFL) for listed paths. Needs a non-read-only connection. -Parameters @{ InputCsv = "file with Volume_GUID,filer_serial_number,path" }'; Parameters = @('InputCsv', 'Paths')
            Columns = (Merge-NmcColumn -First ([ordered]@{ volume_name = '_volume_name'; volume_guid = '_vg'; filer_name = '_filer_name'; filer_serial = '_fs'; path = '_path' }) -Second $script:PathInfoColumns)
            Rows = { param($p)
                $lk = Get-NmcNameLookup
                $inputRows = if ($p['InputCsv']) { @(Import-Csv -LiteralPath $p['InputCsv']) } else { @($p['Paths']) }
                foreach ($r in $inputRows) {
                    $vg = [string](Get-NmcValue $r 'Volume_GUID'); if (-not $vg) { $vg = [string](Get-NmcValue $r 'volume_guid') }
                    $fs = [string](Get-NmcValue $r 'filer_serial_number'); $path = [string](Get-NmcValue $r 'path')
                    if (-not $vg -or -not $fs -or -not $path) { Write-Warning "Skipping input row with a missing volume, filer or path."; continue }
                    $info = Get-NmcFreshPathInfo -VolumeGuid $vg -FilerSerial $fs -Path $path
                    $o = Add-NmcLookupField -Item $info -Lookup $lk -VolumePath '_none' -FilerPath '_none'
                    $o._volume_name = $lk.Volumes[$vg]; $o._filer_name = $lk.Filers[$fs]
                    foreach ($kv in @{ _vg = $vg; _fs = $fs; _path = $path }.GetEnumerator()) { $o | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value -Force }
                    ConvertTo-NmcReportRow -Item $o -Columns $p.__cols
                } }
        }
        'shares-with-sizes'      = @{ Source = 'Reporting_and_Chargeback/ExportAllSharesAndSizes.ps1'; Description = 'Every share with refreshed path info (size etc.). Needs a non-read-only connection.'
            Columns = (Merge-NmcColumn -First ([ordered]@{ shareid = 'id'; volume_name = '_volume_name'; volume_guid = 'volume_guid'; filer_name = '_filer_name'; filer_serial = 'filer_serial_number'; share_name = 'name'; path = 'path'; comment = 'comment' }) -Second $script:PathInfoColumns -Prefix '_info.')
            Rows = { param($p)
                $lk = Get-NmcNameLookup
                foreach ($s in @(Get-NasuniShares)) {
                    $o = Add-NmcLookupField -Item $s -Lookup $lk
                    try { $info = Get-NmcFreshPathInfo -VolumeGuid ([string](Get-NmcValue $s 'volume_guid')) -FilerSerial ([string](Get-NmcValue $s 'filer_serial_number')) -Path ([string](Get-NmcValue $s 'path')) }
                    catch { Write-Warning "Path info failed for share $(Get-NmcValue $s 'name'): $(Protect-NmcText -Text $_.Exception.Message)"; $info = $null }
                    $o | Add-Member -NotePropertyName _info -NotePropertyValue $info -Force
                    ConvertTo-NmcReportRow -Item $o -Columns $p.__cols
                } }
        }
    }
}

function Get-NasuniReportList {
    <#
    .SYNOPSIS
        Lists the available reports, the original script each replaces, and their parameters.
    .EXAMPLE
        Get-NasuniReportList | Format-Table Name, Description
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $defs = Get-NmcReportDefinition
    foreach ($n in $defs.Keys) {
        [pscustomobject]@{ Name = $n; Description = $defs[$n].Description; ReplacesScript = $defs[$n].Source; Parameters = @($defs[$n]['Parameters'] | Where-Object { $_ }) -join ', '; Columns = @($defs[$n].Columns.Keys) -join ', ' }
    }
}

function Get-NasuniReport {
    <#
    .SYNOPSIS
        Runs a named report and returns its rows (secrets redacted). Every page is read.
    .PARAMETER Name
        A report name from Get-NasuniReportList, for example 'shares' or 'filer-status'.
    .PARAMETER Parameters
        Report-specific options, for example @{ FilerSerial = 'ABC' } for 'cifs-locks'.
    .EXAMPLE
        Get-NasuniReport -Name shares | Where-Object readonly -eq $false
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Parameters = @{},
        [hashtable]$Cache
    )
    $defs = Get-NmcReportDefinition
    if (-not $defs.Contains($Name)) { throw "Unknown report '$Name'. Run Get-NasuniReportList." }
    $def = $defs[$Name]
    $allowed = @($def['Parameters'] | Where-Object { $_ })
    foreach ($k in $Parameters.Keys) { if ($k -notin $allowed) { throw "Report '$Name' does not take parameter '$k'. Allowed: $($allowed -join ', ')" } }
    $p = @{} + $Parameters
    $p.__cols = $def.Columns
    $p.__cache = if ($Cache) { $Cache } else { @{} }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-NmcLog -Level Debug -Message 'Report start' -Data @{ report = $Name; parameters = (@($Parameters.Keys) -join ',') }
    try { $rows = @(& $def.Rows $p) }
    catch {
        Write-NmcLog -Level Error -Message 'Report failed' -Data @{ report = $Name; ms = $sw.ElapsedMilliseconds; error = (Protect-NmcText -Text $_.Exception.Message) }
        throw
    }
    Write-NmcLog -Level Info -Message 'Report finished' -Data @{ report = $Name; rows = $rows.Count; ms = $sw.ElapsedMilliseconds }
    $safe = Protect-NasuniSensitiveData -InputObject $rows
    foreach ($r in @($safe)) { $r }
}

function Export-NasuniReport {
    <#
    .SYNOPSIS
        Writes a named report to CSV: every value quoted, spreadsheet formulas neutralised,
        secrets redacted, and the file readable only by its owner (on Linux and macOS).
    .EXAMPLE
        Export-NasuniReport -Name shares -Path ./shares.csv
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Parameters = @{},
        [hashtable]$Cache
    )
    $rows = @(Get-NasuniReport -Name $Name -Parameters $Parameters -Cache $Cache)
    if (-not $PSCmdlet.ShouldProcess($Path, "Write report '$Name' ($($rows.Count) rows)")) { return }
    $columns = @((Get-NmcReportDefinition)[$Name].Columns.Keys)
    $safe = foreach ($r in $rows) {
        $o = [ordered]@{}
        foreach ($c in $columns) { $o[$c] = ConvertTo-NasuniCsvSafeValue -Value (Get-NmcValue $r $c) }
        [pscustomobject]$o
    }
    $lines = if ($rows.Count) { @($safe | ConvertTo-Csv -NoTypeInformation -UseQuotes Always) }
    else { @((@($columns | ForEach-Object { '"' + $_.Replace('"', '""') + '"' })) -join ',') }
    [System.IO.File]::WriteAllText($Path, ($lines -join "`r`n") + "`r`n", [System.Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite') }
    [pscustomobject]@{ Report = $Name; Path = (Resolve-Path -LiteralPath $Path).Path; Rows = $rows.Count }
}

function Export-NasuniReportBundle {
    <#
    .SYNOPSIS
        Writes several reports into one directory and reads the shared data once.
    .DESCRIPTION
        By default it writes the set that ExportEaVolumeSettings.ps1 produced: shares,
        nfs-exports, ftp-directories, volume-auditing, snapshot-sync-schedule, folder-quotas,
        pinned-folders, auto-cache-folders, file-alerts and snapshot-access.
    .EXAMPLE
        Export-NasuniReportBundle -Directory ./ea-settings
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string[]]$Name = @('shares', 'nfs-exports', 'ftp-directories', 'volume-auditing', 'snapshot-sync-schedule', 'folder-quotas', 'pinned-folders', 'auto-cache-folders', 'file-alerts', 'snapshot-access')
    )
    if (-not $PSCmdlet.ShouldProcess($Directory, "Write $($Name.Count) reports")) { return }
    if (-not (Test-Path -LiteralPath $Directory)) { $null = New-Item -ItemType Directory -Path $Directory }
    $cache = @{}
    foreach ($n in $Name) { Export-NasuniReport -Name $n -Path (Join-Path -Path $Directory -ChildPath "$n.csv") -Cache $cache -Confirm:$false }
}

# Bulk plan builders: ports of the nasuni-labs bulk-change scripts onto the plan engine.
# Builders only READ the NMC; they return a plan to review, save, dry-run and execute with
# Invoke-NasuniBulkPlan. Items already in the desired state are skipped with a reason.
# See docs/MIGRATION.md for the script-to-function map.

function ConvertTo-NmcBoolValue {
    # 'true'/'false' (any case) or a real bool; empty -> default; anything else throws.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Value, [Parameter(Mandatory)][bool]$Default, [string]$Field = 'value')
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
    if ($Value -is [bool]) { return $Value }
    switch -Regex ([string]$Value) { '^(?i)true$' { return $true } '^(?i)false$' { return $false } }
    throw "Field '$Field' must be true or false, got '$Value'."
}

function Split-NmcList {
    # ';'-separated cell -> trimmed, non-empty array.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return , @() }
    , @(([string]$Value) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function New-NmcSkip {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a record object only')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Reason)
    [pscustomobject]@{ Key = $Key; Reason = $Reason }
}

function Test-NmcValueEqual {
    # Compares a desired value with the current one (bools/strings case-insensitively, arrays by content).
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Current, [AllowNull()][object]$Desired)
    if ($Desired -is [System.Collections.IEnumerable] -and $Desired -isnot [string]) {
        return ((@($Current) | ForEach-Object { [string]$_ }) -join "`n") -eq ((@($Desired) | ForEach-Object { [string]$_ }) -join "`n")
    }
    [string]$Current -eq [string]$Desired
}

$script:ShareSettableFields = @('readonly', 'browseable', 'hosts_allow', 'hide_unreadable', 'enable_previous_vers', 'case_sensitive', 'enable_snapshot_dirs',
    'homedir_support', 'mobile', 'browser_access', 'aio_enabled', 'veto_files', 'fruit_enabled', 'smb_encrypt', 'comment', 'agl_oplocks')

function New-NasuniSharePropertyPlan {
    <#
    .SYNOPSIS
        Plan to set share properties on many shares, skipping shares that already match.
    .DESCRIPTION
        Replaces SetFilerSharesToReadOnly, SetHideUnreadableForAllShares, SetMacSupportForAllShares,
        SetPreviousVersionsForAllShares and SetBlockFilesForAllSharesOnaFiler.
        -BlockFiles builds the veto_files value. Like the original, it REPLACES the existing list.
    .EXAMPLE
        New-NasuniSharePropertyPlan -FilerSerial NEA-NY-01 -Set @{ readonly = $true }
    .EXAMPLE
        New-NasuniSharePropertyPlan -Set @{ fruit_enabled = $true }               # every share
    .EXAMPLE
        New-NasuniSharePropertyPlan -FilerSerial NEA-NY-01 -BlockFiles 'Thumbs.db', 'Desktop.ini', '.DS_Store'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [hashtable]$Set = @{},
        [string[]]$BlockFiles,
        [string]$FilerSerial,
        [string]$VolumeGuid,
        [string]$ShareName
    )
    $desired = @{} + $Set
    if ($BlockFiles) { $desired.veto_files = ($BlockFiles | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`r`n" }
    if ($desired.Count -eq 0) { throw 'Nothing to set. Use -Set @{ field = value } or -BlockFiles.' }
    foreach ($k in $desired.Keys) { if ($k -notin $script:ShareSettableFields) { throw "Share field '$k' is not settable by this plan. Allowed: $($script:ShareSettableFields -join ', ')" } }
    $items = [System.Collections.Generic.List[object]]::new(); $skipped = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @(Get-NasuniShares)) {
        $vg = [string](Get-NmcValue $s 'volume_guid'); $fs = [string](Get-NmcValue $s 'filer_serial_number'); $id = [string](Get-NmcValue $s 'id'); $nm = [string](Get-NmcValue $s 'name')
        if ($FilerSerial -and $fs -ne $FilerSerial) { continue }
        if ($VolumeGuid -and $vg -ne $VolumeGuid) { continue }
        if ($ShareName -and $nm -ne $ShareName) { continue }
        $key = "$vg/$fs/share:$id"
        $changes = @{}; $before = @{}
        foreach ($k in $desired.Keys) {
            $cur = Get-NmcValue $s $k
            if (-not (Test-NmcValueEqual -Current $cur -Desired $desired[$k])) { $changes[$k] = $desired[$k]; $before[$k] = $cur }
        }
        if ($changes.Count -eq 0) { $skipped.Add((New-NmcSkip -Key $key -Reason "share '$nm' already has the requested settings")); continue }
        $items.Add((New-NasuniBulkItem -Key $key -Command Set-NasuniShare -Parameters @{ VolumeGuid = $vg; FilerSerial = $fs; ShareId = $id } -Body $changes `
                    -Summary "share '$nm' on $fs : $(($changes.Keys | Sort-Object | ForEach-Object { "$_=$($changes[$_])" }) -join ', ')" -Before $before -After $changes))
    }
    New-NasuniBulkPlan -Name 'share-properties' -Description "Set $(($desired.Keys | Sort-Object) -join ', ') on shares" -Items $items.ToArray() -Skipped $skipped.ToArray()
}

function New-NasuniExportPropertyPlan {
    <#
    .SYNOPSIS
        Plan to set NFS export properties on many exports, skipping exports that already match.
    .DESCRIPTION
        Replaces UpdateAccessModeForAllExports.ps1 (and generalises it to the other export fields).
    .EXAMPLE
        New-NasuniExportPropertyPlan -Set @{ access_mode = 'no_root_squash' }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Set, [string]$FilerSerial, [string]$VolumeGuid)
    $allowed = @('readonly', 'hostspec', 'access_mode', 'perf_mode', 'sec_options', 'comment')
    foreach ($k in $Set.Keys) { if ($k -notin $allowed) { throw "Export field '$k' is not settable by this plan. Allowed: $($allowed -join ', ')" } }
    if ($Set.ContainsKey('access_mode') -and $Set.access_mode -notin @('root_squash', 'no_root_squash', 'all_squash')) { throw 'access_mode must be root_squash, no_root_squash or all_squash.' }
    if ($Set.ContainsKey('perf_mode') -and $Set.perf_mode -notin @('sync', 'no_wdelay', 'async')) { throw 'perf_mode must be sync, no_wdelay or async.' }
    $items = [System.Collections.Generic.List[object]]::new(); $skipped = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @(Get-NasuniExports)) {
        $vg = [string](Get-NmcValue $e 'volume_guid'); $fs = [string](Get-NmcValue $e 'filer_serial_number'); $id = [string](Get-NmcValue $e 'id'); $nm = [string](Get-NmcValue $e 'name')
        if (($FilerSerial -and $fs -ne $FilerSerial) -or ($VolumeGuid -and $vg -ne $VolumeGuid)) { continue }
        $key = "$vg/$fs/export:$id"
        $changes = @{}; $before = @{}
        foreach ($k in $Set.Keys) { $cur = Get-NmcValue $e $k; if (-not (Test-NmcValueEqual -Current $cur -Desired $Set[$k])) { $changes[$k] = $Set[$k]; $before[$k] = $cur } }
        if ($changes.Count -eq 0) { $skipped.Add((New-NmcSkip -Key $key -Reason "export '$nm' already matches")); continue }
        $items.Add((New-NasuniBulkItem -Key $key -Command Set-NasuniExport -Parameters @{ VolumeGuid = $vg; FilerSerial = $fs; ExportId = $id } -Body $changes -Summary "export '$nm' on $fs" -Before $before -After $changes))
    }
    New-NasuniBulkPlan -Name 'export-properties' -Description "Set $(($Set.Keys | Sort-Object) -join ', ') on NFS exports" -Items $items.ToArray() -Skipped $skipped.ToArray()
}

function ConvertTo-NmcShareBody {
    # Builds a share-create body from a 'shares' report row, with the original script's defaults.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][object]$Row)
    # The NMC path format (for example \folder) is passed through unchanged; empty means the volume root.
    $path = [string](Get-NmcValue $Row 'path')
    if (-not $path) { $path = '\' }
    [ordered]@{
        name                    = [string](Get-NmcValue $Row 'share_name')
        path                    = $path
        comment                 = [string](Get-NmcValue $Row 'comment')
        readonly                = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'readonly') $false 'readonly'
        browseable              = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'browseable') $true 'browseable'
        hosts_allow             = ((Split-NmcList (Get-NmcValue $Row 'hosts_allow')) -join ' ')
        hide_unreadable         = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'hide_unreadable') $true 'hide_unreadable'
        enable_previous_vers    = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'enable_previous_vers') $false 'enable_previous_vers'
        case_sensitive          = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'case_sensitive') $false 'case_sensitive'
        enable_snapshot_dirs    = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'enable_snapshot_dirs') $false 'enable_snapshot_dirs'
        homedir_support         = if ([string](Get-NmcValue $Row 'homedir_support')) { [int](Get-NmcValue $Row 'homedir_support') } else { 0 }
        mobile                  = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'mobile') $false 'mobile'
        browser_access          = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'browser_access') $false 'browser_access'
        browser_access_settings = [ordered]@{
            shared_links_enabled = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'shared_links_enabled') $false 'shared_links_enabled'
            link_force_password  = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'link_force_password') $true 'link_force_password'
            link_allow_rw        = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'link_allow_rw') $false 'link_allow_rw'
            external_share_url   = [string](Get-NmcValue $Row 'external_share_url')
            link_expire_limit    = if ([string](Get-NmcValue $Row 'link_expire_limit')) { [int](Get-NmcValue $Row 'link_expire_limit') } else { 30 }
            link_auth            = [ordered]@{
                authall = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'link_authAuthall') $true 'link_authAuthall'
                allow_groups_ro = Split-NmcList (Get-NmcValue $Row 'link_authAllow_groups_ro'); allow_groups_rw = Split-NmcList (Get-NmcValue $Row 'link_authAllow_groups_rw')
                deny_groups = Split-NmcList (Get-NmcValue $Row 'link_authDeny_groups'); allow_users_ro = Split-NmcList (Get-NmcValue $Row 'link_authAllow_users_ro')
                allow_users_rw = Split-NmcList (Get-NmcValue $Row 'link_authAllow_users_rw'); deny_users = Split-NmcList (Get-NmcValue $Row 'link_authDeny_users')
            }
        }
        aio_enabled             = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'aio_enabled') $true 'aio_enabled'
        veto_files              = ((Split-NmcList (Get-NmcValue $Row 'veto_files')) -join "`r`n")
        fruit_enabled           = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'fruit_enabled') $false 'fruit_enabled'
        smb_encrypt             = [string](Get-NmcValue $Row 'smb_encrypt')
        auth                    = [ordered]@{
            authall = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'authAuthall') $true 'authAuthall'
            rw_groups = Split-NmcList (Get-NmcValue $Row 'authRw_groups'); ro_groups = Split-NmcList (Get-NmcValue $Row 'authRo_groups'); deny_groups = Split-NmcList (Get-NmcValue $Row 'authDeny_groups')
            rw_users = Split-NmcList (Get-NmcValue $Row 'authRw_users'); ro_users = Split-NmcList (Get-NmcValue $Row 'authRo_users'); deny_users = Split-NmcList (Get-NmcValue $Row 'authDeny_users')
        }
    }
}

function New-NasuniShareCreatePlan {
    <#
    .SYNOPSIS
        Plan to create SMB shares from a CSV in the 'shares' report format.
    .DESCRIPTION
        Replaces CreateSharesFromCSV.ps1. It skips shares whose name already exists on the same
        volume and filer, and rows with a missing volume, filer or name. The body is a real
        object, so quotes and backslashes in names or comments are safe.
    .EXAMPLE
        Export-NasuniReport -Name shares -Path ./shares.csv   # edit, then:
        New-NasuniShareCreatePlan -CsvPath ./shares.csv
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$CsvPath)
    $existing = @{}
    foreach ($s in @(Get-NasuniShares)) { $existing[('{0}|{1}|{2}' -f (Get-NmcValue $s 'volume_guid'), (Get-NmcValue $s 'filer_serial_number'), ([string](Get-NmcValue $s 'name')).ToLowerInvariant())] = $true }
    $items = [System.Collections.Generic.List[object]]::new(); $skipped = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($r in @(Import-Csv -LiteralPath $CsvPath)) {
        $n++
        $vg = [string](Get-NmcValue $r 'Volume_GUID'); $fs = [string](Get-NmcValue $r 'filer_serial_number'); $nm = [string](Get-NmcValue $r 'share_name')
        $key = "$vg/$fs/share-name:$nm"
        if (-not $vg -or -not $fs -or -not $nm) { $skipped.Add((New-NmcSkip -Key "row:$n" -Reason 'missing Volume_GUID, filer_serial_number or share_name')); continue }
        if ($existing.ContainsKey("$vg|$fs|$($nm.ToLowerInvariant())")) { $skipped.Add((New-NmcSkip -Key $key -Reason 'a share with this name already exists there')); continue }
        try { $body = ConvertTo-NmcShareBody -Row $r } catch { $skipped.Add((New-NmcSkip -Key $key -Reason "row $n : $($_.Exception.Message)")); continue }
        $items.Add((New-NasuniBulkItem -Key $key -Command New-NasuniShare -Parameters @{ VolumeGuid = $vg; FilerSerial = $fs } -Body $body -Summary "create share '$nm' ($($body.path)) on $fs"))
    }
    New-NasuniBulkPlan -Name 'share-create' -Description "Create shares from $CsvPath" -Items $items.ToArray() -Skipped $skipped.ToArray()
}

function New-NasuniShareDeletePlan {
    <#
    .SYNOPSIS
        Plan to delete the SMB shares listed in a CSV (shareid, Volume_GUID, filer_serial_number, share_name).
    .DESCRIPTION
        Replaces DeleteSharesFromCSV.ps1. Before deleting, each row is checked against the NMC: the
        share id must exist on that volume and filer AND have the listed name. Mismatches are
        skipped, never deleted. The plan is DESTRUCTIVE: execution asks for confirmation.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$CsvPath)
    $byId = @{}
    foreach ($s in @(Get-NasuniShares)) { $byId[('{0}|{1}|{2}' -f (Get-NmcValue $s 'volume_guid'), (Get-NmcValue $s 'filer_serial_number'), (Get-NmcValue $s 'id'))] = $s }
    $items = [System.Collections.Generic.List[object]]::new(); $skipped = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($r in @(Import-Csv -LiteralPath $CsvPath)) {
        $n++
        $id = [string](Get-NmcValue $r 'shareid'); $vg = [string](Get-NmcValue $r 'Volume_GUID'); $fs = [string](Get-NmcValue $r 'filer_serial_number'); $nm = [string](Get-NmcValue $r 'share_name')
        if (-not $id -or -not $vg -or -not $fs -or -not $nm) { $skipped.Add((New-NmcSkip -Key "row:$n" -Reason 'missing shareid, Volume_GUID, filer_serial_number or share_name')); continue }
        $key = "$vg/$fs/share:$id"
        $cur = $byId["$vg|$fs|$id"]
        if (-not $cur) { $skipped.Add((New-NmcSkip -Key $key -Reason 'no such share (already deleted?)')); continue }
        if ([string](Get-NmcValue $cur 'name') -ne $nm) { $skipped.Add((New-NmcSkip -Key $key -Reason "name mismatch: CSV says '$nm', NMC has '$(Get-NmcValue $cur 'name')'. Not deleted.")); continue }
        $items.Add((New-NasuniBulkItem -Key $key -Command Remove-NasuniShare -Parameters @{ VolumeGuid = $vg; FilerSerial = $fs; ShareId = $id } -Summary "DELETE share '$nm' ($(Get-NmcValue $cur 'path')) on $fs"))
    }
    New-NasuniBulkPlan -Name 'share-delete' -Description "Delete shares listed in $CsvPath" -Items $items.ToArray() -Skipped $skipped.ToArray()
}

function New-NasuniShareReplicationPlan {
    <#
    .SYNOPSIS
        Plan to create, on a destination filer, the shares that exist on a source filer but not on the destination.
    .DESCRIPTION
        Replaces ReplicateMissingShares.ps1. Only volumes the destination can serve are used:
        it must be connected to the volume or own it. Names are compared per volume,
        exactly and ignoring case. Settings are copied from the source share.
    .EXAMPLE
        New-NasuniShareReplicationPlan -SourceFilerSerial NEA-NY-01 -DestinationFilerSerial NEA-LON-03
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$SourceFilerSerial, [Parameter(Mandatory)][string]$DestinationFilerSerial)
    if ($SourceFilerSerial -eq $DestinationFilerSerial) { throw 'Source and destination must differ.' }
    $served = @{}
    foreach ($c in @(Get-NasuniVolumeConnections)) { if ((Get-NmcValue $c 'filer_serial_number') -eq $DestinationFilerSerial -and (Get-NmcValue $c 'connected') -eq $true) { $served[[string](Get-NmcValue $c 'volume_guid')] = $true } }
    foreach ($v in @(Get-NasuniVolumes)) { if ((Get-NmcValue $v 'filer_serial_number') -eq $DestinationFilerSerial) { $served[[string](Get-NmcValue $v 'guid')] = $true } }
    $all = @(Get-NasuniShares)
    $destNames = @{}
    foreach ($s in $all | Where-Object { (Get-NmcValue $_ 'filer_serial_number') -eq $DestinationFilerSerial }) { $destNames[('{0}|{1}' -f (Get-NmcValue $s 'volume_guid'), ([string](Get-NmcValue $s 'name')).ToLowerInvariant())] = $true }
    $items = [System.Collections.Generic.List[object]]::new(); $skipped = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $all | Where-Object { (Get-NmcValue $_ 'filer_serial_number') -eq $SourceFilerSerial }) {
        $vg = [string](Get-NmcValue $s 'volume_guid'); $nm = [string](Get-NmcValue $s 'name')
        $key = "$vg/$DestinationFilerSerial/share-name:$nm"
        if ($destNames.ContainsKey("$vg|$($nm.ToLowerInvariant())")) { $skipped.Add((New-NmcSkip -Key $key -Reason 'already exists on destination')); continue }
        if (-not $served.ContainsKey($vg)) { $skipped.Add((New-NmcSkip -Key $key -Reason 'destination is not connected to this volume')); continue }
        $body = [ordered]@{}
        foreach ($p in $s.PSObject.Properties) { if ($p.Name -notin @('id', 'filer_serial_number', 'volume_guid', 'links')) { $body[$p.Name] = $p.Value } }
        $items.Add((New-NasuniBulkItem -Key $key -Command New-NasuniShare -Parameters @{ VolumeGuid = $vg; FilerSerial = $DestinationFilerSerial } -Body $body -Summary "copy share '$nm' to $DestinationFilerSerial"))
    }
    New-NasuniBulkPlan -Name 'share-replicate' -Description "Shares on $SourceFilerSerial missing on $DestinationFilerSerial" -Items $items.ToArray() -Skipped $skipped.ToArray()
}

function New-NasuniSharePermissionPlan {
    <#
    .SYNOPSIS
        Plan to apply share permissions from a CSV in the 'shares' report format.
    .DESCRIPTION
        Replaces UpdateSharePermissions.ps1. Rows with authAuthall = False get their user and group
        lists applied. Other rows are skipped, as in the original, and so are shares whose
        permissions already match.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$CsvPath)
    $byId = @{}
    foreach ($s in @(Get-NasuniShares)) { $byId[('{0}|{1}|{2}' -f (Get-NmcValue $s 'volume_guid'), (Get-NmcValue $s 'filer_serial_number'), (Get-NmcValue $s 'id'))] = $s }
    $items = [System.Collections.Generic.List[object]]::new(); $skipped = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($r in @(Import-Csv -LiteralPath $CsvPath)) {
        $n++
        $id = [string](Get-NmcValue $r 'shareid'); $vg = [string](Get-NmcValue $r 'Volume_GUID'); $fs = [string](Get-NmcValue $r 'filer_serial_number')
        $key = "$vg/$fs/share:$id"
        if ([string](Get-NmcValue $r 'authAuthall') -notmatch '^(?i)false$') { $skipped.Add((New-NmcSkip -Key $key -Reason 'authAuthall is not False (row left alone, as in the original)')); continue }
        $cur = $byId["$vg|$fs|$id"]
        if (-not $cur) { $skipped.Add((New-NmcSkip -Key $key -Reason 'no such share')); continue }
        $auth = [ordered]@{ authall = $false
            rw_groups = Split-NmcList (Get-NmcValue $r 'authRw_groups'); ro_groups = Split-NmcList (Get-NmcValue $r 'authRo_groups'); deny_groups = Split-NmcList (Get-NmcValue $r 'authDeny_groups')
            rw_users = Split-NmcList (Get-NmcValue $r 'authRw_users'); ro_users = Split-NmcList (Get-NmcValue $r 'authRo_users'); deny_users = Split-NmcList (Get-NmcValue $r 'authDeny_users')
        }
        $same = (Get-NmcValue $cur 'auth.authall') -eq $false
        foreach ($k in 'rw_groups', 'ro_groups', 'deny_groups', 'rw_users', 'ro_users', 'deny_users') { if (-not (Test-NmcValueEqual -Current (Get-NmcValue $cur "auth.$k") -Desired $auth[$k])) { $same = $false } }
        if ($same) { $skipped.Add((New-NmcSkip -Key $key -Reason 'permissions already match')); continue }
        $items.Add((New-NasuniBulkItem -Key $key -Command Set-NasuniShare -Parameters @{ VolumeGuid = $vg; FilerSerial = $fs; ShareId = $id } -Body @{ auth = $auth } `
                    -Summary "permissions on share '$(Get-NmcValue $cur 'name')'" -Before (Get-NmcValue $cur 'auth') -After $auth))
    }
    New-NasuniBulkPlan -Name 'share-permissions' -Description "Share permissions from $CsvPath" -Items $items.ToArray() -Skipped $skipped.ToArray()
}

function ConvertTo-NmcExportBody {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][object]$Row, [switch]$HostOption)
    $access = [string](Get-NmcValue $Row 'access_mode'); $perf = [string](Get-NmcValue $Row 'perf_mode')
    if ($access -and $access -notin @('root_squash', 'no_root_squash', 'all_squash')) { throw "access_mode '$access' is invalid." }
    if ($perf -and $perf -notin @('sync', 'no_wdelay', 'async')) { throw "perf_mode '$perf' is invalid." }
    $b = [ordered]@{}
    if (-not $HostOption) { $b.name = [string](Get-NmcValue $Row 'export_name'); $b.path = [string](Get-NmcValue $Row 'path'); $b.comment = [string](Get-NmcValue $Row 'comment') }
    $b.readonly = ConvertTo-NmcBoolValue (Get-NmcValue $Row 'readonly') $false 'readonly'
    $b.hostspec = ((Split-NmcList (Get-NmcValue $Row 'allowed_hosts')) -join ',')
    if ($access) { $b.access_mode = $access }
    if ($perf) { $b.perf_mode = $perf }
    $b.sec_options = @(([string](Get-NmcValue $Row 'sec_options')) -split '[;\s]+' | Where-Object { $_ })
    $b
}

function New-NasuniExportCreatePlan {
    <#
    .SYNOPSIS
        Plan to create NFS exports from a CSV in the 'nfs-exports' report format.
    .DESCRIPTION
        Replaces CreateExportsFromCSV.ps1. Exports whose name already exists on that volume and filer
        are skipped. Host options are created separately, with New-NasuniExportHostOptionPlan.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$CsvPath)
    $existing = @{}
    foreach ($e in @(Get-NasuniExports)) { $existing[('{0}|{1}|{2}' -f (Get-NmcValue $e 'volume_guid'), (Get-NmcValue $e 'filer_serial_number'), (Get-NmcValue $e 'name'))] = $true }
    $items = [System.Collections.Generic.List[object]]::new(); $skipped = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($r in @(Import-Csv -LiteralPath $CsvPath)) {
        $n++
        $vg = [string](Get-NmcValue $r 'Volume_GUID'); $fs = [string](Get-NmcValue $r 'filer_serial_number'); $nm = [string](Get-NmcValue $r 'export_name')
        $key = "$vg/$fs/export-name:$nm"
        if (-not $vg -or -not $fs -or -not $nm) { $skipped.Add((New-NmcSkip -Key "row:$n" -Reason 'missing Volume_GUID, filer_serial_number or export_name')); continue }
        if ($existing.ContainsKey("$vg|$fs|$nm")) { $skipped.Add((New-NmcSkip -Key $key -Reason 'export already exists')); continue }
        try { $body = ConvertTo-NmcExportBody -Row $r } catch { $skipped.Add((New-NmcSkip -Key $key -Reason "row $n : $($_.Exception.Message)")); continue }
        $items.Add((New-NasuniBulkItem -Key $key -Command New-NasuniExport -Parameters @{ VolumeGuid = $vg; FilerSerial = $fs } -Body $body -Summary "create export '$nm' on $fs"))
    }
    New-NasuniBulkPlan -Name 'export-create' -Description "Create exports from $CsvPath" -Items $items.ToArray() -Skipped $skipped.ToArray()
}

function New-NasuniExportHostOptionPlan {
    <#
    .SYNOPSIS
        Plan to add NFS host options from a CSV (filer_serial_number, export_name, readonly, allowed_hosts, access_mode, perf_mode, sec_options).
    .DESCRIPTION
        Replaces CreateExportHostOptionsFromCSV.ps1. The export is found by filer and name. Rows that
        match no export, or more than one (the same name on several volumes), are skipped. The
        original reused the previous row's export id when a row matched nothing.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$CsvPath)
    $exports = @(Get-NasuniExports)
    $items = [System.Collections.Generic.List[object]]::new(); $skipped = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($r in @(Import-Csv -LiteralPath $CsvPath)) {
        $n++
        $fs = [string](Get-NmcValue $r 'filer_serial_number'); $nm = [string](Get-NmcValue $r 'export_name')
        $match = @($exports | Where-Object { (Get-NmcValue $_ 'filer_serial_number') -eq $fs -and (Get-NmcValue $_ 'name') -eq $nm })
        $key = "row:$n/$fs/export-name:$nm/hosts:$(Get-NmcValue $r 'allowed_hosts')"
        if ($match.Count -ne 1) { $skipped.Add((New-NmcSkip -Key $key -Reason "$($match.Count) exports match filer '$fs' and name '$nm' (need exactly 1)")); continue }
        try { $body = ConvertTo-NmcExportBody -Row $r -HostOption } catch { $skipped.Add((New-NmcSkip -Key $key -Reason $_.Exception.Message)); continue }
        $e = $match[0]
        $items.Add((New-NasuniBulkItem -Key $key -Command New-NasuniNfsHostOption -Parameters @{ VolumeGuid = [string](Get-NmcValue $e 'volume_guid'); FilerSerial = $fs; ExportId = [string](Get-NmcValue $e 'id') } -Body $body -Summary "host option $($body.hostspec) on export '$nm'"))
    }
    New-NasuniBulkPlan -Name 'export-host-options' -Description "NFS host options from $CsvPath" -Items $items.ToArray() -Skipped $skipped.ToArray()
}

function New-NasuniAntivirusPlan {
    <#
    .SYNOPSIS
        Plan to ignore, or to delete the files of, antivirus violations.
    .DESCRIPTION
        Replaces IgnoreOrDeleteAvViolations.ps1 and UpdateAllAntivirusViolations.ps1. There is no
        default -Action. 'delete_file' makes the plan DESTRUCTIVE. With zero violations the plan
        is empty; the original sent DELETEs with empty ids.
    .EXAMPLE
        New-NasuniAntivirusPlan -Action ignore_violation -VolumeGuid vol-eng
    .EXAMPLE
        New-NasuniAntivirusPlan -Action delete_file -PathLike '*.exe'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('ignore_violation', 'delete_file')][string]$Action,
        [string]$VolumeGuid, [string]$FilerSerial, [string]$PathLike, [string[]]$ViolationId
    )
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($v in @(Get-NasuniAntivirusViolations)) {
        $vg = [string](Get-NmcValue $v 'volume_guid'); $fs = [string](Get-NmcValue $v 'filer_serial_number'); $id = [string](Get-NmcValue $v 'id'); $fp = [string](Get-NmcValue $v 'fpath')
        if (($VolumeGuid -and $vg -ne $VolumeGuid) -or ($FilerSerial -and $fs -ne $FilerSerial) -or ($PathLike -and $fp -notlike $PathLike) -or ($ViolationId -and $id -notin $ViolationId)) { continue }
        $verb = if ($Action -eq 'delete_file') { 'DELETE FILE' } else { 'ignore' }
        $items.Add((New-NasuniBulkItem -Key "$vg/$fs/av:$id" -Command Remove-NasuniAntivirusViolation -Parameters @{ VolumeGuid = $vg; FilerSerial = $fs; AntivirusId = $id; Action = $Action } -Summary "$verb $fp ($(Get-NmcValue $v 'vname'))"))
    }
    New-NasuniBulkPlan -Name "antivirus-$Action" -Description "Antivirus violations: $Action" -Items $items.ToArray()
}

function Test-NmcIpAddress {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Value)
    $ip = $null
    [System.Net.IPAddress]::TryParse($Value, [ref]$ip) -and $Value -notmatch '\s'
}

function New-NasuniClientBlockPlan {
    <#
    .SYNOPSIS
        Plan to block (or unblock) client IP addresses on every NMC-managed filer.
    .DESCRIPTION
        Replaces BlockIpOnAllNEAs.ps1, UnblockIpOnAllNEAs.ps1, BlockIpOnAnNEA.ps1 and UnblockIpOnAnNEA.ps1.
        Filers that already block the IP (or no longer do) are skipped.
    .EXAMPLE
        New-NasuniClientBlockPlan -IpAddress 10.1.2.3 -Block
    .EXAMPLE
        Get-NasuniRansomwareAttackIp -Minutes 5 | New-NasuniClientBlockPlan -Block   # DetectAndBlockIpOnAllNEAs.ps1
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding(DefaultParameterSetName = 'Block')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][string[]]$IpAddress,
        [Parameter(Mandatory, ParameterSetName = 'Block')][switch]$Block,
        [Parameter(Mandatory, ParameterSetName = 'Unblock')][switch]$Unblock,
        [string[]]$FilerSerial
    )
    begin { $ips = [System.Collections.Generic.List[string]]::new() }
    process { foreach ($i in $IpAddress) { if (-not (Test-NmcIpAddress $i)) { throw "'$i' is not a valid IP address." }; if (-not $ips.Contains($i)) { $ips.Add($i) } } }
    end {
        $doBlock = [bool]$Block -and -not $Unblock   # parameter sets guarantee exactly one is set
        $blocked = @{}
        foreach ($b in @(Get-NasuniBlockedClients)) { $blocked["$(Get-NmcValue $b 'filer_serial_number')|$(Get-NmcValue $b 'ip_address')"] = $true }
        $filers = @(Get-NasuniFilers | Where-Object { (Get-NmcValue $_ 'management_state') -eq 'nmc' } | ForEach-Object { [string](Get-NmcValue $_ 'serial_number') })
        if ($FilerSerial) { $filers = @($filers | Where-Object { $_ -in $FilerSerial }) }
        $items = [System.Collections.Generic.List[object]]::new(); $skipped = [System.Collections.Generic.List[object]]::new()
        foreach ($ip in $ips) {
            foreach ($fs in $filers) {
                $key = "$fs/ip:$ip"
                $isBlocked = $blocked.ContainsKey("$fs|$ip")
                if ($doBlock) {
                    if ($isBlocked) { $skipped.Add((New-NmcSkip -Key $key -Reason 'already blocked')); continue }
                    $items.Add((New-NasuniBulkItem -Key $key -Command Block-NasuniFilerClient -Parameters @{ FilerSerial = $fs } -Body @{ ip_address = $ip } -Summary "block $ip on $fs"))
                }
                else {
                    if (-not $isBlocked) { $skipped.Add((New-NmcSkip -Key $key -Reason 'not blocked')); continue }
                    $items.Add((New-NasuniBulkItem -Key $key -Command Unblock-NasuniFilerClient -Parameters @{ FilerSerial = $fs; BlockedIp = $ip } -Summary "unblock $ip on $fs"))
                }
            }
        }
        $verb = if ($doBlock) { 'block' } else { 'unblock' }
        New-NasuniBulkPlan -Name "client-$verb" -Description "$verb $($ips -join ', ')" -Items $items.ToArray() -Skipped $skipped.ToArray()
    }
}

function Get-NasuniRansomwareAttackIp {
    <#
    .SYNOPSIS
        Returns the distinct client IPs from recent ransomware-attack notifications (AR_NEW_ATTACK).
    .DESCRIPTION
        The detection half of DetectAndBlockIpOnAllNEAs.ps1. The IP is the first "(...)" in the
        message that parses as an IP address. Dates are parsed robustly; fractional seconds broke
        the original.
    .EXAMPLE
        Get-NasuniRansomwareAttackIp -Minutes 5 | New-NasuniClientBlockPlan -Block
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(1, 10080)][int]$Minutes = 5)
    $since = [datetimeoffset]::UtcNow.AddMinutes(-$Minutes)
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($n in @(Get-NasuniNotifications | Where-Object { (Get-NmcValue $_ 'name') -eq 'AR_NEW_ATTACK' })) {
        $d = [datetimeoffset]::MinValue
        $ds = ([string](Get-NmcValue $n 'date')) -replace '\s*UTC$', ''
        if (-not [datetimeoffset]::TryParse($ds, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d) -or $d -lt $since) { continue }
        foreach ($m in [regex]::Matches([string](Get-NmcValue $n 'message'), '\(([^)]+)\)')) {
            $candidate = $m.Groups[1].Value.Trim()
            if ((Test-NmcIpAddress $candidate) -and $seen.Add($candidate)) { $candidate; break }
        }
    }
}

function New-NasuniMessageCleanupPlan {
    <#
    .SYNOPSIS
        Plan to delete NMC messages with a given code and status (default: failure).
    .DESCRIPTION
        Replaces DeleteSyncErrors.ps1. Pending messages cannot be deleted, so -Status accepts only
        failure or synced.
    .EXAMPLE
        New-NasuniMessageCleanupPlan -Code volumes_shares_add
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_]+$')][string]$Code, [ValidateSet('failure', 'synced')][string]$Status = 'failure')
    $items = foreach ($m in @(Get-NasuniMessages | Where-Object { (Get-NmcValue $_ 'code') -eq $Code -and (Get-NmcValue $_ 'status') -eq $Status })) {
        New-NasuniBulkItem -Key "message:$(Get-NmcValue $m 'id')" -Command Remove-NasuniMessage -Parameters @{ MessageId = [string](Get-NmcValue $m 'id') } -Summary "delete $Status message $Code on $(Get-NmcValue $m 'filer_serial_number')"
    }
    New-NasuniBulkPlan -Name 'message-cleanup' -Description "Delete $Status messages with code $Code" -Items @($items)
}

# TODO(roadmap#16): optional -Snapshot and a before/after GFL state report, as the original DisableGFL did.
function New-NasuniGlobalLockPlan {
    <#
    .SYNOPSIS
        Plan to enable (with a mode) or disable Global File Locking on folder paths.
    .DESCRIPTION
        Replaces EnableGFLOnMultiplePaths, DisableGFLOnMultiplePaths, SetGFLandMode and
        SetGFLandModeForMultiplePaths. Paths come from -Path or a CSV (Path[,Mode]). Duplicates
        are removed. The NMC refuses GFL changes while a snapshot runs: execute with
        -RetryMessagePattern 'snapshot is taking place' (and -RetryDelaySeconds) to retry those
        items, or re-run with the same journal later.
    .EXAMPLE
        New-NasuniGlobalLockPlan -VolumeGuid vol-eng -Path /projects/a, /projects/b -Mode optimized
    .EXAMPLE
        New-NasuniGlobalLockPlan -VolumeGuid vol-eng -CsvPath ./gfl.csv -Disable
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only')]
    [CmdletBinding(DefaultParameterSetName = 'Enable')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VolumeGuid,
        [string[]]$Path,
        [string]$CsvPath,
        [Parameter(ParameterSetName = 'Enable')][ValidateSet('optimized', 'advanced', 'asynchronous')][string]$Mode = 'optimized',
        [Parameter(Mandatory, ParameterSetName = 'Disable')][switch]$Disable
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($p in @($Path | Where-Object { $_ })) { $rows.Add([pscustomobject]@{ Path = $p; Mode = $Mode }) }
    if ($CsvPath) { foreach ($r in @(Import-Csv -LiteralPath $CsvPath)) { $rows.Add([pscustomobject]@{ Path = [string](Get-NmcValue $r 'Path'); Mode = $(if (Get-NmcValue $r 'Mode') { [string](Get-NmcValue $r 'Mode') } else { $Mode }) }) } }
    if ($rows.Count -eq 0) { throw 'Give -Path and/or -CsvPath.' }
    $items = [System.Collections.Generic.List[object]]::new(); $skipped = [System.Collections.Generic.List[object]]::new(); $seen = @{}
    foreach ($r in $rows) {
        $norm = '/' + ($r.Path.Replace('\', '/').Trim().Trim('/'))
        if ($norm -eq '/' -or $norm -match '(^|/)\.\.?(/|$)') { $skipped.Add((New-NmcSkip -Key "path:$($r.Path)" -Reason 'invalid path (root, empty, or containing . / ..)')); continue }
        if ($seen.ContainsKey($norm)) { $skipped.Add((New-NmcSkip -Key "path:$norm" -Reason 'duplicate')); continue }
        $seen[$norm] = $true
        if ($Disable) {
            $items.Add((New-NasuniBulkItem -Key "$VolumeGuid/gfl:$norm" -Command Disable-NasuniGlobalLockFolder -Parameters @{ VolumeGuid = $VolumeGuid; FolderPath = $norm } -Summary "disable GFL on $norm"))
        }
        else {
            if ($r.Mode -notin @('optimized', 'advanced', 'asynchronous')) { $skipped.Add((New-NmcSkip -Key "path:$norm" -Reason "invalid mode '$($r.Mode)'")); continue }
            $items.Add((New-NasuniBulkItem -Key "$VolumeGuid/gfl:$norm" -Command Enable-NasuniGlobalLockFolder -Parameters @{ VolumeGuid = $VolumeGuid } -Body @{ path = $norm; mode = $r.Mode } -Summary "enable GFL ($($r.Mode)) on $norm"))
        }
    }
    $verb = if ($Disable) { 'disable' } else { 'enable' }
    New-NasuniBulkPlan -Name "gfl-$verb" -Description "Global File Locking: $verb on volume $VolumeGuid" -Items $items.ToArray() -Skipped $skipped.ToArray()
}

function New-NasuniFolderQuotaPlan {
    <#
    .SYNOPSIS
        Plan to change the limit of an existing folder quota.
    .DESCRIPTION
        Replaces UpdateQuota.ps1. -VolumeGuid is required: the original used the last match when
        the same path existed on several volumes, and PATCHed a malformed URL when nothing matched.
        Zero or several matches are an error here.
    .EXAMPLE
        New-NasuniFolderQuotaPlan -VolumeGuid vol-finance -Path /Finance/Projects -Limit 500000
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$VolumeGuid, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][ValidateRange(0, [long]::MaxValue)][long]$Limit)
    $norm = '/' + $Path.Replace('\', '/').Trim('/')
    $match = @(Get-NasuniFolderQuotas | Where-Object { (Get-NmcValue $_ 'volume_guid') -eq $VolumeGuid -and ('/' + ([string](Get-NmcValue $_ 'path')).Replace('\', '/').Trim('/')) -eq $norm })
    if ($match.Count -ne 1) { throw "$($match.Count) folder quotas match volume '$VolumeGuid' and path '$norm' (need exactly 1)." }
    $q = $match[0]
    $key = "$VolumeGuid/quota:$(Get-NmcValue $q 'id')"
    if ([long](Get-NmcValue $q 'limit') -eq $Limit) { return New-NasuniBulkPlan -Name 'folder-quota' -Description "Quota on $norm" -Skipped @(New-NmcSkip -Key $key -Reason 'limit already set') }
    $body = @{ type = [string](Get-NmcValue $q 'type'); path = [string](Get-NmcValue $q 'path'); limit = $Limit }
    $item = New-NasuniBulkItem -Key $key -Command Set-NasuniFolderQuota -Parameters @{ VolumeGuid = $VolumeGuid; FolderQuotaId = [string](Get-NmcValue $q 'id') } -Body $body `
        -Summary "quota on $norm : $(Get-NmcValue $q 'limit') -> $Limit" -Before @{ limit = Get-NmcValue $q 'limit' } -After @{ limit = $Limit }
    New-NasuniBulkPlan -Name 'folder-quota' -Description "Quota on $norm" -Items @($item)
}

function Test-NmcSubsetEqual {
    # True when every key in Desired (recursively) equals the value in Current.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Current, [AllowNull()][object]$Desired)
    if ($Desired -is [System.Collections.IDictionary]) {
        foreach ($k in $Desired.Keys) { if (-not (Test-NmcSubsetEqual -Current (Get-NmcValue $Current ([string]$k)) -Desired $Desired[$k])) { return $false } }
        return $true
    }
    Test-NmcValueEqual -Current $Current -Desired $Desired
}

function New-NasuniVolumeAuditPlan {
    <#
    .SYNOPSIS
        Plan to apply audit settings to every volume x online-filer pair.
    .DESCRIPTION
        Replaces SetAuditForAllVolumesAndFilers.ps1 and SetVolumeAuditing.ps1. -Auditing is sent
        as-is under 'auditing'. Use the field names from the NMC API (for example
        @{ enabled = $true; events = @{ create = $true; delete = $true }; logs = @{ prune_audit_logs = $true; days_to_keep = 90 } }).
        Pairs already matching are skipped, and offline filers are skipped unless -IncludeOfflineFilers.
    .EXAMPLE
        New-NasuniVolumeAuditPlan -Auditing @{ enabled = $true; events = @{ delete = $true; rename = $true } } -VolumeGuid vol-finance
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan only; reads the NMC')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Auditing, [string]$VolumeGuid, [string]$FilerSerial, [switch]$IncludeOfflineFilers)
    $offline = @{}
    foreach ($f in @(Get-NasuniFilers)) { if ((Get-NmcValue $f 'status.offline') -eq $true) { $offline[[string](Get-NmcValue $f 'serial_number')] = $true } }
    $items = [System.Collections.Generic.List[object]]::new(); $skipped = [System.Collections.Generic.List[object]]::new()
    foreach ($vf in @(Get-NmcVolumeFilerItem)) {
        $vg = [string]$vf._volume_guid; $fs = [string](Get-NmcValue $vf 'filer_serial_number')
        if (($VolumeGuid -and $vg -ne $VolumeGuid) -or ($FilerSerial -and $fs -ne $FilerSerial)) { continue }
        $key = "$vg/$fs/auditing"
        if ($offline.ContainsKey($fs) -and -not $IncludeOfflineFilers) { $skipped.Add((New-NmcSkip -Key $key -Reason 'filer is offline')); continue }
        if (Test-NmcSubsetEqual -Current (Get-NmcValue $vf 'auditing') -Desired $Auditing) { $skipped.Add((New-NmcSkip -Key $key -Reason 'audit settings already match')); continue }
        $items.Add((New-NasuniBulkItem -Key $key -Command Set-NasuniVolumeFilerSettings -Parameters @{ VolumeGuid = $vg; FilerSerial = $fs } -Body @{ auditing = $Auditing } `
                    -Summary "auditing on volume '$($vf._volume_name)' at $fs" -Before (Get-NmcValue $vf 'auditing') -After $Auditing))
    }
    New-NasuniBulkPlan -Name 'volume-auditing' -Description 'Apply audit settings' -Items $items.ToArray() -Skipped $skipped.ToArray()
}

function Test-NasuniUnprotectedDataAlert {
    <#
    .SYNOPSIS
        Stateful check: which volume/filer pairs have had unprotected data that has not gone down for at least -Days?
    .DESCRIPTION
        Replaces CheckAllUnprotectedAndAlert.ps1. In the original, each run reset the timer before
        the age was reached, so the alert could never fire, and new volume/filer pairs were never
        tracked. Here, each pair records when its unprotected amount last went down (or reached
        zero). The pair alerts once that time is -Days old and the amount is at least -MinBytes.
        The state is a JSON file, chmod 600. Send the returned rows by your own notification
        channel; SMTP is not built in.
    .EXAMPLE
        $alerts = Test-NasuniUnprotectedDataAlert -StatePath ./unprotected-state.json -Days 3
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$StatePath, [ValidateRange(1, 365)][int]$Days = 3, [ValidateRange(0, [long]::MaxValue)][long]$MinBytes = 1)
    $state = @{}
    if (Test-Path -LiteralPath $StatePath) { $raw = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable; if ($raw) { $state = $raw } }
    $now = [datetime]::UtcNow
    $newState = @{}
    foreach ($row in @(Get-NasuniReport -Name 'unprotected-data')) {
        $key = "$($row.volume_guid)|$($row.filer_serial_number)"
        $amount = [long]$row.unprotected_data
        $prev = if ($state.ContainsKey($key)) { $state[$key] } else { $null }
        $since = $now
        if ($prev -and $amount -gt 0 -and $amount -ge [long]$prev.amount) { $since = [datetime]::Parse([string]$prev.since, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal) }
        $newState[$key] = @{ amount = $amount; since = $since.ToString('o') }
        if ($amount -ge $MinBytes -and ($now - $since).TotalDays -ge $Days) {
            [pscustomobject]@{ volume_name = $row.volume_name; volume_guid = $row.volume_guid; filer_description = $row.filer_description; filer_serial_number = $row.filer_serial_number
                unprotected_data = $amount; not_decreasing_since_utc = $since.ToString('o'); days = [math]::Round(($now - $since).TotalDays, 1)
            }
        }
    }
    [System.IO.File]::WriteAllText($StatePath, ($newState | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($StatePath, [System.IO.UnixFileMode]'UserRead, UserWrite') }
}

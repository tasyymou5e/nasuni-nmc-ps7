#Requires -Version 7.4
# MODULE: Nasuni.Nmc.Dashboard. Pode-independent dashboard logic, all unit-tested:
#   rendering (HTML-encoded), CSV safety, RBAC, HMAC-chained audit log, snapshot,
#   two-step change flow, Reports page and background report jobs (Pages.ps1).
# Start-NasuniDashboard.ps1 wires these into Pode routes, middleware and timers.
# Dashboard core: rendering, RBAC, audit log, data snapshot and the two-step change flow.
# Pure PowerShell with no Pode dependency, so every rule here is unit-tested directly.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Rendering ---------------------------------------------------------------

function ConvertTo-DashHtml {
    <#
    .SYNOPSIS
        HTML-encodes any value. Every dynamic value on every page goes through this.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $(if ($Value) { 'yes' } else { 'no' }) }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return [System.Net.WebUtility]::HtmlEncode((@($Value) | ForEach-Object { [string]$_ }) -join ', ')
    }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-DashValue {
    <#
    .SYNOPSIS
        Reads a dotted path (e.g. status.offline) from an object or hashtable; $null if absent.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Path)
    $cur = $InputObject
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) {
            if (-not $cur.Contains($part)) { return $null }
            $cur = $cur[$part]
        }
        else {
            $p = $cur.PSObject.Properties[$part]
            if ($null -eq $p) { return $null }
            $cur = $p.Value
        }
    }
    , $cur
}

function Format-DashTable {
    <#
    .SYNOPSIS
        Renders rows as an HTML table. Columns: @{ Header = 'Name'; Path = 'name' } or with
        Link = scriptblock returning a relative URL (the URL is encoded too).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object[]]$Rows,
        # DEBUG NOTE (See docs/TROUBLESHOOTING.md, "Empty results"): AllowEmptyCollection is needed
        # because a Mandatory array parameter rejects @() at binding time. Generic columns are
        # empty when an undocumented section, such as health, has no rows.
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Columns,
        [ValidateRange(1, 10000)][int]$MaxRows = 2000,
        [string]$Empty = 'No items.'
    )
    $rowsArr = @($Rows | Where-Object { $null -ne $_ })
    if ($rowsArr.Count -eq 0) { return "<p class=""empty"">$(ConvertTo-DashHtml $Empty)</p>" }
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append('<table><thead><tr>')
    foreach ($c in $Columns) { $null = $sb.Append("<th>$(ConvertTo-DashHtml $c.Header)</th>") }
    $null = $sb.Append('</tr></thead><tbody>')
    foreach ($row in ($rowsArr | Select-Object -First $MaxRows)) {
        $null = $sb.Append('<tr>')
        foreach ($c in $Columns) {
            # Action columns show a fixed label; data columns show the encoded value.
            $cell = if ($c.ContainsKey('Label')) { ConvertTo-DashHtml $c.Label } else { ConvertTo-DashHtml (Get-DashValue -InputObject $row -Path $c.Path) }
            if ($c.ContainsKey('Link') -and $c.Link) {
                $href = [string](& $c.Link $row)
                if ($href -match '^/[A-Za-z0-9/_\-?=&.%]*$') { $cell = "<a href=""$(ConvertTo-DashHtml $href)"">$cell</a>" }
            }
            $null = $sb.Append("<td>$cell</td>")
        }
        $null = $sb.Append('</tr>')
    }
    $null = $sb.Append('</tbody></table>')
    if ($rowsArr.Count -gt $MaxRows) { $null = $sb.Append("<p class=""note"">Showing $MaxRows of $($rowsArr.Count). Download the CSV report for everything.</p>") }
    $sb.ToString()
}

function Format-DashPage {
    <#
    .SYNOPSIS
        Wraps page content in the site layout. Only $BodyHtml is trusted HTML; it must be
        built from Format-DashTable / ConvertTo-DashHtml output.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BodyHtml,
        [string]$UserName,
        [string]$Role,
        [string]$CsrfToken,
        [string]$SnapshotAt
    )
    $nav = @(
        @('/', 'Overview'), @('/filers', 'Filers'), @('/volumes', 'Volumes'), @('/shares', 'Shares'),
        @('/antivirus', 'Antivirus'), @('/notifications', 'Notifications'), @('/health', 'Health'),
        @('/credentials', 'Cloud credentials'), @('/reports', 'Reports')
    )
    if ($Role -eq 'Admin') { $nav += , @('/audit', 'Audit log') }
    $navHtml = ($nav | ForEach-Object { "<a href=""$($_[0])"">$(ConvertTo-DashHtml $_[1])</a>" }) -join ''
    $logout = ''
    if ($CsrfToken) {
        $logout = "<form method=""post"" action=""/logout"" class=""inline""><input type=""hidden"" name=""pode.csrf"" value=""$(ConvertTo-DashHtml $CsrfToken)""><button type=""submit"">Sign out</button></form>"
    }
    $stamp = if ($SnapshotAt) { "<span class=""stamp"">Data as of $(ConvertTo-DashHtml $SnapshotAt) UTC</span>" } else { '' }
    @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(ConvertTo-DashHtml $Title) - Nasuni NMC</title><link rel="stylesheet" href="/static/site.css"></head>
<body><header><strong>Nasuni NMC</strong><nav>$navHtml</nav><span class="user">$(ConvertTo-DashHtml $UserName) ($(ConvertTo-DashHtml $Role))</span>$logout</header>
<main><h1>$(ConvertTo-DashHtml $Title)</h1>$stamp
$BodyHtml
</main></body></html>
"@
}

function ConvertTo-DashCsvSafe {
    <#
    .SYNOPSIS
        Neutralises spreadsheet formula injection: values starting with = + - @ tab or CR
        get a leading apostrophe.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $s = if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { (@($Value) | ForEach-Object { [string]$_ }) -join '; ' } else { [string]$Value }
    if ($s -match '^[=+\-@\t\r]') { return "'" + $s }
    $s
}

function ConvertTo-DashCsvRow {
    <#
    .SYNOPSIS
        Flattens rows into CSV-safe objects using the given column definitions.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][object[]]$Rows, [Parameter(Mandatory)][hashtable[]]$Columns)
    foreach ($row in @($Rows | Where-Object { $null -ne $_ })) {
        $o = [ordered]@{}
        foreach ($c in $Columns) { $o[$c.Header] = ConvertTo-DashCsvSafe (Get-DashValue -InputObject $row -Path $c.Path) }
        [pscustomobject]$o
    }
}

#endregion

#region RBAC --------------------------------------------------------------------

$script:Permissions = @{
    Viewer   = @('Read')
    Operator = @('Read', 'Operate', 'Refresh')
    Admin    = @('Read', 'Operate', 'Refresh', 'Destroy', 'Audit')
}

function Resolve-DashRole {
    <#
    .SYNOPSIS
        Maps IdP groups to the highest dashboard role. Returns $null when no group matches.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string[]]$Groups, [Parameter(Mandatory)][hashtable]$RoleMap)
    $g = @($Groups | Where-Object { $_ })
    foreach ($role in 'Admin', 'Operator', 'Viewer') {
        if ($RoleMap.ContainsKey($role) -and (@($RoleMap[$role]) | Where-Object { $g -contains $_ })) { return $role }
    }
    $null
}

function Test-DashPermission {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Role, [Parameter(Mandatory)][ValidateSet('Read', 'Operate', 'Refresh', 'Destroy', 'Audit')][string]$Permission)
    if (-not $Role -or -not $script:Permissions.ContainsKey($Role)) { return $false }
    $script:Permissions[$Role] -contains $Permission
}

#endregion

#region Audit log ---------------------------------------------------------------

function Get-DashAuditHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]]$Key, [Parameter(Mandatory)][AllowEmptyString()][string]$Previous, [Parameter(Mandatory)][string]$Body)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Key)
    try { [Convert]::ToHexString($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Previous`n$Body"))).ToLowerInvariant() }
    finally { $hmac.Dispose() }
}

# TODO(roadmap#10): forward to the SIEM and anchor the last HMAC externally, so deleting the whole file is detectable.
function Write-DashAudit {
    <#
    .SYNOPSIS
        Appends a tamper-evident audit record: HMAC-SHA256(key, previous_hmac + record).
    .DESCRIPTION
        A cross-process named mutex serialises writers, so Pode worker runspaces and restarts
        keep one unbroken chain. Values are redacted before they are written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entry
    )
    if ($Key.Length -lt 32) { throw 'Audit HMAC key must be at least 32 bytes.' }
    $mutex = [System.Threading.Mutex]::new($false, 'NasuniNmcDashboardAudit')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne([timespan]::FromSeconds(10)) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Timed out waiting for the audit log lock.' }
        $prev = ''
        if (Test-Path -LiteralPath $Path) {
            $last = Get-Content -LiteralPath $Path -Tail 1
            if ($last) { $prev = [string]($last | ConvertFrom-Json).hmac }
        }
        $record = [ordered]@{ ts = [datetime]::UtcNow.ToString('o') }
        foreach ($k in $Entry.Keys) { $record[$k] = $Entry[$k] }
        $record = Protect-NasuniSensitiveData -InputObject ([pscustomobject]$record)
        $body = $record | ConvertTo-Json -Compress -Depth 10
        $hash = Get-DashAuditHash -Key $Key -Previous $prev -Body $body
        $line = $body.Substring(0, $body.Length - 1) + ',"prev":"' + $prev + '","hmac":"' + $hash + '"}'
        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir }
        $isNew = -not (Test-Path -LiteralPath $Path)
        [System.IO.File]::AppendAllText($Path, $line + "`n", [System.Text.UTF8Encoding]::new($false))
        if ($isNew -and -not $IsWindows) { [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite') }
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Test-DashAuditChain {
    <#
    .SYNOPSIS
        Verifies every record's HMAC and the link to the previous record.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Valid = $true; Count = 0; BrokenAtLine = $null; Reason = $null } }
    $prev = ''
    $n = 0
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if (-not $line) { continue }
        $n++
        $m = [regex]::Match($line, '^(?<body>\{.*),"prev":"(?<prev>[0-9a-f]*)","hmac":"(?<hmac>[0-9a-f]{64})"\}$')
        if (-not $m.Success) { return [pscustomobject]@{ Valid = $false; Count = $n; BrokenAtLine = $n; Reason = 'Malformed record' } }
        if ($m.Groups['prev'].Value -ne $prev) { return [pscustomobject]@{ Valid = $false; Count = $n; BrokenAtLine = $n; Reason = 'Chain link mismatch (record removed or reordered)' } }
        $expected = Get-DashAuditHash -Key $Key -Previous $prev -Body ($m.Groups['body'].Value + '}')
        if (-not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                [System.Text.Encoding]::ASCII.GetBytes($expected), [System.Text.Encoding]::ASCII.GetBytes($m.Groups['hmac'].Value))) {
            return [pscustomobject]@{ Valid = $false; Count = $n; BrokenAtLine = $n; Reason = 'HMAC mismatch (record altered)' }
        }
        $prev = $m.Groups['hmac'].Value
    }
    [pscustomobject]@{ Valid = $true; Count = $n; BrokenAtLine = $null; Reason = $null }
}

function Read-DashAudit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [ValidateRange(1, 5000)][int]$Last = 200)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Get-Content -LiteralPath $Path -Tail $Last | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

#endregion

#region Data snapshot -------------------------------------------------------------

function Get-DashSnapshot {
    <#
    .SYNOPSIS
        Reads the dashboard's data from the NMC (every page), redacted. A failure in one
        section is recorded in Errors without losing the others.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([ValidateRange(1, 100000)][int]$MaxNotifications = 500)
    $snap = @{ At = [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'); Errors = [System.Collections.Generic.List[string]]::new() }
    $sections = [ordered]@{
        Filers        = { Get-NasuniFilers }
        Volumes       = { Get-NasuniVolumes }
        Shares        = { Get-NasuniShares }
        Health        = { Get-NasuniFilerHealthList }
        Antivirus     = { Get-NasuniAntivirusViolations }
        Notifications = { param($max) Get-NasuniNotifications -First $max }
        Connections   = { Get-NasuniVolumeConnections }
        Credentials   = { Get-NasuniCloudCredentials }
    }
    foreach ($name in $sections.Keys) {
        try {
            # Assign first: Protect-NasuniSensitiveData emits the array as one object, and @() around
            # the call would wrap it in a second array.
            $items = Protect-NasuniSensitiveData -InputObject @(& $sections[$name] $MaxNotifications)
            $snap[$name] = @($items)
        }
        catch {
            $snap[$name] = @()
            $snap.Errors.Add("${name}: $(Protect-NasuniSensitiveData -InputObject $_.Exception.Message)")
        }
    }
    $snap
}

#endregion

#region Change actions --------------------------------------------------------------

$script:IdPattern = '^[A-Za-z0-9._:\-]{1,128}$'

$script:Actions = [ordered]@{
    'share-readonly'   = @{
        Title      = 'Set share read-only flag'
        Permission = 'Operate'
        Params     = @('volume_guid', 'filer_serial', 'share_id', 'readonly')
    }
    'antivirus-ignore' = @{
        Title      = 'Ignore antivirus violation'
        Permission = 'Operate'
        Params     = @('volume_guid', 'filer_serial', 'antivirus_id')
    }
    'antivirus-delete' = @{
        Title      = 'Delete infected file'
        Permission = 'Destroy'
        Params     = @('volume_guid', 'filer_serial', 'antivirus_id')
    }
}

function Get-DashActionDefinition {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:Actions.Contains($Name)) { throw "Unknown action '$Name'." }
    $script:Actions[$Name]
}

function Get-DashActionParameter {
    # Validates and normalises action parameters from a form or query string.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    $def = Get-DashActionDefinition -Name $Action
    $p = @{}
    foreach ($name in $def.Params) {
        $v = if ($Data.Contains($name)) { [string]$Data[$name] } else { '' }
        if ($name -eq 'readonly') {
            if ($v -notin @('true', 'false')) { throw "Parameter 'readonly' must be true or false." }
            $p[$name] = $v -eq 'true'
        }
        else {
            if ($v -notmatch $script:IdPattern) { throw "Parameter '$name' is missing or invalid." }
            $p[$name] = $v
        }
    }
    $p
}

function New-DashActionPreview {
    <#
    .SYNOPSIS
        Step 1 of a change: reads the current state and returns a pending action that must
        be confirmed by typing its confirmation phrase. Nothing is changed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Read-only: builds a pending record')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][hashtable]$Params,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Role,
        [ValidateRange(30, 3600)][int]$TtlSeconds = 300
    )
    $def = Get-DashActionDefinition -Name $Action
    if (-not (Test-DashPermission -Role $Role -Permission $def.Permission)) { throw [System.UnauthorizedAccessException]::new("Role '$Role' may not run '$Action'.") }

    switch ($Action) {
        'share-readonly' {
            $share = Get-NasuniShare -VolumeGuid $Params.volume_guid -FilerSerial $Params.filer_serial -ShareId $Params.share_id
            $before = [bool](Get-DashValue $share 'readonly')
            $target = "share '$(Get-DashValue $share 'name')' ($($Params.volume_guid)/$($Params.filer_serial)/$($Params.share_id))"
            $summary = "Change read-only from $before to $($Params.readonly) on $target"
            $phrase = [string](Get-DashValue $share 'name')
            $beforeState = @{ readonly = $before }
            $afterState = @{ readonly = $Params.readonly }
        }
        { $_ -in 'antivirus-ignore', 'antivirus-delete' } {
            $v = Get-NasuniAntivirusViolation -VolumeGuid $Params.volume_guid -FilerSerial $Params.filer_serial -AntivirusId $Params.antivirus_id
            $fpath = [string](Get-DashValue $v 'fpath')
            $target = "antivirus violation $($Params.antivirus_id) on $fpath"
            if ($Action -eq 'antivirus-delete') {
                $summary = "PERMANENTLY DELETE the file $fpath"
                $phrase = "DELETE $fpath"
            }
            else {
                $summary = "Ignore the violation for $fpath (the file is kept)"
                $phrase = 'IGNORE'
            }
            $beforeState = @{ violation = $true; fpath = $fpath }
            $afterState = @{ violation = $false }
        }
    }
    if ([string]::IsNullOrWhiteSpace($phrase)) { throw 'Could not build a confirmation phrase for this target.' }
    @{
        Id            = [guid]::NewGuid().ToString()
        Action        = $Action
        Title         = $def.Title
        Params        = $Params
        Target        = $target
        Summary       = $summary
        ConfirmPhrase = $phrase
        Before        = $beforeState
        After         = $afterState
        User          = $User
        CreatedUtc    = [datetime]::UtcNow
        ExpiresUtc    = [datetime]::UtcNow.AddSeconds($TtlSeconds)
    }
}

function Invoke-DashAction {
    <#
    .SYNOPSIS
        Step 2: re-checks the pending action, runs it, reads the result back and audits it.
    .DESCRIPTION
        Refused unless: the pending id matches, it has not expired, the same user confirms,
        the role still has permission, and the typed phrase matches exactly (ordinal).
        The pending record is single-use, so the caller must discard it whatever the outcome.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()][hashtable]$Pending,
        [Parameter(Mandatory)][string]$PendingId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TypedPhrase,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$AuditPath,
        [Parameter(Mandatory)][byte[]]$AuditKey
    )
    if ($null -eq $Pending -or $Pending.Id -ne $PendingId) { throw [System.InvalidOperationException]::new('No matching pending change. Start again from the preview.') }
    if ([datetime]::UtcNow -gt $Pending.ExpiresUtc) { throw [System.InvalidOperationException]::new('The preview has expired. Start again.') }
    if ($Pending.User -ne $User) { throw [System.UnauthorizedAccessException]::new('The change must be confirmed by the user who previewed it.') }
    $def = Get-DashActionDefinition -Name $Pending.Action
    if (-not (Test-DashPermission -Role $Role -Permission $def.Permission)) { throw [System.UnauthorizedAccessException]::new("Role '$Role' may not run '$($Pending.Action)'.") }
    if (-not [string]::Equals($TypedPhrase, $Pending.ConfirmPhrase, [StringComparison]::Ordinal)) {
        throw [System.ArgumentException]::new('The confirmation text does not match.')
    }

    $p = $Pending.Params
    $audit = [ordered]@{ user = $User; role = $Role; action = $Pending.Action; target = $Pending.Target; params = $p; before = $Pending.Before; after = $Pending.After }
    $result = @{ Success = $false; Verified = $false; Message = '' }
    if (-not $PSCmdlet.ShouldProcess($Pending.Target, $Pending.Title)) { return $result }
    try {
        switch ($Pending.Action) {
            'share-readonly' {
                $null = Set-NasuniShare -VolumeGuid $p.volume_guid -FilerSerial $p.filer_serial -ShareId $p.share_id -Body @{ readonly = $p.readonly } -Wait -Confirm:$false
                $now = Get-NasuniShare -VolumeGuid $p.volume_guid -FilerSerial $p.filer_serial -ShareId $p.share_id
                $result.Verified = ([bool](Get-DashValue $now 'readonly')) -eq $p.readonly
            }
            { $_ -in 'antivirus-ignore', 'antivirus-delete' } {
                $avAction = if ($Pending.Action -eq 'antivirus-delete') { 'delete_file' } else { 'ignore_violation' }
                $null = Remove-NasuniAntivirusViolation -VolumeGuid $p.volume_guid -FilerSerial $p.filer_serial -AntivirusId $p.antivirus_id -Action $avAction -Wait -Confirm:$false
                try { $null = Get-NasuniAntivirusViolation -VolumeGuid $p.volume_guid -FilerSerial $p.filer_serial -AntivirusId $p.antivirus_id; $result.Verified = $false }
                catch { $result.Verified = ($_.Exception.PSObject.Properties['StatusCode'] -and $_.Exception.StatusCode -eq 404) }
            }
        }
        $result.Success = $true
        $result.Message = if ($result.Verified) { 'Change applied and verified.' } else { 'Change submitted, but the read-back did not confirm it. Check the NMC.' }
        $audit.result = if ($result.Verified) { 'success' } else { 'unverified' }
    }
    catch {
        $result.Message = "Change failed: $(Protect-NasuniSensitiveData -InputObject $_.Exception.Message)"
        $audit.result = 'failure'
        $audit.error = $result.Message
    }
    finally {
        Write-DashAudit -Path $AuditPath -Key $AuditKey -Entry $audit
    }
    $result
}

#endregion

. (Join-Path -Path $PSScriptRoot -ChildPath 'Pages.ps1')

Export-ModuleMember -Function ConvertTo-DashHtml, Get-DashValue, Format-DashTable, Format-DashPage, ConvertTo-DashCsvSafe, ConvertTo-DashCsvRow,
Resolve-DashRole, Test-DashPermission, Write-DashAudit, Test-DashAuditChain, Read-DashAudit, Get-DashSnapshot,
Get-DashActionDefinition, Get-DashActionParameter, New-DashActionPreview, Invoke-DashAction,
Get-DashSectionDefinition, Get-DashSectionColumn, Format-DashSectionBody, Format-DashOverviewBody, Format-DashActionFormBody,
Format-DashPreviewBody, Format-DashAuditBody, Connect-DashNmc,
Write-DashLog, Get-DashReportCatalog, ConvertTo-DashReportParameter, New-DashReportJob, Invoke-DashReportJob, Remove-DashExpiredReportJob,
Test-DashJobAccess, Format-DashReportsBody

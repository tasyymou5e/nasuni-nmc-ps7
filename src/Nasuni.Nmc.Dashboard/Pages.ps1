# Page definitions and page-body builders, dot-sourced into Nasuni.Nmc.Dashboard.psm1.
# All dynamic values are encoded by Format-DashTable / ConvertTo-DashHtml.

function Get-DashSectionDefinition {
    <#
    .SYNOPSIS
        Returns the list sections (page and CSV report) with their snapshot key and columns.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $shareLink = {
        param($r)
        $ro = if ((Get-DashValue $r 'readonly') -eq $true) { 'false' } else { 'true' }
        '/actions/share-readonly?volume_guid={0}&filer_serial={1}&share_id={2}&readonly={3}' -f `
            [uri]::EscapeDataString([string](Get-DashValue $r 'volume_guid')), [uri]::EscapeDataString([string](Get-DashValue $r 'filer_serial_number')),
        [uri]::EscapeDataString([string](Get-DashValue $r 'id')), $ro
    }
    [ordered]@{
        filers        = @{ Title = 'Filers'; Key = 'Filers'; Columns = @(
                @{ Header = 'Serial'; Path = 'serial_number' }, @{ Header = 'Description'; Path = 'description' }, @{ Header = 'Build'; Path = 'build' },
                @{ Header = 'Management'; Path = 'management_state' }, @{ Header = 'Offline'; Path = 'status.offline' }, @{ Header = 'OS version'; Path = 'status.osversion' },
                @{ Header = 'Uptime (s)'; Path = 'status.uptime' })
        }
        volumes       = @{ Title = 'Volumes'; Key = 'Volumes'; Columns = @(
                @{ Header = 'Name'; Path = 'name' }, @{ Header = 'GUID'; Path = 'guid' }, @{ Header = 'Owner filer'; Path = 'filer_serial_number' },
                @{ Header = 'Provider'; Path = 'provider.name' }, @{ Header = 'Protocols'; Path = 'protocols.protocols' }, @{ Header = 'Auth policy'; Path = 'auth.policy' },
                @{ Header = 'Antivirus'; Path = 'antivirus_service.enabled' }, @{ Header = 'Remote access'; Path = 'remote_access.enabled' },
                @{ Header = 'Quota'; Path = 'quota' }, @{ Header = 'Snapshot retention'; Path = 'snapshot_retention.retain' })
        }
        shares        = @{ Title = 'Shares'; Key = 'Shares'; Columns = @(
                @{ Header = 'Name'; Path = 'name' }, @{ Header = 'Volume'; Path = 'volume_guid' }, @{ Header = 'Filer'; Path = 'filer_serial_number' },
                @{ Header = 'Path'; Path = 'path' }, @{ Header = 'Read-only'; Path = 'readonly' }, @{ Header = 'Browseable'; Path = 'browseable' },
                @{ Header = 'SMB encryption'; Path = 'smb_encrypt' }, @{ Header = 'Web access'; Path = 'browser_access' })
            OperatorColumns = @(@{ Header = 'Change'; Path = 'readonly'; Link = $shareLink; Label = 'Toggle read-only' })
        }
        antivirus     = @{ Title = 'Antivirus violations'; Key = 'Antivirus'; Columns = @(
                @{ Header = 'File'; Path = 'fpath' }, @{ Header = 'Volume name'; Path = 'vname' }, @{ Header = 'Volume'; Path = 'volume_guid' },
                @{ Header = 'Filer'; Path = 'filer_serial_number' }, @{ Header = 'Id'; Path = 'id' })
            OperatorColumns = @(@{ Header = 'Ignore'; Path = 'id'; Link = { param($r) Get-DashAntivirusLink -Row $r -Action 'antivirus-ignore' }; Label = 'Ignore' })
            AdminColumns = @(@{ Header = 'Delete file'; Path = 'id'; Link = { param($r) Get-DashAntivirusLink -Row $r -Action 'antivirus-delete' }; Label = 'Delete file' })
        }
        notifications = @{ Title = 'Notifications'; Key = 'Notifications'; Columns = @(
                @{ Header = 'Date'; Path = 'date' }, @{ Header = 'Priority'; Path = 'priority' }, @{ Header = 'Name'; Path = 'name' },
                @{ Header = 'Message'; Path = 'message' }, @{ Header = 'Origin'; Path = 'origin' }, @{ Header = 'Acknowledged'; Path = 'acknowledged' })
        }
        connections   = @{ Title = 'Volume connections'; Key = 'Connections'; Columns = @(
                @{ Header = 'Volume'; Path = 'volume_guid' }, @{ Header = 'Filer'; Path = 'filer_serial_number' }, @{ Header = 'Connected'; Path = 'connected' })
        }
        credentials   = @{ Title = 'Cloud credentials'; Key = 'Credentials'; Columns = @(
                @{ Header = 'Name'; Path = 'name' }, @{ Header = 'Provider'; Path = 'cloud_provider' }, @{ Header = 'Account'; Path = 'account' },
                @{ Header = 'Host'; Path = 'hostname' }, @{ Header = 'Filer'; Path = 'filer_serial_number' }, @{ Header = 'Status'; Path = 'status' },
                @{ Header = 'In use'; Path = 'in_use' })
        }
        # TODO(roadmap#1, #17): health items are undocumented, so columns are generic until verified.
        health        = @{ Title = 'Filer health'; Key = 'Health'; Columns = $null }   # generic: the NMC spec does not define health items
    }
}

function Get-DashAntivirusLink {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Row, [Parameter(Mandatory)][ValidateSet('antivirus-ignore', 'antivirus-delete')][string]$Action)
    '/actions/{0}?volume_guid={1}&filer_serial={2}&antivirus_id={3}' -f $Action,
    [uri]::EscapeDataString([string](Get-DashValue $Row 'volume_guid')), [uri]::EscapeDataString([string](Get-DashValue $Row 'filer_serial_number')),
    [uri]::EscapeDataString([string](Get-DashValue $Row 'id'))
}

function Get-DashGenericColumn {
    # Builds columns from the scalar top-level properties of the first items (for undocumented schemas).
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([AllowNull()][object[]]$Rows)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($r in @($Rows | Select-Object -First 20)) {
        if ($null -eq $r) { continue }
        foreach ($p in $r.PSObject.Properties) {
            if ($p.Name -eq 'links' -or $names.Contains($p.Name)) { continue }
            if ($null -eq $p.Value -or $p.Value -is [string] -or $p.Value -is [ValueType]) { $names.Add($p.Name) }
        }
    }
    , @($names | Select-Object -First 15 | ForEach-Object { @{ Header = $_; Path = $_ } })
}

function Get-DashSectionColumn {
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([Parameter(Mandatory)][hashtable]$Section, [AllowNull()][object[]]$Rows, [string]$Role, [switch]$ForCsv)
    $cols = if ($Section.Columns) { @($Section.Columns) } else { @(Get-DashGenericColumn -Rows $Rows) }
    if (-not $ForCsv) {
        if ($Section.ContainsKey('OperatorColumns') -and (Test-DashPermission -Role $Role -Permission Operate)) { $cols += $Section.OperatorColumns }
        if ($Section.ContainsKey('AdminColumns') -and (Test-DashPermission -Role $Role -Permission Destroy)) { $cols += $Section.AdminColumns }
    }
    , $cols
}

function Format-DashSectionBody {
    <#
    .SYNOPSIS
        Body for a list page: a CSV download link and the table.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Snapshot, [string]$Role)
    $sections = Get-DashSectionDefinition
    if (-not $sections.Contains($Name)) { throw "Unknown section '$Name'." }
    $s = $sections[$Name]
    # DEBUG NOTE (See docs/TROUBLESHOOTING.md, "Empty results"): wrap the whole if-expression in @().
    # `$x = if (...) { @() }` assigns $null, not an empty array, so .Count threw and an empty list page
    # (for example zero antivirus violations, the normal state) returned HTTP 500.
    $rows = @(if ($Snapshot.ContainsKey($s.Key)) { $Snapshot[$s.Key] })
    $cols = Get-DashSectionColumn -Section $s -Rows $rows -Role $Role
    "<p><a class=""button"" href=""/reports/$Name.csv"">Download CSV ($($rows.Count) rows)</a></p>" + (Format-DashTable -Rows $rows -Columns $cols)
}

function Format-DashOverviewBody {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Snapshot, [string]$Role, [string]$CsrfToken)
    $count = { param($k) if ($Snapshot.ContainsKey($k)) { @($Snapshot[$k]).Count } else { 0 } }
    $offline = @($Snapshot['Filers'] | Where-Object { (Get-DashValue $_ 'status.offline') -eq $true }).Count
    $disconnected = @($Snapshot['Connections'] | Where-Object { (Get-DashValue $_ 'connected') -eq $false }).Count
    $alerts = @($Snapshot['Notifications'] | Where-Object { (Get-DashValue $_ 'priority') -in @('error', 'alert') -and (Get-DashValue $_ 'acknowledged') -ne $true }).Count
    $tiles = @(
        @('Filers', (& $count 'Filers'), '/filers'), @('Offline filers', $offline, '/filers'),
        @('Volumes', (& $count 'Volumes'), '/volumes'), @('Disconnected volume/filer pairs', $disconnected, '/connections'),
        @('Shares', (& $count 'Shares'), '/shares'), @('Antivirus violations', (& $count 'Antivirus'), '/antivirus'),
        @('Unacknowledged errors and alerts', $alerts, '/notifications')
    )
    $html = '<div class="tiles">' + (($tiles | ForEach-Object {
                "<a class=""tile"" href=""$($_[2])""><span class=""n"">$(ConvertTo-DashHtml $_[1])</span><span>$(ConvertTo-DashHtml $_[0])</span></a>"
            }) -join '') + '</div>'
    $errors = @($Snapshot['Errors'])
    if ($errors.Count) {
        $html += '<h2>Data errors</h2><ul class="errors">' + (($errors | ForEach-Object { "<li>$(ConvertTo-DashHtml $_)</li>" }) -join '') + '</ul>'
    }
    if ($CsrfToken -and (Test-DashPermission -Role $Role -Permission Refresh)) {
        $html += "<form method=""post"" action=""/refresh""><input type=""hidden"" name=""pode.csrf"" value=""$(ConvertTo-DashHtml $CsrfToken)""><button type=""submit"">Refresh now</button></form>"
    }
    $html
}

function Format-DashActionFormBody {
    <#
    .SYNOPSIS
        First page of a change: shows what will be previewed and posts to the preview step.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][hashtable]$Params, [Parameter(Mandatory)][string]$CsrfToken)
    $def = Get-DashActionDefinition -Name $Action
    $hidden = ($Params.Keys | Sort-Object | ForEach-Object {
            $v = if ($Params[$_] -is [bool]) { ([string]$Params[$_]).ToLowerInvariant() } else { [string]$Params[$_] }
            "<input type=""hidden"" name=""$(ConvertTo-DashHtml $_)"" value=""$(ConvertTo-DashHtml $v)"">"
        }) -join ''
    $list = ($Params.Keys | Sort-Object | ForEach-Object { "<li><b>$(ConvertTo-DashHtml $_)</b>: $(ConvertTo-DashHtml $Params[$_])</li>" }) -join ''
    @"
<p>$(ConvertTo-DashHtml $def.Title). The next step reads the current state from the NMC and shows exactly what will change. Nothing is changed yet.</p>
<ul>$list</ul>
<form method="post" action="/actions/$(ConvertTo-DashHtml $Action)/preview">$hidden<input type="hidden" name="pode.csrf" value="$(ConvertTo-DashHtml $CsrfToken)"><button type="submit">Preview change</button></form>
"@
}

function Format-DashPreviewBody {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Pending, [Parameter(Mandatory)][string]$CsrfToken)
    $danger = if ($Pending.Action -eq 'antivirus-delete') { ' danger' } else { '' }
    @"
<div class="preview$danger"><p><b>$(ConvertTo-DashHtml $Pending.Summary)</b></p>
<table><tr><th>Before</th><td>$(ConvertTo-DashHtml ($Pending.Before | ConvertTo-Json -Compress))</td></tr>
<tr><th>After</th><td>$(ConvertTo-DashHtml ($Pending.After | ConvertTo-Json -Compress))</td></tr></table>
<p>To confirm, type <code>$(ConvertTo-DashHtml $Pending.ConfirmPhrase)</code> exactly. This preview expires at $(ConvertTo-DashHtml $Pending.ExpiresUtc.ToString('HH:mm:ss')) UTC.</p>
<form method="post" action="/actions/execute">
<input type="hidden" name="pending_id" value="$(ConvertTo-DashHtml $Pending.Id)">
<input type="hidden" name="pode.csrf" value="$(ConvertTo-DashHtml $CsrfToken)">
<input type="text" name="confirm" autocomplete="off" required>
<button type="submit">Apply change</button></form></div>
"@
}

function Format-DashAuditBody {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Chain, [AllowNull()][object[]]$Entries)
    $status = if ($Chain.Valid) { "<p class=""ok"">Chain verified: $($Chain.Count) records, no tampering detected.</p>" }
    else { "<p class=""bad"">CHAIN BROKEN at record $(ConvertTo-DashHtml $Chain.BrokenAtLine): $(ConvertTo-DashHtml $Chain.Reason)</p>" }
    $rows = @($Entries | Sort-Object ts -Descending)
    $status + (Format-DashTable -Rows $rows -Columns @(
            @{ Header = 'Time (UTC)'; Path = 'ts' }, @{ Header = 'User'; Path = 'user' }, @{ Header = 'Role'; Path = 'role' },
            @{ Header = 'Action'; Path = 'action' }, @{ Header = 'Target'; Path = 'target' }, @{ Header = 'Result'; Path = 'result' }, @{ Header = 'Error'; Path = 'error' }))
}

function Connect-DashNmc {
    <#
    .SYNOPSIS
        Ensures this runspace has an NMC connection with the requested account and mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Nmc,
        [Parameter(Mandatory)][pscredential]$Credential,
        [switch]$ReadOnly,
        [ValidateRange(0.05, 1.0)][double]$RateShare = 0.2
    )
    $c = Get-NasuniConnection
    if ($c.Connected -and $c.UserName -eq $Credential.UserName -and $c.ReadOnly -eq [bool]$ReadOnly) { return }
    $connArgs = @{ ComputerName = $Nmc.Host; Credential = $Credential; ReadOnly = [bool]$ReadOnly; RateShare = $RateShare }
    foreach ($k in 'Port', 'TrustedCaCertificatePath', 'PinnedSpkiSha256', 'RevocationMode', 'LogLevel') {
        if ($Nmc.ContainsKey($k) -and $Nmc[$k]) { $connArgs[$k] = $Nmc[$k] }
    }
    $null = Connect-Nasuni @connArgs
}

#region Reports page and background report jobs ------------------------------------
# Live reports run as background jobs in the 'report-runner' timer runspace, on the READ-ONLY
# NMC account: long reports never block web threads, and route runspaces never switch accounts
# (see TROUBLESHOOTING.md, Pode "change requests stalled"). Each job writes one CSV under
# ReportDirectory. Only the requester or an Admin can download it, and files expire.

# Reports the dashboard can run. path-info needs an input list, and shares-with-sizes refreshes
# path info (a POST); neither fits a read-only background job.
$script:DashExcludedReports = @('path-info', 'shares-with-sizes')
$script:DashReportParameters = @{
    'cifs-locks'       = @(@{ Name = 'FilerSerial'; Label = 'Filer serial (optional)'; Pattern = '^[A-Za-z0-9._\-]{1,64}$' })
    'unprotected-data' = @(@{ Name = 'MinBytes'; Label = 'Minimum bytes (optional)'; Pattern = '^\d{1,19}$' })
}

function Write-DashLog {
    <#
    .SYNOPSIS
        Writes a dashboard event through the Nasuni.Nmc logger (same redaction, sinks and ring
        buffer as the module, so Get-NasuniDiagnostic shows dashboard events too).
    #>
    [CmdletBinding()]
    param([ValidateSet('Debug', 'Info', 'Warning', 'Error')][string]$Level = 'Info', [Parameter(Mandatory)][string]$Message, [hashtable]$Data)
    $m = Get-Module Nasuni.Nmc
    if ($m) { & $m { param($l, $msg, $d) Write-NmcLog -Level $l -Message $msg -Data $d } $Level $Message $Data }
}

function Get-DashReportCatalog {
    # Reports offered on the Reports page, with any optional parameters.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    foreach ($r in @(Get-NasuniReportList | Where-Object { $_.Name -notin $script:DashExcludedReports })) {
        [pscustomobject]@{ Name = $r.Name; Description = $r.Description; ReplacesScript = $r.ReplacesScript
            Parameters = @(if ($script:DashReportParameters.ContainsKey($r.Name)) { $script:DashReportParameters[$r.Name] })
        }
    }
}

function ConvertTo-DashReportParameter {
    <#
    .SYNOPSIS
        Validates a report request from a form. Returns the report parameters, or throws.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    $entry = @(Get-DashReportCatalog | Where-Object Name -EQ $Name)
    if ($entry.Count -ne 1) { throw "Report '$Name' is not available in the dashboard." }
    $p = @{}
    foreach ($spec in $entry[0].Parameters) {
        $v = if ($Data.Contains($spec.Name)) { ([string]$Data[$spec.Name]).Trim() } else { '' }
        if (-not $v) { continue }
        if ($v -notmatch $spec.Pattern) { throw "Parameter '$($spec.Label)' is invalid." }
        $p[$spec.Name] = if ($spec.Name -eq 'MinBytes') { [long]$v } else { $v }
    }
    $p
}

function New-DashReportJob {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory job record only')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Parameters = @{}, [Parameter(Mandatory)][string]$User)
    [hashtable]::Synchronized(@{
            Id = [guid]::NewGuid().ToString('N'); Name = $Name; Parameters = $Parameters; User = $User; Status = 'queued'
            CreatedUtc = [datetime]::UtcNow; StartedUtc = $null; FinishedUtc = $null; Rows = $null; File = $null; Error = $null; Attempts = 0
        })
}

function Invoke-DashReportJob {
    <#
    .SYNOPSIS
        Runs one queued report job: connects (read-only), exports the CSV, and records the
        outcome on the job. Transient failures (network, 429, 5xx) are retried once after a delay.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Job,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][hashtable]$Nmc,
        [Parameter(Mandatory)][pscredential]$Credential,
        [double]$RateShare = 0.2,
        [ValidateRange(0, 300)][int]$RetryDelaySeconds = 10
    )
    if (-not (Test-Path -LiteralPath $Directory)) { $null = New-Item -ItemType Directory -Path $Directory -Force }
    $Job.Status = 'running'; $Job.StartedUtc = [datetime]::UtcNow
    $file = Join-Path -Path $Directory -ChildPath "$($Job.Id).csv"
    Write-DashLog -Level Info -Message 'Report job started' -Data @{ job = $Job.Id; report = $Job.Name; user = $Job.User }
    while ($true) {
        $Job.Attempts++
        try {
            Connect-DashNmc -Nmc $Nmc -Credential $Credential -ReadOnly -RateShare $RateShare
            $r = Export-NasuniReport -Name $Job.Name -Path $file -Parameters $Job.Parameters -Confirm:$false
            $Job.Rows = $r.Rows; $Job.File = $file; $Job.Status = 'done'
            break
        }
        catch {
            $ex = $_.Exception
            $status = if ($ex.PSObject.Properties['StatusCode']) { [int]$ex.StatusCode } else { -1 }
            $transient = $status -eq 0 -or $status -eq 429 -or $status -ge 500
            $msg = Protect-NasuniSensitiveData -InputObject $ex.Message
            if ($transient -and $Job.Attempts -lt 2) {
                Write-DashLog -Level Warning -Message 'Report job transient failure; retrying' -Data @{ job = $Job.Id; report = $Job.Name; error = $msg }
                Start-Sleep -Seconds $RetryDelaySeconds
                continue
            }
            $ref = if ($ex.PSObject.Properties['CorrelationId'] -and $ex.CorrelationId) { " (reference $($ex.CorrelationId))" } else { '' }
            $Job.Status = 'failed'; $Job.Error = "$msg$ref"
            Write-DashLog -Level Error -Message 'Report job failed' -Data @{ job = $Job.Id; report = $Job.Name; error = $msg }
            break
        }
    }
    $Job.FinishedUtc = [datetime]::UtcNow
    Write-DashLog -Level Info -Message 'Report job finished' -Data @{ job = $Job.Id; report = $Job.Name; status = $Job.Status; rows = $Job.Rows; ms = [int]($Job.FinishedUtc - $Job.StartedUtc).TotalMilliseconds }
}

function Remove-DashExpiredReportJob {
    <#
    .SYNOPSIS
        Deletes finished report jobs (and their CSV files) older than the retention period.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][System.Collections.Concurrent.ConcurrentDictionary[string, object]]$Jobs, [ValidateRange(1, 720)][int]$RetentionHours = 24)
    $cutoff = [datetime]::UtcNow.AddHours(-$RetentionHours)
    foreach ($kv in @($Jobs.ToArray())) {
        $j = $kv.Value
        if ($j.Status -in @('done', 'failed') -and $j.FinishedUtc -and $j.FinishedUtc -lt $cutoff) {
            if (-not $PSCmdlet.ShouldProcess($j.Id, 'Remove expired report job')) { continue }
            if ($j.File -and (Test-Path -LiteralPath $j.File)) { Remove-Item -LiteralPath $j.File -Force }
            $removed = $null
            $null = $Jobs.TryRemove($kv.Key, [ref]$removed)
        }
    }
}

function Test-DashJobAccess {
    # Only the requester or an Admin can see or download a job.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Job, [Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][string]$Role)
    $Job.User -eq $User -or $Role -eq 'Admin'
}

# TODO(roadmap#15): add <meta http-equiv=refresh> while jobs are queued (allowed by the CSP).
function Format-DashReportsBody {
    <#
    .SYNOPSIS
        The Reports page: run a live report, recent jobs, and quick exports of the snapshot.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$CsrfToken, [Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][string]$Role,
        [AllowNull()][object[]]$Jobs, [string]$Message)
    $sb = [System.Text.StringBuilder]::new()
    if ($Message) { $null = $sb.Append("<p class=""note"">$(ConvertTo-DashHtml $Message)</p>") }
    $null = $sb.Append('<h2>Run a live report</h2><p class="note">Reads every page from the NMC using the read-only account. The report runs in the background and appears below when it is ready. Secrets are redacted and spreadsheet formulas neutralised.</p>')
    $null = $sb.Append('<table><thead><tr><th>Report</th><th>Description</th><th>Replaces</th><th></th></tr></thead><tbody>')
    foreach ($r in @(Get-DashReportCatalog)) {
        $inputs = ($r.Parameters | ForEach-Object { "<label>$(ConvertTo-DashHtml $_.Label) <input type=""text"" name=""$(ConvertTo-DashHtml $_.Name)"" size=""14""></label> " }) -join ''
        $null = $sb.Append("<tr><td>$(ConvertTo-DashHtml $r.Name)</td><td>$(ConvertTo-DashHtml $r.Description)</td><td class=""note"">$(ConvertTo-DashHtml $r.ReplacesScript)</td><td><form method=""post"" action=""/reports/run"" class=""inline""><input type=""hidden"" name=""pode.csrf"" value=""$(ConvertTo-DashHtml $CsrfToken)""><input type=""hidden"" name=""report"" value=""$(ConvertTo-DashHtml $r.Name)"">$inputs<button type=""submit"">Run</button></form></td></tr>")
    }
    $null = $sb.Append('</tbody></table>')
    $visible = @($Jobs | Where-Object { $_ -and (Test-DashJobAccess -Job $_ -User $User -Role $Role) } | Sort-Object { $_.CreatedUtc } -Descending)
    $null = $sb.Append('<h2>Report jobs</h2>')
    if ($visible.Count -eq 0) { $null = $sb.Append('<p class="empty">No report jobs yet.</p>') }
    else {
        $null = $sb.Append('<table><thead><tr><th>Report</th><th>Requested by</th><th>Status</th><th>Rows</th><th>Requested (UTC)</th><th>Finished (UTC)</th><th>Result</th></tr></thead><tbody>')
        foreach ($j in $visible) {
            $result = switch ($j.Status) {
                'done' { "<a href=""/reports/jobs/$(ConvertTo-DashHtml $j.Id)"">Download CSV</a>" }
                'failed' { "<span class=""bad"">$(ConvertTo-DashHtml $j.Error)</span>" }
                default { '<span class="note">working...</span>' }
            }
            $fin = if ($j.FinishedUtc) { $j.FinishedUtc.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
            $null = $sb.Append("<tr><td>$(ConvertTo-DashHtml $j.Name)</td><td>$(ConvertTo-DashHtml $j.User)</td><td>$(ConvertTo-DashHtml $j.Status)</td><td>$(ConvertTo-DashHtml $j.Rows)</td><td>$(ConvertTo-DashHtml $j.CreatedUtc.ToString('yyyy-MM-dd HH:mm:ss'))</td><td>$(ConvertTo-DashHtml $fin)</td><td>$result</td></tr>")
        }
        $null = $sb.Append('</tbody></table><p class="note">Reload the page to update job status. Files are kept for a limited time.</p>')
    }
    $null = $sb.Append('<h2>Quick exports</h2><p class="note">Instant CSVs of the cached overview data.</p><ul>')
    foreach ($kv in (Get-DashSectionDefinition).GetEnumerator()) { $null = $sb.Append("<li><a href=""/reports/$($kv.Key).csv"">$(ConvertTo-DashHtml $kv.Value.Title)</a></li>") }
    $null = $sb.Append('</ul>')
    $sb.ToString()
}
#endregion

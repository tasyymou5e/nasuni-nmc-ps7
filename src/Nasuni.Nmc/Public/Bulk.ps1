# Bulk change engine: plan -> review -> execute with a resumable journal.
# Replaces the nasuni-labs bulk scripts, which ran 0..(Count-1) loops with no dry run, no
# per-item error handling and no record of what had already been changed.

function Get-NmcCommandEndpointMap {
    # Maps each generated cmdlet name to its manifest endpoint (cached per runspace).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if (-not $script:NmcCommandEndpoints) {
        $map = @{}
        foreach ($cmd in Get-Command -Module Nasuni.Nmc -CommandType Function) {
            if ($cmd.ScriptBlock.ToString() -match "Invoke-NmcEndpoint -Id '([A-Za-z]+)' ") { $map[$cmd.Name] = Get-NmcEndpoint -Id $Matches[1] }
        }
        $script:NmcCommandEndpoints = $map
    }
    $script:NmcCommandEndpoints
}

function New-NasuniBulkItem {
    <#
    .SYNOPSIS
        Describes one change in a bulk plan.
    .PARAMETER Key
        Stable, unique identifier for the item (for example "v1/s1/share:Finance"). The
        journal uses it to resume.
    .PARAMETER Command
        A generated write cmdlet, such as Set-NasuniShare. GET cmdlets are rejected.
    .PARAMETER Parameters
        Path parameters by PowerShell name, such as @{ VolumeGuid = '...'; FilerSerial = '...' },
        plus query parameters such as Action.
    .PARAMETER Body
        Request body, if the endpoint takes one.
    .EXAMPLE
        New-NasuniBulkItem -Key 'v1/s1/5' -Command Set-NasuniShare -Parameters @{ VolumeGuid = 'v1'; FilerSerial = 's1'; ShareId = '5' } -Body @{ readonly = $true }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan item only')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateLength(1, 512)][string]$Key,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [object]$Body,
        [string]$Summary,
        [object]$Before,
        [object]$After
    )
    $ep = (Get-NmcCommandEndpointMap)[$Command]
    if (-not $ep) { throw "'$Command' is not a Nasuni.Nmc endpoint cmdlet." }
    if ($ep.Method -eq 'GET') { throw "'$Command' is read-only and cannot be a bulk change." }
    foreach ($k in $Parameters.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$Parameters[$k])) { throw "Item '$Key': parameter '$k' is empty." }
    }
    [pscustomobject][ordered]@{
        Key         = $Key
        Command     = $Command
        Method      = $ep.Method
        Destructive = [bool]$ep.Destructive
        Parameters  = $Parameters
        Body        = if ($PSBoundParameters.ContainsKey('Body')) { $Body } else { $null }
        HasBody     = $PSBoundParameters.ContainsKey('Body')
        Summary     = if ($Summary) { $Summary } else { "$($ep.Method) $Command $Key" }
        Before      = $Before
        After       = $After
    }
}

function ConvertTo-NmcCanonical {
    # Recursively sorts dictionary/object keys so equal data always serialises identically.
    # DEBUG NOTE (See docs/TROUBLESHOOTING.md, "Plan hash"): a [hashtable] has no key order, and
    # JSON read back from a saved plan does, so hashing raw ConvertTo-Json output made a saved
    # plan fail its own integrity check.
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in ($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) { $o[$k] = ConvertTo-NmcCanonical -Value $Value[$k] }
        return $o
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($p in ($Value.PSObject.Properties | Sort-Object Name)) { $o[$p.Name] = ConvertTo-NmcCanonical -Value $p.Value }
        return $o
    }
    if ($Value -is [System.Collections.IEnumerable]) { return , @(foreach ($x in $Value) { ConvertTo-NmcCanonical -Value $x }) }
    [string]$Value
}

function Get-NmcBulkPlanHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items)
    $canon = foreach ($i in $Items) {
        $params = [ordered]@{}
        foreach ($k in ($i.Parameters.Keys | Sort-Object)) { $params[$k] = [string]$i.Parameters[$k] }
        [ordered]@{ Key = $i.Key; Command = $i.Command; Parameters = $params; Body = (ConvertTo-NmcCanonical -Value $i.Body) }
    }
    $json = ConvertTo-Json -InputObject @($canon) -Depth 20 -Compress
    [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function New-NasuniBulkPlan {
    <#
    .SYNOPSIS
        Wraps bulk items into a reviewable plan. Nothing is sent to the NMC.
    .DESCRIPTION
        Rejects duplicate keys. Records skipped candidates, with the reason, so the review
        shows what was deliberately left alone (for example "already read-only"). The plan
        hash binds it to its execution journal.
    .EXAMPLE
        $plan = New-NasuniSharePropertyPlan -FilerSerial ABC -Set @{ readonly = $true }
        $plan.Items | Format-Table Key, Summary
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan object only')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9 ._\-]{1,100}$')][string]$Name,
        [string]$Description,
        [AllowEmptyCollection()][object[]]$Items = @(),
        [AllowEmptyCollection()][object[]]$Skipped = @()
    )
    $items = @($Items | Where-Object { $null -ne $_ })
    $dupes = @($items | Group-Object Key | Where-Object Count -GT 1)
    if ($dupes.Count) { throw "Duplicate plan keys: $(($dupes.Name | Select-Object -First 5) -join ', ')" }
    [pscustomobject][ordered]@{
        Format      = 'nasuni-bulk-plan/1'
        Name        = $Name
        Description = $Description
        CreatedUtc  = [datetime]::UtcNow.ToString('o')
        CreatedBy   = [Environment]::UserName
        Destructive = [bool](@($items | Where-Object Destructive).Count)
        Items       = $items
        Skipped     = @($Skipped | Where-Object { $null -ne $_ })
        PlanHash    = Get-NmcBulkPlanHash -Items $items
    }
}

function Export-NasuniBulkPlan {
    <#
    .SYNOPSIS
        Saves a plan as JSON for review or approval, or for running later.
    .EXAMPLE
        Export-NasuniBulkPlan -Plan $plan -Path ./readonly-plan.json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][pscustomobject]$Plan, [Parameter(Mandatory)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write bulk plan')) { return }
    $json = $Plan | ConvertTo-Json -Depth 30
    # Refuse rather than silently redact: a redacted plan would no longer do what was reviewed.
    if ((Protect-NasuniSensitiveData -InputObject $Plan | ConvertTo-Json -Depth 30) -ne $json) {
        throw 'This plan contains secret-bearing fields (password, passphrase, secret, ...) and will not be written to disk.'
    }
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite') }
}

function Import-NasuniBulkPlan {
    <#
    .SYNOPSIS
        Loads a saved plan and re-validates every item against the endpoint manifest.
    .DESCRIPTION
        If the file was edited after export, the stored hash will not match. The plan is
        refused unless -AcceptModified is given, in which case a new hash is computed (and
        any existing journal for the old plan will no longer resume).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [switch]$AcceptModified)
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 30 -AsHashtable
    if ($raw.Format -ne 'nasuni-bulk-plan/1') { throw "$Path is not a nasuni-bulk-plan/1 file." }
    $items = foreach ($i in @($raw.Items)) {
        $p = @{ Key = [string]$i.Key; Command = [string]$i.Command; Parameters = [hashtable]$i.Parameters; Summary = [string]$i.Summary; Before = $i.Before; After = $i.After }
        if ($i.HasBody) { $p.Body = $i.Body }
        New-NasuniBulkItem @p
    }
    $plan = New-NasuniBulkPlan -Name $raw.Name -Description $raw.Description -Items @($items) -Skipped @($raw.Skipped)
    if ($plan.PlanHash -ne $raw.PlanHash -and -not $AcceptModified) {
        throw "Plan file $Path was modified after export (hash mismatch). Review it, then import with -AcceptModified."
    }
    $plan
}

function Read-NasuniBulkJournal {
    <#
    .SYNOPSIS
        Reads an execution journal: a header, then one record per item attempt.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Header = $null; Records = @(); Succeeded = @{} } }
    $header = $null
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if (-not $line) { continue }
        $r = $line | ConvertFrom-Json
        if ($r.type -eq 'header') { if (-not $header) { $header = $r } }
        elseif ($r.type -eq 'item') { $records.Add($r) }
    }
    $done = @{}
    foreach ($r in $records) { if ($r.status -eq 'succeeded') { $done[$r.key] = $true } }
    [pscustomobject]@{ Header = $header; Records = $records.ToArray(); Succeeded = $done }
}

function Write-NmcBulkJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    $isNew = -not (Test-Path -LiteralPath $Path)
    $line = ([pscustomobject]$Record | ConvertTo-Json -Compress -Depth 10)
    [System.IO.File]::AppendAllText($Path, $line + "`n", [System.Text.UTF8Encoding]::new($false))
    if ($isNew -and -not $IsWindows) { [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite') }
}

# TODO(roadmap#8): dashboard UI (upload, preview, approve, run, resume) and a second approver for destructive plans.
function Invoke-NasuniBulkPlan {
    <#
    .SYNOPSIS
        Dry-runs (default) or executes a bulk plan, journaling each item so the run can resume.
    .DESCRIPTION
        - Without -Execute, nothing is sent. Each item is listed as 'would-run', or as
          'already-done' when the journal shows it succeeded.
        - With -Execute, it confirms once for the whole plan (ConfirmImpact High; use
          -Confirm:$false in automation), then runs each item. Async changes are waited
          to completion, and every outcome is journaled.
        - A failed item is recorded and the run continues. After -MaxFailures failures,
          or on the first one with -StopOnError, the run stops with status 'aborted'.
        - Re-running with the same journal skips the items that already succeeded. A journal
          written for a different plan is refused.
        - -RetryMessagePattern retries an item (up to -MaxRetries, -RetryDelaySeconds apart) when
          its error matches, for example 'snapshot is taking place' for Global File Locking.
    .EXAMPLE
        Invoke-NasuniBulkPlan -Plan $plan -JournalPath ./run1.jsonl                      # dry run
        Invoke-NasuniBulkPlan -Plan $plan -JournalPath ./run1.jsonl -Execute             # asks once, then runs
        Invoke-NasuniBulkPlan -Plan $plan -JournalPath ./run1.jsonl -Execute -Confirm:$false   # resume after a failure
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [Parameter(Mandatory)][string]$JournalPath,
        [switch]$Execute,
        [ValidateRange(1, 100000)][int]$MaxFailures = 10,
        [switch]$StopOnError,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [string]$RetryMessagePattern,
        [ValidateRange(1, 3600)][int]$RetryDelaySeconds = 30,
        [ValidateRange(0, 100)][int]$MaxRetries = 5
    )

    if ($Plan.Format -ne 'nasuni-bulk-plan/1') { throw 'Not a bulk plan. Build one with a New-Nasuni*Plan function or Import-NasuniBulkPlan.' }
    $items = @($Plan.Items)
    if ((Get-NmcBulkPlanHash -Items $items) -ne $Plan.PlanHash) { throw 'Plan items were changed after the plan was built (hash mismatch). Rebuild the plan.' }

    $journal = Read-NasuniBulkJournal -Path $JournalPath
    if ($journal.Header -and $journal.Header.planHash -ne $Plan.PlanHash) {
        throw "Journal $JournalPath belongs to a different plan ($($journal.Header.plan)). Use a new journal path."
    }

    $summary = [ordered]@{
        Plan = $Plan.Name; Mode = $(if ($Execute) { 'execute' } else { 'dry-run' }); Total = $items.Count
        Succeeded = 0; Failed = 0; AlreadyDone = 0; WouldRun = 0; NotRun = 0; Status = 'completed'; JournalPath = $JournalPath
        Results = [System.Collections.Generic.List[object]]::new()
    }

    if (-not $Execute) {
        foreach ($i in $items) {
            $state = if ($journal.Succeeded.ContainsKey($i.Key)) { 'already-done' } else { 'would-run' }
            if ($state -eq 'already-done') { $summary.AlreadyDone++ } else { $summary.WouldRun++ }
            $summary.Results.Add([pscustomobject]@{ Key = $i.Key; Status = $state; Summary = $i.Summary; Error = $null })
        }
        $summary.Status = 'dry-run'
        return [pscustomobject]$summary
    }

    if ($items.Count -eq 0) { return [pscustomobject]$summary }
    if ((Get-NasuniConnection).ReadOnly) { throw 'The NMC connection is read-only. Reconnect without -ReadOnly to execute a plan.' }
    $remaining = @($items | Where-Object { -not $journal.Succeeded.ContainsKey($_.Key) })
    $what = "$($remaining.Count) of $($items.Count) change(s) in plan '$($Plan.Name)'" + $(if ($Plan.Destructive) { ' (includes DESTRUCTIVE changes)' } else { '' })
    if (-not $PSCmdlet.ShouldProcess($what, 'Execute bulk plan')) { return }

    if (-not $journal.Header) {
        Write-NmcBulkJournal -Path $JournalPath -Record ([ordered]@{ type = 'header'; plan = $Plan.Name; planHash = $Plan.PlanHash; items = $items.Count; startedUtc = [datetime]::UtcNow.ToString('o'); user = [Environment]::UserName })
    }

    foreach ($i in $items) {
        if ($journal.Succeeded.ContainsKey($i.Key)) {
            $summary.AlreadyDone++
            $summary.Results.Add([pscustomobject]@{ Key = $i.Key; Status = 'already-done'; Summary = $i.Summary; Error = $null })
            continue
        }
        if ($summary.Status -eq 'aborted') {
            $summary.NotRun++
            $summary.Results.Add([pscustomobject]@{ Key = $i.Key; Status = 'not-run'; Summary = $i.Summary; Error = $null })
            continue
        }
        Write-NmcLog -Level Debug -Message 'Bulk item start' -Data @{ plan = $Plan.Name; key = $i.Key; command = $i.Command }
        $splat = @{} + $i.Parameters
        if ($i.HasBody) { $splat.Body = $i.Body }
        $cmd = Get-Command -Name $i.Command -Module Nasuni.Nmc
        if ($cmd.Parameters.ContainsKey('Wait')) { $splat.Wait = $true; $splat.TimeoutSeconds = $TimeoutSeconds }
        try {
            # Transient NMC refusals (e.g. GFL 'snapshot is taking place') are retried when they
            # match -RetryMessagePattern; anything else fails the item immediately.
            $attempt = 0
            while ($true) {
                try { $out = & $cmd @splat -Confirm:$false; break }
                catch {
                    $attempt++
                    if (-not $RetryMessagePattern -or $attempt -gt $MaxRetries -or $_.Exception.Message -notmatch $RetryMessagePattern) { throw }
                    Write-NmcLog -Level Warning -Message 'Bulk item hit a retryable condition; waiting' -Data @{ key = $i.Key; attempt = $attempt; waitSeconds = $RetryDelaySeconds }
                    Start-Sleep -Seconds $RetryDelaySeconds
                }
            }
            $msgStatus = if ($out -and $out.PSObject.Properties['status']) { [string]$out.status } else { $null }
            Write-NmcBulkJournal -Path $JournalPath -Record ([ordered]@{ type = 'item'; key = $i.Key; status = 'succeeded'; message = $msgStatus; ts = [datetime]::UtcNow.ToString('o') })
            $summary.Succeeded++
            $summary.Results.Add([pscustomobject]@{ Key = $i.Key; Status = 'succeeded'; Summary = $i.Summary; Error = $null })
        }
        catch {
            $err = Protect-NmcText -Text $_.Exception.Message
            Write-NmcBulkJournal -Path $JournalPath -Record ([ordered]@{ type = 'item'; key = $i.Key; status = 'failed'; error = $err; ts = [datetime]::UtcNow.ToString('o') })
            $summary.Failed++
            $summary.Results.Add([pscustomobject]@{ Key = $i.Key; Status = 'failed'; Summary = $i.Summary; Error = $err })
            Write-NmcLog -Level Warning -Message 'Bulk item failed' -Data @{ plan = $Plan.Name; key = $i.Key; error = $err }
            if ($StopOnError -or $summary.Failed -ge $MaxFailures) {
                $summary.Status = 'aborted'
                Write-NmcBulkJournal -Path $JournalPath -Record ([ordered]@{ type = 'abort'; reason = "failures=$($summary.Failed)"; ts = [datetime]::UtcNow.ToString('o') })
            }
        }
    }
    if ($summary.Status -ne 'aborted' -and $summary.Failed -gt 0) { $summary.Status = 'completed-with-failures' }
    Write-NmcLog -Level Info -Message 'Bulk plan finished' -Data @{ plan = $Plan.Name; status = $summary.Status; succeeded = $summary.Succeeded; failed = $summary.Failed; alreadyDone = $summary.AlreadyDone; notRun = $summary.NotRun; journal = $JournalPath }
    [pscustomobject]$summary
}

# Shared report plumbing: flattening, CSV safety and the report registry.

function ConvertTo-NmcFlatRow {
    <#
    .SYNOPSIS
        Flattens nested objects into one level with dotted names (status.offline); arrays are
        joined with '; '. 'links' subtrees are dropped (API navigation only).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][object]$InputObject, [string]$Prefix = '', [System.Collections.Specialized.OrderedDictionary]$Into, [int]$Depth = 0)
    if ($null -eq $Into) { $Into = [ordered]@{} }
    if ($null -eq $InputObject) { return $Into }
    $props = if ($InputObject -is [System.Collections.IDictionary]) { $InputObject.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $InputObject[$_] } } }
    else { $InputObject.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } } }
    foreach ($p in $props) {
        if ($p.Name -eq 'links') { continue }
        $name = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
        $v = $p.Value
        if ($null -eq $v -or $v -is [string] -or $v -is [ValueType]) { $Into[$name] = $v }
        elseif ($v -is [System.Collections.IDictionary] -or $v -is [System.Management.Automation.PSCustomObject]) {
            if ($Depth -lt 6) { $null = ConvertTo-NmcFlatRow -InputObject $v -Prefix $name -Into $Into -Depth ($Depth + 1) }
        }
        elseif ($v -is [System.Collections.IEnumerable]) {
            $Into[$name] = (@($v) | ForEach-Object { if ($_ -is [string] -or $_ -is [ValueType]) { [string]$_ } else { $_ | ConvertTo-Json -Compress -Depth 5 } }) -join '; '
        }
        else { $Into[$name] = [string]$v }
    }
    $Into
}

function ConvertTo-NasuniCsvSafeValue {
    <#
    .SYNOPSIS
        Neutralises spreadsheet formula injection: a leading apostrophe for values starting
        with = + - @ tab or CR.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    # Real numbers (e.g. a quota of -1) are data, not formulas; only text is neutralised.
    if ($Value -is [ValueType] -and $Value -isnot [char]) { return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value) }
    $s = [string]$Value
    if ($s -match '^[=+\-@\t\r]') { return "'" + $s }
    $s
}

function Get-NmcValue {
    # Null-safe dotted-path read (status.platform.cpu.cores) from objects or dictionaries.
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Path)
    $cur = $InputObject
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) { $cur = if ($cur.Contains($part)) { $cur[$part] } else { $null } }
        else { $prop = $cur.PSObject.Properties[$part]; $cur = if ($prop) { $prop.Value } else { $null } }
    }
    , $cur
}

function ConvertTo-NmcReportRow {
    <#
    .SYNOPSIS
        Builds one report row. Columns map header -> dotted path (string) or scriptblock
        param($item). Arrays are joined with ';'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][object]$Item, [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Columns)
    $row = [ordered]@{}
    foreach ($h in $Columns.Keys) {
        $spec = $Columns[$h]
        $v = if ($spec -is [scriptblock]) { & $spec $Item } else { Get-NmcValue -InputObject $Item -Path ([string]$spec) }
        if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string] -and $v -isnot [System.Collections.IDictionary]) {
            $v = (@($v) | ForEach-Object { [string]$_ }) -join ';'
        }
        $row[$h] = $v
    }
    [pscustomobject]$row
}

function Get-NmcNameLookup {
    # serial -> filer description and guid -> volume name, fetched once per report.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $filers = @{}
    foreach ($f in @(Get-NasuniFilers)) { $k = [string](Get-NmcValue $f 'serial_number'); if ($k) { $filers[$k] = [string](Get-NmcValue $f 'description') } }
    $volumes = @{}
    $owners = @{}
    foreach ($v in @(Get-NasuniVolumes)) { $k = [string](Get-NmcValue $v 'guid'); if ($k) { $volumes[$k] = [string](Get-NmcValue $v 'name'); $owners[$k] = [string](Get-NmcValue $v 'filer_serial_number') } }
    @{ Filers = $filers; Volumes = $volumes; Owners = $owners }
}

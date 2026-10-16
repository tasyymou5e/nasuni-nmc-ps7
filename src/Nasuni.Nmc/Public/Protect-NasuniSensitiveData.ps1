# FILE: Public/Protect-NasuniSensitiveData.ps1. Field-level redaction of NMC data (secret,
# passphrase, password, token, ...) before it reaches an LLM, a browser, a CSV or the audit log.

function Protect-NasuniSensitiveData {
    <#
    .SYNOPSIS
        Returns a copy of NMC data with secret-bearing fields replaced by '***REDACTED***'.
    .DESCRIPTION
        Some NMC responses contain secrets in clear text. For example, cloud credentials carry
        a 'secret' field, filer settings carry 'escrow_passphrase', and SNMP settings carry
        'v3_password'. Use this before showing data to an LLM, a browser or a CSV export.

        A field is redacted when its name matches a sensitive pattern and its value is not a
        boolean or null. Booleans such as link_force_password describe settings, not secrets,
        so they are kept. The input is never modified.
    .PARAMETER InputObject
        Any object, array, hashtable or scalar returned by the NMC cmdlets.
    .EXAMPLE
        Get-NasuniCloudCredentials | Protect-NasuniSensitiveData
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][AllowNull()][object]$InputObject
    )
    process {
        # DEBUG NOTE (See docs/TROUBLESHOOTING.md, "Array wrapping"): the leading comma emits an array as ONE object.
        # Assign the result ($x = Protect-...), then use @($x). Writing @(Protect-...) adds a
        # second array level; the dashboard then showed one blank row instead of the real items.
        , (ConvertTo-NmcRedactedCopy -Value $InputObject -Depth 0)
    }
}

function Test-NmcSensitiveFieldName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    $Name -match '(?i)(secret|passphrase|password|passwd|token|private_key|key_file|access_key|api_key|credential_data)'
}

function ConvertTo-NmcRedactedCopy {
    [CmdletBinding()]
    param([AllowNull()][object]$Value, [int]$Depth)

    if ($null -eq $Value) { return $null }
    if ($Depth -gt 64) { return '***DEPTH-LIMIT***' }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }

    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $v = $Value[$key]
            if ((Test-NmcSensitiveFieldName -Name ([string]$key)) -and $null -ne $v -and $v -isnot [bool]) { $copy[$key] = '***REDACTED***' }
            else { $copy[$key] = ConvertTo-NmcRedactedCopy -Value $v -Depth ($Depth + 1) }
        }
        return $copy
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) {
            $v = $p.Value
            if ((Test-NmcSensitiveFieldName -Name $p.Name) -and $null -ne $v -and $v -isnot [bool]) { $copy[$p.Name] = '***REDACTED***' }
            else { $copy[$p.Name] = ConvertTo-NmcRedactedCopy -Value $v -Depth ($Depth + 1) }
        }
        return [pscustomobject]$copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $list.Add((ConvertTo-NmcRedactedCopy -Value $item -Depth ($Depth + 1))) }
        return , $list.ToArray()
    }
    $Value
}

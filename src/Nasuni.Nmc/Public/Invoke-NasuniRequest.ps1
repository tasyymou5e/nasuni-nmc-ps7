# FILE: Public/Invoke-NasuniRequest.ps1. Generic escape hatch for any NMC path, through the same pipeline.

function Invoke-NasuniRequest {
    <#
    .SYNOPSIS
        Calls any NMC v1.2 endpoint through the hardened pipeline.
    .DESCRIPTION
        This is the generic escape hatch underneath every generated cmdlet.
        - GET requests always run, even under -WhatIf, so lookups and login still work.
        - Non-GET requests go through ShouldProcess.
        - /auth/ paths are reserved for Connect-Nasuni and Disconnect-Nasuni.
        - -All streams every page of a list endpoint.
    .PARAMETER Path
        A path relative to /api/v1.2, for example /volumes/ or /filers/ABC123/.
    .PARAMETER Query
        Query parameters. Values are URL-encoded.
    .PARAMETER Body
        Request body, serialized with ConvertTo-Json (never built by string concatenation).
    .EXAMPLE
        Invoke-NasuniRequest -Path /volumes/ -All
    .EXAMPLE
        Invoke-NasuniRequest -Method PATCH -Path "/volumes/$guid/filers/$serial/shares/$id/" -Body @{ readonly = $true } -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query,
        [object]$Body,
        [switch]$All,
        [ValidateRange(1, 1000)][int]$PageSize = 200,
        [ValidateRange(0, [int]::MaxValue)][int]$MaxItems = 0
    )

    Assert-NmcPath -Path $Path
    if ($Path -like '/auth/*') { throw 'Use Connect-Nasuni / Disconnect-Nasuni for /auth/ endpoints.' }

    if ($Method -eq 'GET') {
        if ($All) {
            $q = if ($Query) { $Query } else { @{} }
            return Get-NmcPagedItem -Path $Path -Query $q -PageSize $PageSize -MaxItems $MaxItems
        }
        return Invoke-NmcRequest -Method GET -Path $Path -Query $Query
    }

    if ($All) { throw '-All applies only to GET requests.' }
    if ($script:NmcState.ReadOnly) { throw "Connection is read-only; $Method $Path was refused." }
    if (-not $PSCmdlet.ShouldProcess("$($script:NmcState.Host)$Path", $Method)) { return }

    $params = @{ Method = $Method; Path = $Path; Query = $Query }
    # -InputObject, not the pipeline: piping unrolls arrays, so @(@{...}) would be sent as {...}.
    if ($PSBoundParameters.ContainsKey('Body')) { $params.BodyJson = ConvertTo-Json -InputObject $Body -Depth 32 -Compress }
    $result = Invoke-NmcRequest @params -IncludeStatus
    if ($null -ne $result.Data) { return $result.Data }
    [pscustomobject]@{ StatusCode = $result.StatusCode; Location = $result.Location }
}

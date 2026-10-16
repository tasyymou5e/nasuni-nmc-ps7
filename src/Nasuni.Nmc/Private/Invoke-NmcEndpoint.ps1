# FILE: Private/Invoke-NmcEndpoint.ps1. Shared body of all 118 generated cmdlets: resolves the
# manifest entry, pages GETs, applies ShouldProcess once for writes, and waits for async messages.

function Get-NmcEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    if (-not $script:NmcEndpoints) {
        $data = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../Data/Endpoints.psd1')
        $map = @{}
        foreach ($ep in $data.Endpoints) { $map[$ep.Id] = $ep }
        $script:NmcEndpoints = $map
    }
    if (-not $script:NmcEndpoints.ContainsKey($Id)) { throw "Unknown NMC endpoint id '$Id'." }
    $script:NmcEndpoints[$Id]
}

function Invoke-NmcEndpoint {
    <#
    .SYNOPSIS
        Shared implementation behind every generated endpoint cmdlet.
    .DESCRIPTION
        - GET: list endpoints are paged to completion (or until -First); other GETs are a single call.
        - Writes: refused on read-only connections, then ShouldProcess is checked exactly once
          using the calling cmdlet's $PSCmdlet, so the user sees a single -Confirm prompt.
        - -Wait on an async endpoint polls the returned message to completion.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess is called on the caller-supplied $Cmdlet so there is exactly one prompt')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [hashtable]$PathValues = @{},
        [hashtable]$Query = @{},
        [object]$Body,
        [switch]$HasBody,
        [int]$First = 0,
        [int]$PageSize = 200,
        [switch]$Wait,
        [int]$TimeoutSeconds = 300
    )

    $ep = Get-NmcEndpoint -Id $Id
    $path = Resolve-NmcPathTemplate -Template $ep.Path -Values $PathValues
    $q = @{}
    foreach ($k in $Query.Keys) { if ($null -ne $Query[$k] -and '' -ne $Query[$k]) { $q[$k] = $Query[$k] } }

    if ($ep.Method -eq 'GET') {
        if ($ep.Paged) { return Get-NmcPagedItem -Path $path -Query $q -PageSize $PageSize -MaxItems $First }
        return Invoke-NmcRequest -Method GET -Path $path -Query $q
    }

    Assert-NmcConnected
    if ($script:NmcState.ReadOnly) { throw "Connection is read-only; $($ep.Method) $path was refused." }
    $target = "$($script:NmcState.Host)$path"
    $action = "$($ep.Method) ($($ep.Summary))"
    if (-not $Cmdlet.ShouldProcess($target, $action)) { return }

    $params = @{ Method = $ep.Method; Path = $path; Query = $q }
    # -InputObject, not the pipeline: piping unrolls arrays, so @(@{...}) would be sent as {...}.
    if ($HasBody) { $params.BodyJson = ConvertTo-Json -InputObject $Body -Depth 32 -Compress }
    $result = Invoke-NmcRequest @params -IncludeStatus
    Write-NmcLog -Level Info -Message 'NMC write submitted' -Data @{ endpoint = $Id; method = $ep.Method; path = $path; status = $result.StatusCode }

    $output = if ($null -ne $result.Data) { $result.Data } else { [pscustomobject]@{ StatusCode = $result.StatusCode; Location = $result.Location } }
    if ($Wait -and $ep.Async) { return ($output | Wait-NasuniMessage -TimeoutSeconds $TimeoutSeconds) }
    $output
}

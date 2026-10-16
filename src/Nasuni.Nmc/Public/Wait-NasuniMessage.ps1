# FILE: Public/Wait-NasuniMessage.ps1. Polls async NMC messages (synced / failure / 303 / expired
# 404). Never follows an href that points outside the connected NMC, so the token cannot leak.

function ConvertTo-NmcRelativePath {
    <#
    .SYNOPSIS
        Turns an absolute href returned by the NMC into a path under the connected base URI.
    .DESCRIPTION
        Refuses hrefs that point at any other host or scheme, so a malicious or misconfigured
        response can never make the client send its token to a different server.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Href)
    $base = [uri]($script:NmcState.BaseUri + '/')
    $target = $null
    if (-not [uri]::TryCreate($base, $Href, [ref]$target)) { throw "Invalid href '$Href'." }
    if ($target.Scheme -ne 'https' -or $target.Authority -ne $base.Authority -or
        -not $target.AbsolutePath.StartsWith($base.AbsolutePath, [StringComparison]::Ordinal)) {
        throw "Refusing to follow href outside the connected NMC API: $Href"
    }
    $relative = '/' + $target.AbsolutePath.Substring($base.AbsolutePath.Length)
    Assert-NmcPath -Path $relative
    $relative
}

function Wait-NasuniMessage {
    <#
    .SYNOPSIS
        Waits for an asynchronous NMC change to finish.
    .DESCRIPTION
        NMC write requests return 202 with { message = { id, status, links } }. This polls
        /messages/{id}/ until the status is 'synced' (it returns the message) or 'failure'
        (it throws). A 303 response means the change was applied, and is treated as synced.
        A 404 means the message expired before it was seen; the function returns a result
        with Status 'expired' so the caller can read the resource back and check.
        Status codes are checked as numbers, not by matching error text (that was the PS7
        bug in the original module).
    .PARAMETER InputObject
        The response from a write cmdlet, which carries .message or .Location.
    .PARAMETER TimeoutSeconds
        Any positive value is accepted and clamped to 1-3600.
    .EXAMPLE
        Invoke-NasuniRequest -Method PATCH -Path $p -Body $b | Wait-NasuniMessage
    #>
    [CmdletBinding(DefaultParameterSetName = 'Object')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Object')][object]$InputObject,
        [Parameter(Mandatory, ParameterSetName = 'Id')][ValidatePattern('^[A-Za-z0-9\-_]{1,128}$')][string]$MessageId,
        [int]$TimeoutSeconds = 300,
        [ValidateRange(1, 60)][int]$PollSeconds = 2
    )

    process {
        $timeout = [math]::Max(1, [math]::Min(3600, $TimeoutSeconds))

        $path = $null
        $message = $null
        if ($PSCmdlet.ParameterSetName -eq 'Id') {
            $path = "/messages/$([uri]::EscapeDataString($MessageId))/"
        }
        else {
            $names = @($InputObject.PSObject.Properties | ForEach-Object Name)
            if ($names -contains 'message' -and $InputObject.message) {
                $message = $InputObject.message
                $self = $null
                if (($null -ne $message.PSObject.Properties['links']) -and ($null -ne $message.links.PSObject.Properties['self'])) { $self = $message.links.self.href }
                if ($self) { $path = ConvertTo-NmcRelativePath -Href $self }
                elseif (($null -ne $message.PSObject.Properties['id'])) { $path = "/messages/$([uri]::EscapeDataString([string]$message.id))/" }
            }
            elseif ($names -contains 'Location' -and $InputObject.Location) {
                $path = ConvertTo-NmcRelativePath -Href ([string]$InputObject.Location)
            }
            elseif ($names -contains 'status' -and $names -contains 'id') {
                $message = $InputObject
                $path = "/messages/$([uri]::EscapeDataString([string]$InputObject.id))/"
            }
            if (-not $path) { throw 'Input has no message to wait on (expected .message, .Location or a message object).' }
            if ($message -and ($null -ne $message.PSObject.Properties['status']) -and $message.status -eq 'synced') { return $message }
        }

        $deadline = [datetime]::UtcNow.AddSeconds($timeout)
        while ($true) {
            try {
                $resp = Invoke-NmcRequest -Method GET -Path $path -IncludeStatus
            }
            catch [NasuniApiException] {
                if ($_.Exception.StatusCode -eq 404) {
                    Write-NmcLog -Level Warning -Message 'Message expired before completion was observed; verify the resource' -Data @{ path = $path }
                    return [pscustomobject]@{ status = 'expired'; path = $path; applied_resource = $null }
                }
                throw
            }

            if ($resp.StatusCode -eq 303) {
                return [pscustomobject]@{ status = 'synced'; path = $path; applied_resource = $resp.Location }
            }
            $msg = $resp.Data
            if ($msg -and ($null -ne $msg.PSObject.Properties['message'])) { $msg = $msg.message }
            $status = if ($msg -and ($null -ne $msg.PSObject.Properties['status'])) { [string]$msg.status } else { '' }

            switch ($status) {
                'synced' { return $msg }
                'failure' {
                    $detail = if (($null -ne $msg.PSObject.Properties['error']) -and $msg.error) { $msg.error | ConvertTo-Json -Compress -Depth 8 } else { 'no error detail' }
                    throw [NasuniApiException]::new("NMC reported failure for $path`: $(Protect-NmcText -Text $detail)", 200, 'GET', $path, '', $detail)
                }
            }

            if ([datetime]::UtcNow -ge $deadline) {
                throw "Timed out after $timeout s waiting for $path (last status '$status'). The change may still complete; check the NMC."
            }
            Start-Sleep -Seconds $PollSeconds
        }
    }
}

# FILE: Public/Test-NasuniFipsHost.ps1. FIPS-mode detection (Linux kernel flag + MD5 refusal;
# Windows FipsAlgorithmPolicy) and the assertion used at import and by every entry point.

function Test-NasuniFipsHost {
    <#
    .SYNOPSIS
        Reports whether this host's OS crypto provider is running in FIPS-approved mode.
    .DESCRIPTION
        PowerShell 7 / .NET has no cryptography of its own: on Linux it uses OpenSSL,
        on Windows it uses CNG/SChannel. FIPS compliance therefore depends on the OS
        being in FIPS mode. This function gathers evidence; it never changes settings.

        Linux:   /proc/sys/crypto/fips_enabled must be 1, and MD5 must be refused by
                 OpenSSL (proves the FIPS provider is actually enforcing).
        Windows: the FipsAlgorithmPolicy registry value must be 1. Note that .NET (Core)
                 on Windows does not block MD5 even in FIPS mode, so no MD5 probe is used.
        macOS:   there is no user-configurable FIPS mode; always reported as non-FIPS.
    .OUTPUTS
        PSCustomObject with IsFipsHost, Platform and Evidence.
    .EXAMPLE
        Test-NasuniFipsHost | Format-List
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $evidence = [System.Collections.Generic.List[string]]::new()
    $isFips = $false
    $platform = 'Unknown'

    # TODO(roadmap#2): only the non-FIPS dev path has run; verify on RHEL 9 fips=1 and on Windows with the FIPS GPO.
    if ($IsLinux) {
        $platform = 'Linux'
        $flagFile = '/proc/sys/crypto/fips_enabled'
        $kernelFips = $false
        if (Test-Path -LiteralPath $flagFile) {
            $value = (Get-Content -LiteralPath $flagFile -Raw).Trim()
            $kernelFips = $value -eq '1'
            $evidence.Add("fips_enabled=$value")
        }
        else {
            $evidence.Add('fips_enabled flag not present')
        }

        $md5Refused = $false
        try {
            # Deliberate non-approved algorithm probe: a FIPS-enforcing OpenSSL must refuse it.
            $probe = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::MD5)
            try { $probe.AppendData([byte[]]@(1)); $null = $probe.GetHashAndReset() } finally { $probe.Dispose() }
            $evidence.Add('MD5 permitted by OpenSSL (FIPS provider not enforcing)')
        }
        catch {
            $md5Refused = $true
            $evidence.Add('MD5 refused by OpenSSL')
        }
        $isFips = $kernelFips -and $md5Refused
    }
    elseif ($IsWindows) {
        $platform = 'Windows'
        $key = 'HKLM:\System\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy'
        $enabled = $null
        try { $enabled = (Get-ItemProperty -LiteralPath $key -Name Enabled -ErrorAction Stop).Enabled } catch { $enabled = $null }
        $evidence.Add("FipsAlgorithmPolicy.Enabled=$enabled")
        $isFips = $enabled -eq 1
    }
    elseif ($IsMacOS) {
        $platform = 'macOS'
        $evidence.Add('macOS has no configurable FIPS mode')
    }

    [pscustomobject]@{
        IsFipsHost = $isFips
        Platform   = $platform
        Evidence   = $evidence.ToArray()
    }
}

function Assert-NasuniFipsHost {
    <#
    .SYNOPSIS
        Throws unless the host is in FIPS mode (or the documented development override is active).
    .EXAMPLE
        Assert-NasuniFipsHost
    #>
    [CmdletBinding()]
    param()

    $result = Test-NasuniFipsHost
    if ($result.IsFipsHost) { return }
    if ($env:NASUNI_ALLOW_NON_FIPS_HOST -eq '1' -and $env:NASUNI_ENVIRONMENT -ne 'Production') {
        Write-NmcLog -Level Warning -Message 'Non-FIPS host permitted by development override' -Data @{ Evidence = $result.Evidence }
        return
    }
    throw "Host is not in FIPS-approved mode: $($result.Evidence -join '; ')"
}

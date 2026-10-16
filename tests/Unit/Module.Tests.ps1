BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    $script:Manifest = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../src/Nasuni.Nmc/Data/Endpoints.psd1')
}

Describe 'Module load' {
    It 'refuses to load on a non-FIPS host without the override' {
        if ((Test-NasuniFipsHost).IsFipsHost) { Set-ItResult -Skipped -Because 'host is in FIPS mode'; return }
        $modulePath = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/Nasuni.Nmc/Nasuni.Nmc.psd1')).Path
        $out = pwsh -NoProfile -Command "`$env:NASUNI_ALLOW_NON_FIPS_HOST='0'; try { Import-Module '$modulePath' -ErrorAction Stop; 'LOADED' } catch { 'REFUSED' }"
        $out | Should -Contain 'REFUSED'
    }

    It 'ignores the override when NASUNI_ENVIRONMENT=Production' {
        if ((Test-NasuniFipsHost).IsFipsHost) { Set-ItResult -Skipped -Because 'host is in FIPS mode'; return }
        $modulePath = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/Nasuni.Nmc/Nasuni.Nmc.psd1')).Path
        $out = pwsh -NoProfile -Command "`$env:NASUNI_ALLOW_NON_FIPS_HOST='1'; `$env:NASUNI_ENVIRONMENT='Production'; try { Import-Module '$modulePath' -ErrorAction Stop -WarningAction SilentlyContinue; 'LOADED' } catch { 'REFUSED' }"
        $out | Should -Contain 'REFUSED'
    }

    It 'reports platform evidence' {
        $r = Test-NasuniFipsHost
        $r.Platform | Should -BeIn @('Linux', 'Windows', 'macOS')
        @($r.Evidence).Count | Should -BeGreaterThan 0
    }
}

Describe 'Endpoint manifest coverage' {
    BeforeDiscovery {
        $m = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../src/Nasuni.Nmc/Data/Endpoints.psd1')
        $script:EndpointCases = foreach ($ep in $m.Endpoints) { if ($ep.Id -notin 'Login', 'Logout') { @{ Id = $ep.Id; Method = $ep.Method; Destructive = $ep.Destructive; Paged = $ep.Paged; Async = $ep.Async } } }
    }

    It 'has unique ids and 120 documented endpoints' {
        $ids = $script:Manifest.Endpoints.Id
        $ids.Count | Should -Be 120
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }

    It '<Id> has a cmdlet with help, a doc link and the right safety settings' -ForEach $script:EndpointCases {
        $cmd = Get-Command -Module Nasuni.Nmc | Where-Object {
            $_.ScriptBlock.ToString() -match "Invoke-NmcEndpoint -Id '$Id' "
        }
        @($cmd).Count | Should -Be 1
        $help = Get-Help $cmd.Name
        $help.Synopsis | Should -Not -BeNullOrEmpty
        ($help.relatedLinks.navigationLink.uri -join ' ') | Should -Match '^https://docs\.api\.nasuni\.com/'

        $binding = $cmd.ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        if ($Method -eq 'GET') {
            $binding.SupportsShouldProcess | Should -BeFalse
        }
        else {
            $binding.SupportsShouldProcess | Should -BeTrue
            $expected = if ($Destructive) { 'High' } else { 'Medium' }
            [string]$binding.ConfirmImpact | Should -Be $expected
        }
        if ($Method -eq 'GET' -and $Paged) { $cmd.Parameters.Keys | Should -Contain 'First' }
        if ($Method -ne 'GET' -and $Async) { $cmd.Parameters.Keys | Should -Contain 'Wait' }
    }

    It 'requires an explicit antivirus action with no default' {
        $p = (Get-Command Remove-NasuniAntivirusViolation).Parameters['Action']
        ($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -BeTrue
        ($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues | Should -Be @('delete_file', 'ignore_violation')
    }

    It 'exports exactly the manifest functions' {
        $psd1 = Import-PowerShellDataFile -LiteralPath $script:ModulePath
        (Get-Command -Module Nasuni.Nmc).Count | Should -Be $psd1.FunctionsToExport.Count
    }
}

Describe 'Path and query handling' {
    It 'URL-encodes path parameters' {
        InModuleScope Nasuni.Nmc {
            Resolve-NmcPathTemplate -Template '/filers/{filer_serial}/blocked-sources/usernames/{blocked_username}/' -Values @{ filer_serial = 'ABC 1'; blocked_username = 'dom\user' } |
                Should -Be '/filers/ABC%201/blocked-sources/usernames/dom%5Cuser/'
        }
    }
    It 'keeps folder separators in {path} but encodes each segment' {
        InModuleScope Nasuni.Nmc {
            Resolve-NmcPathTemplate -Template '/volumes/{volume_guid}/filers/{filer_serial}/path/{path}' -Values @{ volume_guid = 'g'; filer_serial = 's'; path = '/Finance/Q1 Reports/a#b' } |
                Should -Be '/volumes/g/filers/s/path/Finance/Q1%20Reports/a%23b'
        }
    }
    It 'rejects traversal in {path}' {
        InModuleScope Nasuni.Nmc {
            { Resolve-NmcPathTemplate -Template '/volumes/{volume_guid}/filers/{filer_serial}/path/{path}' -Values @{ volume_guid = 'g'; filer_serial = 's'; path = 'a/../../etc' } } | Should -Throw '*may not contain*'
        }
    }
    It 'rejects missing path values' {
        InModuleScope Nasuni.Nmc { { Resolve-NmcPathTemplate -Template '/volumes/{volume_guid}/' -Values @{} } | Should -Throw '*Missing value*' }
    }
    It 'rejects absolute URLs, double slashes and dot segments' -ForEach @(
        @{ P = 'https://evil.example/x' }, @{ P = '/volumes//x' }, @{ P = '/volumes/../auth/' }, @{ P = 'volumes/' }, @{ P = '/volumes/?limit=1' }
    ) {
        InModuleScope Nasuni.Nmc -Parameters @{ P = $P } { param($P) { Assert-NmcPath -Path $P } | Should -Throw }
    }
    It 'encodes and sorts query strings' {
        InModuleScope Nasuni.Nmc {
            ConvertTo-NmcQueryString -Query @{ offset = 0; limit = 50; action = 'a&b=c' } | Should -Be '?action=a%26b%3Dc&limit=50&offset=0'
            ConvertTo-NmcQueryString -Query @{} | Should -Be ''
        }
    }
}

Describe 'Redaction' {
    It 'removes tokens, passwords and Vault tokens' {
        InModuleScope Nasuni.Nmc {
            $text = 'Authorization: Token abc123def456 {"password":"hunter2!","token":"zzz"} X-Vault-Token: hvs.SECRETSECRET'
            $out = Protect-NmcText -Text $text
            $out | Should -Not -Match 'abc123def456|hunter2|hvs\.SECRET'
        }
    }
    It 'removes registered secret values wherever they appear' {
        InModuleScope Nasuni.Nmc {
            Register-NmcRedaction -Value 'registered-secret-value'
            Protect-NmcText -Text 'error near registered-secret-value here' | Should -Be 'error near *** here'
        }
    }
}

Describe 'Retry delay' {
    It 'uses the NMC body hint first' {
        InModuleScope Nasuni.Nmc { Get-NmcRetryDelay -StatusCode 429 -Body 'Request throttled. Expected available in 3.2 seconds' -Attempt 1 | Should -Be 5 }
    }
    It 'falls back to Retry-After' {
        InModuleScope Nasuni.Nmc { Get-NmcRetryDelay -StatusCode 429 -Body '' -RetryAfter '7' -Attempt 1 | Should -Be 8 }
    }
    It 'defaults to 30 s for 429 without hints' {
        InModuleScope Nasuni.Nmc { Get-NmcRetryDelay -StatusCode 429 -Attempt 1 | Should -Be 30 }
    }
    It 'backs off exponentially, capped at 30 s' {
        InModuleScope Nasuni.Nmc {
            $d = Get-NmcRetryDelay -StatusCode 503 -Attempt 2
            $d | Should -BeGreaterOrEqual 4
            $d | Should -BeLessThan 5
            Get-NmcRetryDelay -StatusCode 503 -Attempt 9 | Should -Be 30
        }
    }
}

Describe 'Rate limiter' {
    It 'limits writes to about 1 per second' {
        InModuleScope Nasuni.Nmc {
            $script:NmcState.Buckets = @{}
            $script:NmcState.RateShare = 1.0
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            1..3 | ForEach-Object { Wait-NmcRateLimit -Class Write }
            $sw.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 1.8
        }
    }
    It 'classifies requests' {
        InModuleScope Nasuni.Nmc {
            Get-NmcRateClass -Method POST -Path '/auth/login/' | Should -Be 'Auth'
            Get-NmcRateClass -Method GET -Path '/volumes/' | Should -Be 'Read'
            Get-NmcRateClass -Method DELETE -Path '/volumes/x/' | Should -Be 'Write'
        }
    }
}

Describe 'Connection validation' {
    It 'rejects host names with a scheme or path' -ForEach @(@{ H = 'https://nmc' }, @{ H = 'nmc/api' }, @{ H = '' }) {
        { Connect-Nasuni -ComputerName $H -Credential (Get-CanaryCredential) } | Should -Throw
    }
    It 'rejects a malformed SPKI pin' {
        { Connect-Nasuni -ComputerName nmc.example -Credential (Get-CanaryCredential) -PinnedSpkiSha256 'not-a-pin' } | Should -Throw
    }
    It 'requires https for Vault' {
        { Get-NasuniVaultCredential -VaultAddress 'http://vault:8200' -Mount kv -SecretPath x -AuthMethod Cert } | Should -Throw
    }
}

Describe 'Sensitive field redaction' {
    It 'redacts secrets at any depth but keeps booleans and the original intact' {
        $orig = [pscustomobject]@{
            cred_uuid = 'c1'; name = 'aws'; secret = 'AKIA-SECRET-VALUE'
            settings  = [pscustomobject]@{ escrow_passphrase = 'escrow-pass'; snmp = @{ v3_password = 'snmp-pass'; v3_user = 'u' } }
            browser_access_settings = [pscustomobject]@{ link_force_password = $true }
            items     = @([pscustomobject]@{ token = 'tok'; id = 1 }, [pscustomobject]@{ token = $null; id = 2 })
        }
        $r = Protect-NasuniSensitiveData -InputObject $orig
        $json = $r | ConvertTo-Json -Depth 10
        $json | Should -Not -Match 'AKIA-SECRET-VALUE|escrow-pass|snmp-pass|"tok"'
        $r.cred_uuid | Should -Be 'c1'
        $r.settings.snmp.v3_user | Should -Be 'u'
        $r.browser_access_settings.link_force_password | Should -BeTrue
        $r.items[1].token | Should -BeNullOrEmpty
        $orig.secret | Should -Be 'AKIA-SECRET-VALUE'
    }
    It 'passes scalars and null through' {
        Protect-NasuniSensitiveData -InputObject 5 | Should -Be 5
        Protect-NasuniSensitiveData -InputObject $null | Should -BeNullOrEmpty
    }
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')

    function Connect-Fake {
        param([switch]$ReadOnly)
        Connect-Nasuni -ComputerName nmc.test.example -Credential (Get-CanaryCredential) -ReadOnly:$ReadOnly | Out-Null
    }
    function Get-Calls([string]$Method, [string]$PathRegex) {
        , @($script:Fake.Calls | Where-Object { $_.Method -eq $Method -and $_.Path -match $PathRegex })
    }
}

Describe 'Fake NMC integration' {
    BeforeEach {
        Reset-FakeNmc
        Mock -ModuleName Nasuni.Nmc Invoke-NmcHttp {
            $b = Get-Variable -Name BodyJson -ValueOnly -ErrorAction Ignore
            Invoke-FakeNmc -Method $Method -Uri $Uri -Headers $Headers -BodyJson $b
        }
        Mock -ModuleName Nasuni.Nmc Start-Sleep { }
        Mock -ModuleName Nasuni.Nmc Wait-NmcRateLimit { }
    }

    AfterEach {
        InModuleScope Nasuni.Nmc { if ($script:NmcState.HttpClient) { Disconnect-Nasuni } }
    }

    Describe 'Login' {
        It 'builds valid JSON for a password containing quotes and backslashes' {
            Connect-Fake
            $login = Get-Calls POST '/auth/login/$'
            $login.Count | Should -Be 1
            ($login[0].BodyJson | ConvertFrom-Json).password | Should -BeExactly $script:CanaryPassword
            (Get-NasuniConnection).Connected | Should -BeTrue
        }
        It 'never returns the token or password from Get-NasuniConnection' {
            Connect-Fake
            $json = Get-NasuniConnection | ConvertTo-Json
            $json | Should -Not -Match ([regex]::Escape($script:CanaryToken))
            $json | Should -Not -Match 'Canary'
        }
        It 'sends the token in the Authorization: Token header' {
            Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/ABC/$' -Handler { New-FakeResponse -Body @{ serial_number = 'ABC' } }
            Connect-Fake
            $null = Get-NasuniFiler -FilerSerial ABC
            (Get-Calls GET '/filers/ABC/$')[0].Headers.Authorization | Should -Be "Token $script:CanaryToken"
        }
        It 'fails cleanly and keeps no state when the credentials are wrong' {
            $bad = [pscredential]::new('api-user', (InModuleScope Nasuni.Nmc { ConvertTo-NmcSecureString -Value 'wrong' }))
            { Connect-Nasuni -ComputerName nmc.test.example -Credential $bad } | Should -Throw '*401*'
            (Get-NasuniConnection).Connected | Should -BeFalse
        }
    }

    Describe 'Paging' {
        BeforeEach {
            $script:TotalItems = 450
            Add-FakeRoute -Method GET -Path '^/api/v1\.2/volumes/$' -Handler {
                param($req)
                $limit = [int]$req.Query['limit']; $offset = [int]$req.Query['offset']
                $end = [math]::Min($script:TotalItems, $offset + $limit)
                $items = @(); for ($i = $offset; $i -lt $end; $i++) { $items += @{ guid = "vol-$i" } }
                $next = if ($end -lt $script:TotalItems) { 'next-url' } else { $null }
                New-FakeResponse -Body @{ Paging = @{ total = $script:TotalItems; limit = $limit; offset = $offset; next = $next }; items = $items }
            }
        }
        It 'returns every item across pages' {
            Connect-Fake
            $all = @(Get-NasuniVolumes)
            $all.Count | Should -Be 450
            ($all.guid | Sort-Object -Unique).Count | Should -Be 450
            (Get-Calls GET '/volumes/$').Count | Should -Be 3
        }
        It 'returns nothing (and makes one call) for an empty list' {
            $script:TotalItems = 0
            Connect-Fake
            @(Get-NasuniVolumes).Count | Should -Be 0
            (Get-Calls GET '/volumes/$').Count | Should -Be 1
        }
        It 'stops at -First' {
            Connect-Fake
            @(Get-NasuniVolumes -First 10 -PageSize 5).Count | Should -Be 10
        }
        It 'handles an empty JSON object response under strict mode' {
            Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/$' -Handler { New-FakeResponse -Body '{}' }
            Connect-Fake
            Set-StrictMode -Version Latest
            $r = @(Get-NasuniFilers)
            $r.Count | Should -Be 1
            @($r[0].PSObject.Properties).Count | Should -Be 0
        }
        It 'stops when the server keeps returning the same page' {
            Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/$' -Handler {
                New-FakeResponse -Body @{ Paging = @{ total = 999; next = 'x' }; items = @(@{ serial_number = 'same' }) }
            }
            Connect-Fake
            @(Get-NasuniFilers).Count | Should -Be 1
            (Get-Calls GET '/filers/$').Count | Should -Be 2
        }
    }

    Describe 'Retry, throttling and errors' {
        It 'waits and retries after 429 using the body hint' {
            $script:n = 0
            Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/X/$' -Handler {
                $script:n++
                if ($script:n -eq 1) { return New-FakeResponse -Status 429 -Body 'Request throttled. Expected available in 2 seconds' }
                New-FakeResponse -Body @{ serial_number = 'X' }
            }
            Connect-Fake
            (Get-NasuniFiler -FilerSerial X).serial_number | Should -Be 'X'
            Should -Invoke -ModuleName Nasuni.Nmc Start-Sleep -ParameterFilter { $Milliseconds -eq 3000 } -Times 1
        }
        It 're-authenticates once on 401 and retries' {
            $script:n = 0
            Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/X/$' -Handler {
                $script:n++
                if ($script:n -eq 1) { return New-FakeResponse -Status 401 }
                New-FakeResponse -Body @{ serial_number = 'X' }
            }
            Connect-Fake
            (Get-NasuniFiler -FilerSerial X).serial_number | Should -Be 'X'
            (Get-Calls POST '/auth/login/$').Count | Should -Be 2
        }
        It 'gives up after a second 401' {
            Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/X/$' -Handler { New-FakeResponse -Status 401 }
            Connect-Fake
            { Get-NasuniFiler -FilerSerial X } | Should -Throw '*401*'
        }
        It 'retries GET on 503' {
            $script:n = 0
            Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/X/$' -Handler {
                $script:n++
                if ($script:n -lt 3) { return New-FakeResponse -Status 503 }
                New-FakeResponse -Body @{ serial_number = 'X' }
            }
            Connect-Fake
            (Get-NasuniFiler -FilerSerial X).serial_number | Should -Be 'X'
        }
        It 'does NOT retry a write on 500 (a retry could duplicate it)' {
            Add-FakeRoute -Method POST -Path '/shares/$' -Handler { New-FakeResponse -Status 500 -Body @{ error = 'boom' } }
            Connect-Fake
            { New-NasuniShare -VolumeGuid g -FilerSerial s -Body @{ name = 'x'; path = '/x' } -Confirm:$false } | Should -Throw '*500*'
            (Get-Calls POST '/shares/$').Count | Should -Be 1
        }
        It 'raises NasuniApiException with status, endpoint and correlation id' {
            Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/X/$' -Handler { New-FakeResponse -Status 404 -Body @{ error = 'nope' } }
            Connect-Fake
            try { Get-NasuniFiler -FilerSerial X; throw 'expected failure' }
            catch {
                $_.Exception.GetType().Name | Should -Be 'NasuniApiException'
                $_.Exception.StatusCode | Should -Be 404
                $_.Exception.Endpoint | Should -Be '/filers/X/'
                $_.Exception.CorrelationId | Should -Match '^[0-9a-f-]{36}$'
            }
        }
        It 'opens the circuit breaker after repeated failures' {
            Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/X/$' -Handler { New-FakeResponse -Status 503 }
            Connect-Fake
            { Get-NasuniFiler -FilerSerial X } | Should -Throw
            { Get-NasuniFiler -FilerSerial X } | Should -Throw '*circuit breaker*'
        }
        It 'rejects a non-JSON success body' {
            Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/X/$' -Handler { New-FakeResponse -Body '<html>proxy login</html>' }
            Connect-Fake
            { Get-NasuniFiler -FilerSerial X } | Should -Throw '*not valid JSON*'
        }
    }

    Describe 'Write safety' {
        It 'refuses writes on a read-only connection without sending anything' {
            Connect-Fake -ReadOnly
            { Remove-NasuniShare -VolumeGuid g -FilerSerial s -ShareId 1 -Confirm:$false } | Should -Throw '*read-only*'
            { Invoke-NasuniRequest -Method PATCH -Path '/volumes/g/' -Body @{} -Confirm:$false } | Should -Throw '*read-only*'
            (Get-Calls DELETE '.').Count + (Get-Calls PATCH '.').Count | Should -Be 0
        }
        It 'still logs out (revokes the token) on a read-only connection' {
            Connect-Fake -ReadOnly
            Disconnect-Nasuni
            $logout = Get-Calls POST '/auth/logout/$'
            $logout.Count | Should -Be 1
            $logout[0].Headers.Authorization | Should -Be "Token $script:CanaryToken"
        }
        It 'sends a one-element array body as a JSON array' {
            Add-FakeRoute -Method PATCH -Path '/volumes/g/$' -Handler { New-FakeResponse -Status 202 -Body @{ message = @{ id = 'm1'; status = 'pending' } } }
            Connect-Fake
            $null = Invoke-NasuniRequest -Method PATCH -Path '/volumes/g/' -Body @(@{ name = 'x' }) -Confirm:$false
            (Get-Calls PATCH '/volumes/g/$')[0].BodyJson | Should -BeExactly '[{"name":"x"}]'
        }
        It '-WhatIf sends no write, but login and GETs still work' {
            Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/X/$' -Handler { New-FakeResponse -Body @{ serial_number = 'X' } }
            Connect-Fake
            InModuleScope Nasuni.Nmc { $script:NmcState.Token = $null }
            Remove-NasuniShare -VolumeGuid g -FilerSerial s -ShareId 1 -WhatIf
            (Get-Calls DELETE '.').Count | Should -Be 0
            # The original module skipped the login POST under -WhatIf. Here a read with
            # WhatIfPreference on must still log in (the token was cleared above) and succeed.
            $WhatIfPreference = $true
            try { (Get-NasuniFiler -FilerSerial X).serial_number | Should -Be 'X' } finally { $WhatIfPreference = $false }
            (Get-Calls POST '/auth/login/$').Count | Should -Be 2
        }
        It 'blocks /auth/ paths in the generic request' {
            Connect-Fake
            { Invoke-NasuniRequest -Method POST -Path '/auth/login/' -Confirm:$false } | Should -Throw '*Connect-Nasuni*'
        }
        It 'sends DELETE for antivirus violations with the chosen action' {
            Add-FakeRoute -Method DELETE -Path '/antivirus-violations/42/$' -Handler { New-FakeResponse -Status 202 -Body @{ message = @{ id = 'm1'; status = 'pending' } } }
            Connect-Fake
            $null = Remove-NasuniAntivirusViolation -VolumeGuid g -FilerSerial s -AntivirusId 42 -Action ignore_violation -Confirm:$false
            (Get-Calls DELETE '/antivirus-violations/42/$')[0].Query['action'] | Should -Be 'ignore_violation'
        }
    }

    Describe 'Async messages' {
        BeforeEach {
            Add-FakeRoute -Method POST -Path '/shares/$' -Handler {
                New-FakeResponse -Status 202 -Body @{ message = @{ id = 'm1'; status = 'pending'; links = @{ self = @{ href = 'https://nmc.test.example/api/v1.2/messages/m1/' } } } }
            }
        }
        It 'waits until synced' {
            $script:n = 0
            Add-FakeRoute -Method GET -Path '/messages/m1/$' -Handler {
                $script:n++
                $s = if ($script:n -lt 3) { 'pending' } else { 'synced' }
                New-FakeResponse -Body @{ id = 'm1'; status = $s }
            }
            Connect-Fake
            (New-NasuniShare -VolumeGuid g -FilerSerial s -Body @{ name = 'x' } -Wait -Confirm:$false).status | Should -Be 'synced'
            (Get-Calls GET '/messages/m1/$').Count | Should -Be 3
        }
        It 'throws with the NMC error on failure' {
            Add-FakeRoute -Method GET -Path '/messages/m1/$' -Handler { New-FakeResponse -Body @{ id = 'm1'; status = 'failure'; error = @{ description = 'share name in use' } } }
            Connect-Fake
            { New-NasuniShare -VolumeGuid g -FilerSerial s -Body @{ name = 'x' } -Wait -Confirm:$false } | Should -Throw '*share name in use*'
        }
        It 'treats 303 as synced and returns the applied resource' {
            Add-FakeRoute -Method GET -Path '/messages/m1/$' -Handler { New-FakeResponse -Status 303 -Location 'https://nmc.test.example/api/v1.2/volumes/g/filers/s/shares/9/' }
            Connect-Fake
            $r = New-NasuniShare -VolumeGuid g -FilerSerial s -Body @{ name = 'x' } -Wait -Confirm:$false
            $r.status | Should -Be 'synced'
            $r.applied_resource | Should -Match '/shares/9/$'
        }
        It 'treats 303 as synced even when the redirect body is not JSON' {
            Add-FakeRoute -Method GET -Path '/messages/m1/$' -Handler { New-FakeResponse -Status 303 -Body '<html>See Other</html>' -Location 'https://nmc.test.example/api/v1.2/volumes/g/filers/s/shares/9/' }
            Connect-Fake
            (New-NasuniShare -VolumeGuid g -FilerSerial s -Body @{ name = 'x' } -Wait -Confirm:$false).status | Should -Be 'synced'
        }
        It 'reports an expired message (404) instead of a false failure' {
            Add-FakeRoute -Method GET -Path '/messages/m1/$' -Handler { New-FakeResponse -Status 404 }
            Connect-Fake
            (New-NasuniShare -VolumeGuid g -FilerSerial s -Body @{ name = 'x' } -Wait -Confirm:$false).status | Should -Be 'expired'
        }
        It 'refuses to follow a message link to another host' {
            Connect-Fake
            $evil = [pscustomobject]@{ message = [pscustomobject]@{ id = 'm1'; status = 'pending'; links = [pscustomobject]@{ self = [pscustomobject]@{ href = 'https://attacker.example/api/v1.2/messages/m1/' } } } }
            { $evil | Wait-NasuniMessage } | Should -Throw '*outside the connected NMC*'
            @($script:Fake.Calls | Where-Object { $_.Uri.Host -eq 'attacker.example' }).Count | Should -Be 0
        }
        It 'times out with a clear message' {
            Add-FakeRoute -Method GET -Path '/messages/m1/$' -Handler { New-FakeResponse -Body @{ id = 'm1'; status = 'pending' } }
            Connect-Fake
            { Wait-NasuniMessage -MessageId m1 -TimeoutSeconds 1 -PollSeconds 1 } | Should -Throw '*Timed out*'
        }
    }

    Describe 'Secrets never leak to logs or errors' {
        It 'keeps the canary password and token out of stderr and exception text' {
            $sw = [System.IO.StringWriter]::new()
            $orig = [Console]::Error
            [Console]::SetError($sw)
            try {
                Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/X/$' -Handler {
                    New-FakeResponse -Status 400 -Body ('{"detail":"bad","echo":"Authorization: Token ' + $script:CanaryToken + '","password":"' + $script:CanaryPassword.Replace('\', '\\').Replace('"', '\"') + '"}')
                }
                Connect-Nasuni -ComputerName nmc.test.example -Credential (Get-CanaryCredential) -LogLevel Debug | Out-Null
                $err = $null
                try { Get-NasuniFiler -FilerSerial X } catch { $err = $_.Exception.Message }
            }
            finally { [Console]::SetError($orig) }
            $logText = $sw.ToString()
            $logText | Should -Not -BeNullOrEmpty
            foreach ($text in @($logText, $err)) {
                $text | Should -Not -Match ([regex]::Escape($script:CanaryToken))
                $text | Should -Not -Match 'Canary'
            }
        }
    }
}

# Calls every generated endpoint cmdlet against the fake NMC and checks that it sends
# exactly the documented method and path (with encoded parameters), and that list
# endpoints page.
BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
}

Describe 'Every generated cmdlet hits its documented endpoint' {
    BeforeDiscovery {
        $m = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../src/Nasuni.Nmc/Data/Endpoints.psd1')
        $script:Cases = foreach ($ep in $m.Endpoints) {
            if ($ep.Id -in 'Login', 'Logout') { continue }
            @{ Id = $ep.Id; Method = $ep.Method; Path = $ep.Path; PathParams = $ep.PathParams; Paged = $ep.Paged; QueryParams = $ep.QueryParams }
        }
    }

    BeforeEach {
        Reset-FakeNmc
        Add-FakeRoute -Method GET -Path '.' -Handler {
            param($req)
            if ($req.Query['limit']) { return New-FakeResponse -Body @{ Paging = @{ total = 1; next = $null }; items = @(@{ id = 1 }) } }
            New-FakeResponse -Body @{ id = 1 }
        }
        foreach ($verb in 'POST', 'PUT', 'PATCH', 'DELETE') {
            Add-FakeRoute -Method $verb -Path '^/api/v1\.2/(?!auth/)' -Handler { New-FakeResponse -Status 202 -Body @{ message = @{ id = 'm1'; status = 'pending' } } }
        }
        Mock -ModuleName Nasuni.Nmc Invoke-NmcHttp {
            $b = Get-Variable -Name BodyJson -ValueOnly -ErrorAction Ignore
            Invoke-FakeNmc -Method $Method -Uri $Uri -Headers $Headers -BodyJson $b
        }
        Mock -ModuleName Nasuni.Nmc Wait-NmcRateLimit { }
        Mock -ModuleName Nasuni.Nmc Start-Sleep { }
        Connect-Nasuni -ComputerName nmc.test.example -Credential (Get-CanaryCredential) | Out-Null
    }

    AfterEach { InModuleScope Nasuni.Nmc { if ($script:NmcState.HttpClient) { Disconnect-Nasuni } } }

    It '<Id> sends <Method> <Path>' -ForEach $script:Cases {
        $cmd = Get-Command -Module Nasuni.Nmc | Where-Object { $_.ScriptBlock.ToString() -match "Invoke-NmcEndpoint -Id '$Id' " }
        $splat = @{}
        $expectedPath = $Path
        foreach ($pp in $PathParams) {
            $param = $cmd.Parameters.Values | Where-Object { $_.Aliases -contains $pp }
            $value = if ($pp -eq 'path') { 'Dept A/sub#1' } else { "v $pp" }
            $splat[$param.Name] = $value
            $encoded = if ($pp -eq 'path') { 'Dept%20A/sub%231' } else { [uri]::EscapeDataString($value) }
            $expectedPath = $expectedPath.Replace("{$pp}", $encoded)
        }
        if ($Id -eq 'RemoveAntivirusViolation') { $splat.Action = 'ignore_violation' }
        if ($Method -ne 'GET') { $splat.Body = @{ probe = $true }; $splat.Confirm = $false }

        $null = & $cmd.Name @splat

        $sent = @($script:Fake.Calls | Where-Object { $_.Method -eq $Method -and $_.Path -notlike '*/auth/*' })
        $sent.Count | Should -Be 1
        $sent[0].Uri.AbsolutePath | Should -Be ('/api/v1.2' + $expectedPath)
        $sent[0].Headers.Authorization | Should -Be "Token $script:CanaryToken"
        if ($Method -eq 'GET' -and $Paged) { $sent[0].Query['limit'] | Should -Not -BeNullOrEmpty }
        if ($Method -ne 'GET') { ($sent[0].BodyJson | ConvertFrom-Json).probe | Should -BeTrue }
    }
}

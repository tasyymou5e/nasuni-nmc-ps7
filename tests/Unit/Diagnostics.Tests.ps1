BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    $script:Dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nmc-diag-" + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $script:Dir
}
AfterAll {
    $null = Set-NasuniLogging -Level Warning -Path $null
    Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Logging and diagnostics' {
    BeforeEach {
        Reset-FakeNmc
        Add-FakeDataRoutes -Data (New-FakeSeedData)
        Mock -ModuleName Nasuni.Nmc Invoke-NmcHttp {
            $b = Get-Variable -Name BodyJson -ValueOnly -ErrorAction Ignore
            Invoke-FakeNmc -Method $Method -Uri $Uri -Headers $Headers -BodyJson $b
        }
        Mock -ModuleName Nasuni.Nmc Wait-NmcRateLimit { }
        Mock -ModuleName Nasuni.Nmc Start-Sleep { }
    }
    AfterEach { InModuleScope Nasuni.Nmc { if ($script:NmcState.HttpClient) { Disconnect-Nasuni } } }

    It 'writes redacted Debug traces with timing and correlation ids to a 0600 log file' {
        $log = Join-Path -Path $script:Dir -ChildPath 'debug.jsonl'
        $s = Set-NasuniLogging -Level Debug -Path $log
        $s.Level | Should -Be 'Debug'
        $orig = [Console]::Error; [Console]::SetError([System.IO.StringWriter]::new())
        try {
            Connect-Nasuni -ComputerName nmc.test.example -Credential (Get-CanaryCredential) | Out-Null
            $null = @(Get-NasuniVolumes)
        }
        finally { [Console]::SetError($orig) }
        $lines = @(Get-Content -LiteralPath $log | ForEach-Object { $_ | ConvertFrom-Json })
        $req = @($lines | Where-Object { $_.msg -eq 'NMC request' -and $_.data.path -eq '/volumes/' })
        $req.Count | Should -BeGreaterThan 0
        $req[0].data.ms | Should -Not -BeNullOrEmpty
        $req[0].data.correlationId | Should -Match '^[0-9a-f-]{36}$'
        (Get-Content -LiteralPath $log -Raw) | Should -Not -Match ([regex]::Escape($script:CanaryToken))
        (Get-Content -LiteralPath $log -Raw) | Should -Not -Match 'Canary'
        if (-not $IsWindows) { (Get-Item $log).UnixFileMode | Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite') }
        $null = Set-NasuniLogging -Level Warning -Path $null
    }

    It 'keeps API errors in the diagnostic snapshot with their correlation id, and no secrets' {
        $orig = [Console]::Error; [Console]::SetError([System.IO.StringWriter]::new())
        try {
            Connect-Nasuni -ComputerName nmc.test.example -Credential (Get-CanaryCredential) | Out-Null
            $cid = $null
            try { $null = Get-NasuniFiler -FilerSerial missing } catch { $cid = $_.Exception.CorrelationId }
        }
        finally { [Console]::SetError($orig) }
        $d = Get-NasuniDiagnostic
        $d.Stats.Failures | Should -BeGreaterThan 0
        $d.Stats.LastCorrelationId | Should -Be $cid
        $d.Connection.Connected | Should -BeTrue
        $d.PowerShell | Should -Not -BeNullOrEmpty
        @($d.RecentLog | Where-Object { $_.msg -eq 'NMC API error' -and $_.data.correlationId -eq $cid }).Count | Should -Be 1
        ($d | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($script:CanaryToken))
    }

    It 'logs report runs with row counts' {
        $orig = [Console]::Error; [Console]::SetError([System.IO.StringWriter]::new())
        try {
            Connect-Nasuni -ComputerName nmc.test.example -Credential (Get-CanaryCredential) | Out-Null
            $null = @(Get-NasuniReport -Name volumes)
        }
        finally { [Console]::SetError($orig) }
        $e = @((Get-NasuniDiagnostic -Last 200).RecentLog | Where-Object { $_.msg -eq 'Report finished' -and $_.data.report -eq 'volumes' })
        $e[-1].data.rows | Should -Be 2
    }
}

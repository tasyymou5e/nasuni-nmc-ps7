BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    $script:Dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nmc-rep-" + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $script:Dir
}
AfterAll { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Reports' {
    BeforeEach {
        Reset-FakeNmc
        Add-FakeDataRoutes -Data (New-FakeSeedData)
        Mock -ModuleName Nasuni.Nmc Invoke-NmcHttp {
            $b = Get-Variable -Name BodyJson -ValueOnly -ErrorAction Ignore
            Invoke-FakeNmc -Method $Method -Uri $Uri -Headers $Headers -BodyJson $b
        }
        Mock -ModuleName Nasuni.Nmc Wait-NmcRateLimit { }
        Mock -ModuleName Nasuni.Nmc Start-Sleep { }
        Connect-Nasuni -ComputerName nmc.test.example -Credential (Get-CanaryCredential) | Out-Null
    }
    AfterEach { InModuleScope Nasuni.Nmc { if ($script:NmcState.HttpClient) { Disconnect-Nasuni } } }

    It 'lists every report with the script it replaces' {
        $list = @(Get-NasuniReportList)
        $list.Count | Should -BeGreaterOrEqual 24
        foreach ($r in $list) { $r.ReplacesScript | Should -Not -BeNullOrEmpty; $r.Columns | Should -Not -BeNullOrEmpty }
    }

    It 'runs every report that needs no input, against the seeded estate' -ForEach @(
        @{ N = 'shares'; Count = 3 }, @{ N = 'nfs-exports'; Count = 2 }, @{ N = 'ftp-directories'; Count = 1 }, @{ N = 'cifs-clients'; Count = 1 }
        @{ N = 'cifs-locks'; Count = 1 }, @{ N = 'antivirus-violations'; Count = 2 }, @{ N = 'blocked-clients'; Count = 1 }, @{ N = 'filer-status'; Count = 3 }
        @{ N = 'health'; Count = 1 }, @{ N = 'messages'; Count = 3 }, @{ N = 'notifications'; Count = 4 }, @{ N = 'auto-cache-folders'; Count = 1 }
        @{ N = 'pinned-folders'; Count = 1 }, @{ N = 'folder-quotas'; Count = 2 }, @{ N = 'qos'; Count = 1 }, @{ N = 'volumes'; Count = 2 }
        @{ N = 'volume-detail'; Count = 2 }, @{ N = 'volume-auditing'; Count = 3 }, @{ N = 'snapshot-sync-schedule'; Count = 3 }, @{ N = 'file-alerts'; Count = 3 }
        @{ N = 'snapshot-access'; Count = 3 }, @{ N = 'ingest-progress'; Count = 3 }, @{ N = 'unprotected-data'; Count = 3 }
    ) {
        @(Get-NasuniReport -Name $N).Count | Should -Be $Count
    }

    It 'resolves volume and filer names, flattens nested fields and joins lists' {
        $s = @(Get-NasuniReport -Name shares)
        $fin = $s | Where-Object share_name -EQ 'Finance'
        $fin.volume_name | Should -Be 'Finance'
        $fin.filer_name | Should -Be 'NY'
        $fin.hosts_allow | Should -Be '10.0.0.1;10.0.0.2'
        $fin.veto_files | Should -Be 'Thumbs.db;.DS_Store'
        ($s | Where-Object share_name -EQ 'Archive').authRo_users | Should -Be 'DOM\bob'
        $st = (Get-NasuniReport -Name filer-status) | Where-Object SerialNumber -EQ 's1'
        $st.cpuCores | Should -Be 8
        $st.IpAddresses | Should -Be '10.1.1.1;10.1.1.2'
        (Get-NasuniReport -Name nfs-exports)[0].nfs_host_options | Should -Match 'host_option_id: 7; allowed_hosts: 10.2.0.0/16'
    }

    It 'never includes secrets' {
        (Get-NasuniReport -Name filer-status | ConvertTo-Json -Depth 5) | Should -Not -MatchExactly 'ESCROW-VALUE-7'
    }

    It 'sorts messages oldest first and computes QoS rows only for NMC-managed filers with rules' {
        (Get-NasuniReport -Name messages).id | Should -Be @('m1', 'm2', 'm3')
        $q = @(Get-NasuniReport -Name qos)
        $q[0].'Filer Serial' | Should -Be 's1'
        $q[0].Monday | Should -BeTrue
        $q[0].Start | Should -Be 0
    }

    It 'filters unprotected data by MinBytes and reads snapshot status per pair' {
        @(Get-NasuniReport -Name unprotected-data -Parameters @{ MinBytes = 10 }).Count | Should -Be 1
        ((Get-NasuniReport -Name ingest-progress) | Where-Object { $_.volume_guid -eq 'v1' -and $_.filer_serial_number -eq 's2' }).snapshot_status | Should -Be 'in_progress'
    }

    It 'validates report names and parameters' {
        { Get-NasuniReport -Name nope } | Should -Throw '*Unknown report*'
        { Get-NasuniReport -Name shares -Parameters @{ Bogus = 1 } } | Should -Throw '*does not take parameter*'
        @(Get-NasuniReport -Name cifs-locks -Parameters @{ FilerSerial = 's1' }).Count | Should -Be 1
    }

    It 'refreshes path info (POST, wait, GET), including volume-root paths' {
        $rows = @(Get-NasuniReport -Name path-info -Parameters @{ Paths = @(
                    [pscustomobject]@{ volume_guid = 'v1'; filer_serial_number = 's1'; path = '\' }
                    [pscustomobject]@{ volume_guid = 'v1'; filer_serial_number = 's1'; path = '\archive' }) })
        $rows.Count | Should -Be 2
        $rows[0].size | Should -Be 123456
        $rows[0].volume_name | Should -Be 'Finance'
        $rows[1].size | Should -Be 999
        (Get-FakeWrite POST '/path/').Count | Should -Be 2
    }

    It 'adds sizes to every share' {
        $rows = @(Get-NasuniReport -Name shares-with-sizes)
        $rows.Count | Should -Be 3
        ($rows | Where-Object share_name -EQ 'Archive').size | Should -Be 999
        ($rows | Where-Object share_name -EQ 'Eng').size | Should -Be 5
    }

    It 'writes a quoted, formula-safe CSV readable only by its owner' {
        $path = Join-Path -Path $script:Dir -ChildPath 'shares.csv'
        $r = Export-NasuniReport -Name shares -Path $path
        $r.Rows | Should -Be 3
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match ([regex]::Escape('"''=HYPERLINK'))
        $text | Should -Match '"a, b"'
        $back = @(Import-Csv -LiteralPath $path)
        $back.Count | Should -Be 3
        ($back | Where-Object share_name -EQ 'Archive').comment | Should -Be 'a, b'
        if (-not $IsWindows) { (Get-Item $path).UnixFileMode | Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite') }
        $vol = Join-Path -Path $script:Dir -ChildPath 'volumes.csv'
        $null = Export-NasuniReport -Name volumes -Path $vol
        ((Import-Csv $vol) | Where-Object guid -EQ 'v1').quota | Should -Be '-1'
    }

    It 'writes a header-only CSV for an empty report' {
        $script:FakeData['/api/v1.2/volumes/filers/ftp-directories/'] = [System.Collections.ArrayList]@()
        $path = Join-Path -Path $script:Dir -ChildPath 'ftp.csv'
        (Export-NasuniReport -Name ftp-directories -Path $path).Rows | Should -Be 0
        (Get-Content $path -Raw) | Should -Match '^"FtpId","Volume_GUID"'
    }

    It 'writes the EA settings bundle and reads volume/filer settings only once' {
        $out = Join-Path -Path $script:Dir -ChildPath 'bundle'
        $files = @(Export-NasuniReportBundle -Directory $out)
        $files.Count | Should -Be 10
        (Get-ChildItem $out -Filter *.csv).Count | Should -Be 10
        @($script:Fake.Calls | Where-Object { $_.Method -eq 'GET' -and $_.Path -eq '/api/v1.2/volumes/v1/filers/' }).Count | Should -Be 1
    }

    Context 'Unprotected-data alert state' {
        It 'alerts only after unprotected data has not gone down for N days, and tracks new pairs' {
            $state = Join-Path -Path $script:Dir -ChildPath ('state-' + [guid]::NewGuid() + '.json')
            @(Test-NasuniUnprotectedDataAlert -StatePath $state -Days 3).Count | Should -Be 0
            $s = Get-Content $state -Raw | ConvertFrom-Json -AsHashtable
            $s.Keys.Count | Should -Be 3
            $s['v1|s1'].since = [datetime]::UtcNow.AddDays(-4).ToString('o')
            $s | ConvertTo-Json | Set-Content $state
            $alerts = @(Test-NasuniUnprotectedDataAlert -StatePath $state -Days 3)
            $alerts.Count | Should -Be 1
            $alerts[0].volume_guid | Should -Be 'v1'
            $alerts[0].filer_serial_number | Should -Be 's1'
            ($script:FakeData['/api/v1.2/volumes/v1/filers/'][0]).status.data_not_yet_protected = 100
            @(Test-NasuniUnprotectedDataAlert -StatePath $state -Days 3).Count | Should -Be 0
        }
    }
}

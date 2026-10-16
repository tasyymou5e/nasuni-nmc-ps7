BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    $script:Dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nmc-plans-" + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $script:Dir
    function New-Csv([string]$Name, [object[]]$Rows) {
        $p = Join-Path -Path $script:Dir -ChildPath $Name
        # Export-Csv takes its columns from the FIRST object only; select the union so no column is lost.
        $cols = @($Rows | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
        $Rows | Select-Object -Property $cols | Export-Csv -LiteralPath $p -NoTypeInformation
        $p
    }
}
AfterAll { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Bulk plan builders' {
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
        $script:Journal = Join-Path -Path $script:Dir -ChildPath ("j-" + [guid]::NewGuid() + '.jsonl')
    }
    AfterEach { InModuleScope Nasuni.Nmc { if ($script:NmcState.HttpClient) { Disconnect-Nasuni } } }

    Context 'Share and export properties' {
        It 'sets a property only where it differs, and executes end to end' {
            $plan = New-NasuniSharePropertyPlan -FilerSerial s1 -Set @{ readonly = $true }
            $plan.Items.Count | Should -Be 1
            $plan.Items[0].Key | Should -Be 'v1/s1/share:11'
            $plan.Skipped.Count | Should -Be 1
            $plan.Skipped[0].Reason | Should -Match 'already'
            $r = Invoke-NasuniBulkPlan -Plan $plan -JournalPath $script:Journal -Execute -Confirm:$false
            $r.Succeeded | Should -Be 1
            $w = Get-FakeWrite PATCH 'shares/11/$'
            ($w[0].BodyJson | ConvertFrom-Json).readonly | Should -BeTrue
        }
        It 'covers all shares, Mac support, previous versions and block files' {
            (New-NasuniSharePropertyPlan -Set @{ fruit_enabled = $true }).Items.Count | Should -Be 2
            (New-NasuniSharePropertyPlan -Set @{ enable_previous_vers = $false }).Items.Count | Should -Be 1
            $bf = New-NasuniSharePropertyPlan -FilerSerial s1 -BlockFiles 'Thumbs.db', '.DS_Store'
            $bf.Items.Count | Should -Be 1
            $bf.Items[0].Body.veto_files | Should -Be "Thumbs.db`r`n.DS_Store"
        }
        It 'rejects unknown fields and empty requests' {
            { New-NasuniSharePropertyPlan -Set @{ id = 9 } } | Should -Throw '*not settable*'
            { New-NasuniSharePropertyPlan } | Should -Throw '*Nothing to set*'
            { New-NasuniExportPropertyPlan -Set @{ access_mode = 'wrong' } } | Should -Throw '*access_mode*'
        }
        It 'updates export access mode where it differs' {
            $p = New-NasuniExportPropertyPlan -Set @{ access_mode = 'no_root_squash' }
            $p.Items.Count | Should -Be 1
            $p.Items[0].Parameters.ExportId | Should -Be '1'
        }
    }

    Context 'Share create, delete, replicate, permissions' {
        It 'creates shares from the shares report format with safe JSON and defaults' {
            $csv = New-Csv 'create.csv' @(
                [pscustomobject]@{ shareid = ''; Volume_GUID = 'v1'; filer_serial_number = 's1'; share_name = 'New "Q" Share'; path = '\new\folder'; comment = 'has "quotes" and \back'; authAuthall = 'False'; authRw_groups = 'DOM\a;DOM\b'; veto_files = 'x.tmp;y.tmp' }
                [pscustomobject]@{ shareid = ''; Volume_GUID = 'v1'; filer_serial_number = 's1'; share_name = 'finance'; path = '\' }
                [pscustomobject]@{ shareid = ''; Volume_GUID = ''; filer_serial_number = 's1'; share_name = 'x'; path = '\' }
                [pscustomobject]@{ shareid = ''; Volume_GUID = 'v1'; filer_serial_number = 's1'; share_name = 'Bad'; path = '\'; readonly = 'maybe' })
            $p = New-NasuniShareCreatePlan -CsvPath $csv
            $p.Items.Count | Should -Be 1
            $p.Skipped.Count | Should -Be 3
            ($p.Skipped.Reason -join '|') | Should -Match 'already exists'
            ($p.Skipped.Reason -join '|') | Should -Match 'readonly'
            $b = $p.Items[0].Body
            $b.name | Should -Be 'New "Q" Share'
            $b.auth.authall | Should -BeFalse
            $b.auth.rw_groups | Should -Be @('DOM\a', 'DOM\b')
            $b.veto_files | Should -Be "x.tmp`r`ny.tmp"
            $b.browseable | Should -BeTrue
            $b.browser_access_settings.link_expire_limit | Should -Be 30
            $null = Invoke-NasuniBulkPlan -Plan $p -JournalPath $script:Journal -Execute -Confirm:$false
            ((Get-FakeWrite POST '/shares/$')[0].BodyJson | ConvertFrom-Json).comment | Should -Be 'has "quotes" and \back'
        }
        It 'deletes only shares whose id AND name match, as a destructive plan' {
            $csv = New-Csv 'delete.csv' @(
                [pscustomobject]@{ shareid = '12'; Volume_GUID = 'v1'; filer_serial_number = 's1'; share_name = 'Archive' }
                [pscustomobject]@{ shareid = '11'; Volume_GUID = 'v1'; filer_serial_number = 's1'; share_name = 'WrongName' }
                [pscustomobject]@{ shareid = '99'; Volume_GUID = 'v1'; filer_serial_number = 's1'; share_name = 'Gone' })
            $p = New-NasuniShareDeletePlan -CsvPath $csv
            $p.Destructive | Should -BeTrue
            $p.Items.Count | Should -Be 1
            $p.Items[0].Key | Should -Be 'v1/s1/share:12'
            ($p.Skipped.Reason -join '|') | Should -Match 'name mismatch'
            ($p.Skipped.Reason -join '|') | Should -Match 'no such share'
        }
        It 'replicates missing shares only into volumes the destination serves' {
            $p = New-NasuniShareReplicationPlan -SourceFilerSerial s1 -DestinationFilerSerial s2
            $p.Items.Count | Should -Be 2
            $p.Items[0].Parameters.FilerSerial | Should -Be 's2'
            $p.Items[0].Body.Contains('id') | Should -BeFalse
            { New-NasuniShareReplicationPlan -SourceFilerSerial s1 -DestinationFilerSerial s1 } | Should -Throw '*differ*'
            $back = New-NasuniShareReplicationPlan -SourceFilerSerial s2 -DestinationFilerSerial s1
            $back.Items.Count | Should -Be 0
            $back.Skipped[0].Reason | Should -Match 'not connected'
        }
        It 'applies permissions only for authAuthall=False rows that differ' {
            $csv = New-Csv 'perm.csv' @(
                [pscustomobject]@{ shareid = '12'; Volume_GUID = 'v1'; filer_serial_number = 's1'; authAuthall = 'False'; authRo_users = 'DOM\bob'; authRw_groups = 'DOM\fin' }
                [pscustomobject]@{ shareid = '11'; Volume_GUID = 'v1'; filer_serial_number = 's1'; authAuthall = 'False'; authRw_users = 'DOM\carol' }
                [pscustomobject]@{ shareid = '21'; Volume_GUID = 'v2'; filer_serial_number = 's2'; authAuthall = 'True' })
            $p = New-NasuniSharePermissionPlan -CsvPath $csv
            $p.Items.Count | Should -Be 1
            $p.Items[0].Body.auth.rw_users | Should -Be @('DOM\carol')
            ($p.Skipped.Reason -join '|') | Should -Match 'already match'
        }
    }

    Context 'Exports and host options' {
        It 'creates exports and skips existing names' {
            $csv = New-Csv 'exp.csv' @(
                [pscustomobject]@{ Volume_GUID = 'v1'; filer_serial_number = 's1'; export_name = 'nfs1'; path = '/x' }
                [pscustomobject]@{ Volume_GUID = 'v1'; filer_serial_number = 's1'; export_name = 'nfs9'; path = '/y'; allowed_hosts = '10.0.0.0/8;10.1.0.0/16'; access_mode = 'all_squash'; sec_options = 'sys krb5' })
            $p = New-NasuniExportCreatePlan -CsvPath $csv
            $p.Items.Count | Should -Be 1
            $p.Items[0].Body.hostspec | Should -Be '10.0.0.0/8,10.1.0.0/16'
            $p.Items[0].Body.sec_options | Should -Be @('sys', 'krb5')
        }
        It 'refuses ambiguous or unknown exports for host options (no stale id reuse)' {
            $csv = New-Csv 'hosts.csv' @(
                [pscustomobject]@{ filer_serial_number = 's1'; export_name = 'nfs1'; allowed_hosts = '10.3.0.0/16' }
                [pscustomobject]@{ filer_serial_number = 's9'; export_name = 'none'; allowed_hosts = '10.4.0.0/16' })
            $p = New-NasuniExportHostOptionPlan -CsvPath $csv
            $p.Items.Count | Should -Be 0
            ($p.Skipped.Reason -join '|') | Should -Match '2 exports match'
            ($p.Skipped.Reason -join '|') | Should -Match '0 exports match'
        }
    }

    Context 'Security operations' {
        It 'plans antivirus actions with filters; an empty selection is an empty plan' {
            (New-NasuniAntivirusPlan -Action ignore_violation).Items.Count | Should -Be 2
            $d = New-NasuniAntivirusPlan -Action delete_file -PathLike '*.exe'
            $d.Items.Count | Should -Be 1
            $d.Destructive | Should -BeTrue
            (New-NasuniAntivirusPlan -Action ignore_violation -VolumeGuid nope).Items.Count | Should -Be 0
            $null = Invoke-NasuniBulkPlan -Plan $d -JournalPath $script:Journal -Execute -Confirm:$false
            (Get-FakeWrite DELETE 'antivirus-violations/501/$')[0].Query['action'] | Should -Be 'delete_file'
        }
        It 'blocks an IP on NMC-managed filers not already blocking it, and unblocks where blocked' {
            $b = New-NasuniClientBlockPlan -IpAddress 10.9.9.9 -Block
            $b.Items.Count | Should -Be 1
            $b.Items[0].Parameters.FilerSerial | Should -Be 's2'
            $b.Items[0].Body.ip_address | Should -Be '10.9.9.9'
            $u = New-NasuniClientBlockPlan -IpAddress 10.9.9.9 -Unblock
            $u.Items.Count | Should -Be 1
            $u.Items[0].Command | Should -Be 'Unblock-NasuniFilerClient'
            { New-NasuniClientBlockPlan -IpAddress '10.0.0.300' -Block } | Should -Throw '*not a valid IP*'
        }
        It 'extracts distinct recent attack IPs (fractional seconds parsed) and pipes into a block plan' {
            $ips = @(Get-NasuniRansomwareAttackIp -Minutes 5)
            $ips | Should -Be @('10.6.6.6')
            (Get-NasuniRansomwareAttackIp -Minutes 5 | New-NasuniClientBlockPlan -Block).Items.Count | Should -Be 2
        }
    }

    Context 'Operations' {
        It 'deletes only messages with the requested code and status' {
            $p = New-NasuniMessageCleanupPlan -Code volumes_shares_add
            $p.Items.Count | Should -Be 2
            $null = Invoke-NasuniBulkPlan -Plan $p -JournalPath $script:Journal -Execute -Confirm:$false
            (Get-FakeWrite DELETE '/messages/').Count | Should -Be 2
        }
        It 'plans GFL enable/disable with de-duplication and path validation' {
            $e = New-NasuniGlobalLockPlan -VolumeGuid v1 -Path '/a', 'a/', '/b', '/', '/x/../y' -Mode advanced
            $e.Items.Count | Should -Be 2
            $e.Items[0].Body.path | Should -Be '/a'
            $e.Items[0].Body.mode | Should -Be 'advanced'
            ($e.Skipped.Reason -join '|') | Should -Match 'duplicate'
            ($e.Skipped.Reason -join '|') | Should -Match 'invalid path'
            $csv = New-Csv 'gfl.csv' @([pscustomobject]@{ Path = '/c'; Mode = 'asynchronous' }, [pscustomobject]@{ Path = '/d'; Mode = 'bogus' })
            $c = New-NasuniGlobalLockPlan -VolumeGuid v1 -CsvPath $csv
            $c.Items.Count | Should -Be 1
            $dis = New-NasuniGlobalLockPlan -VolumeGuid v1 -Path '/a' -Disable
            $dis.Items[0].Command | Should -Be 'Disable-NasuniGlobalLockFolder'
            $null = Invoke-NasuniBulkPlan -Plan $dis -JournalPath $script:Journal -Execute -Confirm:$false
            (Get-FakeWrite DELETE '/global-lock-folders/a$').Count | Should -Be 1
        }
        It 'retries GFL while a snapshot is running, then succeeds' {
            $script:Busy = 2
            Add-FakeRoute -Method POST -Path '/global-lock-folders/$' -Handler {
                if ($script:Busy -gt 0) { $script:Busy--; return New-FakeResponse -Status 202 -Body @{ message = @{ id = 'mbusy'; status = 'pending' } } }
                New-FakeResponse -Status 202 -Body @{ message = @{ id = 'mw'; status = 'pending' } }
            }
            Add-FakeRoute -Method GET -Path '/messages/mbusy/$' -Handler { New-FakeResponse -Body @{ id = 'mbusy'; status = 'failure'; error = @{ description = 'A snapshot is taking place, try later' } } }
            $p = New-NasuniGlobalLockPlan -VolumeGuid v1 -Path '/a'
            $r = Invoke-NasuniBulkPlan -Plan $p -JournalPath $script:Journal -Execute -Confirm:$false -RetryMessagePattern 'snapshot is taking place' -RetryDelaySeconds 1
            $r.Succeeded | Should -Be 1
            (Get-FakeWrite POST '/global-lock-folders/$').Count | Should -Be 3
            $script:Busy = 1
            $r2 = Invoke-NasuniBulkPlan -Plan $p -JournalPath (Join-Path $script:Dir 'nr.jsonl') -Execute -Confirm:$false
            $r2.Failed | Should -Be 1
        }
        It 'changes a quota only with an unambiguous volume and path' {
            $p = New-NasuniFolderQuotaPlan -VolumeGuid v1 -Path '\Finance\Projects\' -Limit 500
            $p.Items.Count | Should -Be 1
            $p.Items[0].Body.limit | Should -Be 500
            (New-NasuniFolderQuotaPlan -VolumeGuid v1 -Path '/Finance/Projects' -Limit 100).Skipped.Count | Should -Be 1
            { New-NasuniFolderQuotaPlan -VolumeGuid v9 -Path '/Finance/Projects' -Limit 1 } | Should -Throw '*0 folder quotas match*'
        }
        It 'applies audit settings only to online pairs that differ' {
            $p = New-NasuniVolumeAuditPlan -Auditing @{ enabled = $true; events = @{ delete = $true } }
            $p.Items.Count | Should -Be 0
            ($p.Skipped.Reason -join '|') | Should -Match 'already match'
            ($p.Skipped.Reason -join '|') | Should -Match 'offline'
            $p2 = New-NasuniVolumeAuditPlan -Auditing @{ enabled = $true; events = @{ delete = $true } } -IncludeOfflineFilers
            $p2.Items.Count | Should -Be 2
            $p2.Items[0].Body.auditing.enabled | Should -BeTrue
        }
    }
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../src/Nasuni.Nmc.Dashboard/Nasuni.Nmc.Dashboard.psm1') -Force
    $script:Dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nmc-dashrep-" + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $script:Dir
}
AfterAll { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Dashboard report jobs' {
    BeforeEach {
        Reset-FakeNmc
        Add-FakeDataRoutes -Data (New-FakeSeedData)
        Mock -ModuleName Nasuni.Nmc Invoke-NmcHttp {
            $b = Get-Variable -Name BodyJson -ValueOnly -ErrorAction Ignore
            Invoke-FakeNmc -Method $Method -Uri $Uri -Headers $Headers -BodyJson $b
        }
        Mock -ModuleName Nasuni.Nmc Wait-NmcRateLimit { }
        Mock -ModuleName Nasuni.Nmc Start-Sleep { }
        $script:Nmc = @{ Host = 'nmc.test.example'; RevocationMode = 'NoCheck' }
    }
    AfterEach { InModuleScope Nasuni.Nmc { if ($script:NmcState.HttpClient) { Disconnect-Nasuni } } }

    It 'offers every report except the two that need writes or input' {
        $names = @(Get-DashReportCatalog).Name
        $names | Should -Not -Contain 'path-info'
        $names | Should -Not -Contain 'shares-with-sizes'
        $names | Should -Contain 'shares'
        (@(Get-DashReportCatalog) | Where-Object Name -EQ 'cifs-locks').Parameters[0].Name | Should -Be 'FilerSerial'
    }

    It 'validates report requests' {
        (ConvertTo-DashReportParameter -Name 'unprotected-data' -Data @{ MinBytes = '1024' }).MinBytes | Should -Be 1024
        (ConvertTo-DashReportParameter -Name 'shares' -Data @{ MinBytes = 'ignored' }).Count | Should -Be 0
        { ConvertTo-DashReportParameter -Name 'unprotected-data' -Data @{ MinBytes = '-5' } } | Should -Throw '*invalid*'
        { ConvertTo-DashReportParameter -Name 'cifs-locks' -Data @{ FilerSerial = '../x' } } | Should -Throw '*invalid*'
        { ConvertTo-DashReportParameter -Name 'path-info' -Data @{} } | Should -Throw '*not available*'
    }

    It 'runs a job on a read-only connection and writes the CSV' {
        $job = New-DashReportJob -Name volumes -User alice
        Invoke-DashReportJob -Job $job -Directory $script:Dir -Nmc $script:Nmc -Credential (Get-CanaryCredential) -RetryDelaySeconds 0
        $job.Status | Should -Be 'done'
        $job.Rows | Should -Be 2
        (Import-Csv -LiteralPath $job.File).Count | Should -Be 2
        (Get-NasuniConnection).ReadOnly | Should -BeTrue
    }

    It 'retries a transient failure once, and reports a permanent one with its reference' {
        $script:Fails = 1
        Mock -ModuleName Nasuni.Nmc.Dashboard Export-NasuniReport {
            if ($script:Fails -gt 0) { $script:Fails--; throw (InModuleScope Nasuni.Nmc { [NasuniApiException]::new('boom', 503, 'GET', '/volumes/', 'cid-1', '') }) }
            [pscustomobject]@{ Rows = 7 }
        }
        $job = New-DashReportJob -Name volumes -User alice
        Invoke-DashReportJob -Job $job -Directory $script:Dir -Nmc $script:Nmc -Credential (Get-CanaryCredential) -RetryDelaySeconds 0
        $job.Status | Should -Be 'done'
        $job.Attempts | Should -Be 2

        Mock -ModuleName Nasuni.Nmc.Dashboard Export-NasuniReport { throw (InModuleScope Nasuni.Nmc { [NasuniApiException]::new('denied', 403, 'GET', '/volumes/', 'cid-2', '') }) }
        $job2 = New-DashReportJob -Name volumes -User alice
        Invoke-DashReportJob -Job $job2 -Directory $script:Dir -Nmc $script:Nmc -Credential (Get-CanaryCredential) -RetryDelaySeconds 0
        $job2.Status | Should -Be 'failed'
        $job2.Attempts | Should -Be 1
        $job2.Error | Should -Match 'reference cid-2'
    }

    It 'limits job visibility to the requester and admins, and encodes the page' {
        $mine = New-DashReportJob -Name '<b>shares' -User alice
        $theirs = New-DashReportJob -Name volumes -User bob
        Test-DashJobAccess -Job $theirs -User alice -Role Operator | Should -BeFalse
        Test-DashJobAccess -Job $theirs -User root -Role Admin | Should -BeTrue
        $html = Format-DashReportsBody -CsrfToken t -User alice -Role Viewer -Jobs @($mine, $theirs)
        $html | Should -Match '&lt;b&gt;shares'
        $html | Should -Not -Match '>bob<'
        (Format-DashReportsBody -CsrfToken t -User root -Role Admin -Jobs @($mine, $theirs)) | Should -Match '>bob<'
    }

    It 'expires finished jobs and deletes their files' {
        $jobs = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
        $old = New-DashReportJob -Name volumes -User a
        $old.Status = 'done'; $old.FinishedUtc = [datetime]::UtcNow.AddHours(-30); $old.File = Join-Path $script:Dir 'old.csv'; Set-Content $old.File 'x'
        $new = New-DashReportJob -Name volumes -User a
        $new.Status = 'done'; $new.FinishedUtc = [datetime]::UtcNow
        $queued = New-DashReportJob -Name volumes -User a
        foreach ($j in $old, $new, $queued) { $null = $jobs.TryAdd($j.Id, $j) }
        Remove-DashExpiredReportJob -Jobs $jobs -RetentionHours 24 -Confirm:$false
        $jobs.Count | Should -Be 2
        Test-Path $old.File | Should -BeFalse
    }
}

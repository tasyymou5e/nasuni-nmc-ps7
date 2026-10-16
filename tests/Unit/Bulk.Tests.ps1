BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    $script:Dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nmc-bulk-" + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $script:Dir

    function New-SharePlan([int]$Count = 3) {
        $items = foreach ($n in 1..$Count) {
            New-NasuniBulkItem -Key "v1/s1/$n" -Command Set-NasuniShare -Parameters @{ VolumeGuid = 'v1'; FilerSerial = 's1'; ShareId = "$n" } -Body @{ readonly = $true; comment = "c$n" } -Summary "share $n -> read-only"
        }
        New-NasuniBulkPlan -Name 'readonly test' -Items @($items)
    }
    function Get-Patches { , @($script:Fake.Calls | Where-Object Method -EQ 'PATCH') }
}
AfterAll { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Bulk plan engine' {
    BeforeEach {
        Reset-FakeNmc
        $script:FailShare = $null
        Add-FakeRoute -Method PATCH -Path '^/api/v1\.2/volumes/v1/filers/s1/shares/(\d+)/$' -Handler {
            param($req)
            $id = ([regex]::Match($req.Path, 'shares/(\d+)/')).Groups[1].Value
            if ($id -eq $script:FailShare) { return New-FakeResponse -Status 400 -Body @{ error = 'bad share' } }
            New-FakeResponse -Status 202 -Body @{ message = @{ id = "m$id"; status = 'pending' } }
        }
        Add-FakeRoute -Method GET -Path '^/api/v1\.2/messages/m\d+/$' -Handler { param($req) New-FakeResponse -Body @{ id = 'm'; status = 'synced' } }
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

    Context 'Building plans' {
        It 'rejects read-only cmdlets, unknown commands, empty ids and duplicate keys' {
            { New-NasuniBulkItem -Key k -Command Get-NasuniShare -Parameters @{ VolumeGuid = 'v'; FilerSerial = 's'; ShareId = '1' } } | Should -Throw '*read-only*'
            { New-NasuniBulkItem -Key k -Command Remove-Item -Parameters @{} } | Should -Throw '*not a Nasuni.Nmc endpoint*'
            { New-NasuniBulkItem -Key k -Command Set-NasuniShare -Parameters @{ VolumeGuid = ''; FilerSerial = 's'; ShareId = '1' } } | Should -Throw '*empty*'
            $i = New-NasuniBulkItem -Key same -Command Set-NasuniShare -Parameters @{ VolumeGuid = 'v'; FilerSerial = 's'; ShareId = '1' } -Body @{}
            { New-NasuniBulkPlan -Name dup -Items @($i, $i) } | Should -Throw '*Duplicate plan keys*'
        }
        It 'flags destructive plans' {
            $d = New-NasuniBulkItem -Key d -Command Remove-NasuniShare -Parameters @{ VolumeGuid = 'v'; FilerSerial = 's'; ShareId = '1' }
            $d.Destructive | Should -BeTrue
            (New-NasuniBulkPlan -Name d -Items @($d)).Destructive | Should -BeTrue
            (New-SharePlan).Destructive | Should -BeFalse
        }
        It 'round-trips through a saved file with a stable hash, and detects edits' {
            $plan = New-SharePlan
            $path = Join-Path -Path $script:Dir -ChildPath 'plan.json'
            Export-NasuniBulkPlan -Plan $plan -Path $path
            if (-not $IsWindows) { (Get-Item $path).UnixFileMode | Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite') }
            (Import-NasuniBulkPlan -Path $path).PlanHash | Should -Be $plan.PlanHash
            (Get-Content $path -Raw).Replace('"c2"', '"edited"') | Set-Content $path
            { Import-NasuniBulkPlan -Path $path } | Should -Throw '*modified*'
            (Import-NasuniBulkPlan -Path $path -AcceptModified).PlanHash | Should -Not -Be $plan.PlanHash
        }
        It 'refuses to save a plan that carries secrets' {
            $i = New-NasuniBulkItem -Key k -Command Set-NasuniFilerCloudCredential -Parameters @{ CloudCredentialId = 'c'; FilerSerial = 's' } -Body @{ secret = 'AWS-SECRET' }
            { Export-NasuniBulkPlan -Plan (New-NasuniBulkPlan -Name s -Items @($i)) -Path (Join-Path $script:Dir 'secret.json') } | Should -Throw '*secret-bearing*'
            Test-Path (Join-Path $script:Dir 'secret.json') | Should -BeFalse
        }
    }

    Context 'Running plans' {
        It 'dry-runs by default and sends nothing' {
            $r = Invoke-NasuniBulkPlan -Plan (New-SharePlan) -JournalPath $script:Journal
            $r.Status | Should -Be 'dry-run'
            $r.WouldRun | Should -Be 3
            (Get-Patches).Count | Should -Be 0
            Test-Path $script:Journal | Should -BeFalse
        }
        It 'executes every item, waits for each message and journals the outcomes' {
            $r = Invoke-NasuniBulkPlan -Plan (New-SharePlan) -JournalPath $script:Journal -Execute -Confirm:$false
            $r.Status | Should -Be 'completed'
            $r.Succeeded | Should -Be 3
            (Get-Patches).Count | Should -Be 3
            ((Get-Patches)[0].BodyJson | ConvertFrom-Json).readonly | Should -BeTrue
            @($script:Fake.Calls | Where-Object Path -Like '*/messages/*').Count | Should -Be 3
            $j = Read-NasuniBulkJournal -Path $script:Journal
            $j.Header.planHash | Should -Be (New-SharePlan).PlanHash
            $j.Succeeded.Count | Should -Be 3
        }
        It 'continues past a failure, then resumes only the failed item' {
            $plan = New-SharePlan
            $script:FailShare = '2'
            $r1 = Invoke-NasuniBulkPlan -Plan $plan -JournalPath $script:Journal -Execute -Confirm:$false
            $r1.Status | Should -Be 'completed-with-failures'
            $r1.Succeeded | Should -Be 2; $r1.Failed | Should -Be 1
            ($r1.Results | Where-Object Status -EQ 'failed').Error | Should -Match '400'

            $dry = Invoke-NasuniBulkPlan -Plan $plan -JournalPath $script:Journal
            $dry.AlreadyDone | Should -Be 2; $dry.WouldRun | Should -Be 1

            $script:FailShare = $null
            $before = (Get-Patches).Count
            $r2 = Invoke-NasuniBulkPlan -Plan $plan -JournalPath $script:Journal -Execute -Confirm:$false
            $r2.Succeeded | Should -Be 1; $r2.AlreadyDone | Should -Be 2
            (Get-Patches).Count - $before | Should -Be 1
            (Get-Patches)[-1].Path | Should -Match 'shares/2/$'
        }
        It 'aborts after MaxFailures and marks the rest not-run' {
            $script:FailShare = '1'
            $r = Invoke-NasuniBulkPlan -Plan (New-SharePlan) -JournalPath $script:Journal -Execute -Confirm:$false -StopOnError
            $r.Status | Should -Be 'aborted'
            $r.NotRun | Should -Be 2
            (Get-Patches).Count | Should -Be 1
        }
        It 'refuses a journal from another plan, a tampered plan, and a read-only connection' {
            $null = Invoke-NasuniBulkPlan -Plan (New-SharePlan 2) -JournalPath $script:Journal -Execute -Confirm:$false
            { Invoke-NasuniBulkPlan -Plan (New-SharePlan 3) -JournalPath $script:Journal -Execute -Confirm:$false } | Should -Throw '*different plan*'
            $p = New-SharePlan; $p.Items[0].Parameters.ShareId = '99'
            { Invoke-NasuniBulkPlan -Plan $p -JournalPath (Join-Path $script:Dir 'x.jsonl') -Execute -Confirm:$false } | Should -Throw '*hash mismatch*'
            Disconnect-Nasuni
            Connect-Nasuni -ComputerName nmc.test.example -Credential (Get-CanaryCredential) -ReadOnly | Out-Null
            { Invoke-NasuniBulkPlan -Plan (New-SharePlan) -JournalPath (Join-Path $script:Dir 'y.jsonl') -Execute -Confirm:$false } | Should -Throw '*read-only*'
        }
        It 'does nothing for an empty plan (no 0..-1 loop)' {
            $r = Invoke-NasuniBulkPlan -Plan (New-NasuniBulkPlan -Name empty) -JournalPath $script:Journal -Execute -Confirm:$false
            $r.Total | Should -Be 0
            $script:Fake.Calls.Count | Should -Be 1   # only the login
        }
        It 'honours -WhatIf even with -Execute' {
            $r = Invoke-NasuniBulkPlan -Plan (New-SharePlan) -JournalPath $script:Journal -Execute -WhatIf
            (Get-Patches).Count | Should -Be 0
        }
    }
}

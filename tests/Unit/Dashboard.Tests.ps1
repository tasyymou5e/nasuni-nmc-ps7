BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../src/Nasuni.Nmc.Dashboard/Nasuni.Nmc.Dashboard.psm1') -Force
    $script:Dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nmc-dash-" + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $script:Dir
    $script:Key = [byte[]](1..32)
}
AfterAll { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Rendering' {
    It 'HTML-encodes every cell, header and link' {
        $rows = @([pscustomobject]@{ name = '<script>alert(1)</script>'; id = 'a"b' })
        $html = Format-DashTable -Rows $rows -Columns @(@{ Header = '<Name>'; Path = 'name' }, @{ Header = 'Id'; Path = 'id'; Link = { param($r) "/x?id=$($r.id)" } })
        $html | Should -Not -Match '<script>'
        $html | Should -Match '&lt;script&gt;'
        $html | Should -Match '&lt;Name&gt;'
        $html | Should -Not -Match 'href="/x\?id=a"b"'
    }
    It 'drops links that are not plain relative paths' {
        $html = Format-DashTable -Rows @([pscustomobject]@{ n = 'x' }) -Columns @(@{ Header = 'N'; Path = 'n'; Link = { 'javascript:alert(1)' } })
        $html | Should -Not -Match 'href'
    }
    It 'reads nested values and renders booleans and arrays' {
        $o = [pscustomobject]@{ status = [pscustomobject]@{ offline = $true }; protocols = @('CIFS', 'NFS') }
        ConvertTo-DashHtml (Get-DashValue $o 'status.offline') | Should -Be 'yes'
        ConvertTo-DashHtml (Get-DashValue $o 'protocols') | Should -Be 'CIFS, NFS'
        Get-DashValue $o 'missing.path' | Should -BeNullOrEmpty
    }
    It 'shows an empty message and caps long tables' {
        Format-DashTable -Rows @() -Columns @(@{ Header = 'A'; Path = 'a' }) | Should -Match 'No items'
        $many = 1..5 | ForEach-Object { [pscustomobject]@{ a = $_ } }
        Format-DashTable -Rows $many -Columns @(@{ Header = 'A'; Path = 'a' }) -MaxRows 2 | Should -Match 'Showing 2 of 5'
    }
    It 'encodes the user name in the layout and only shows Audit to admins' {
        $p = Format-DashPage -Title 'T' -BodyHtml '' -UserName '<img onerror=x>' -Role 'Viewer'
        $p | Should -Not -Match '<img'
        $p | Should -Not -Match '/audit'
        Format-DashPage -Title 'T' -BodyHtml '' -UserName 'a' -Role 'Admin' | Should -Match '/audit'
    }
    It 'neutralises CSV formula injection' {
        ConvertTo-DashCsvSafe '=HYPERLINK("http://x")' | Should -Be "'=HYPERLINK(""http://x"")"
        foreach ($v in '+1', '-1', '@SUM(A1)', "`tx") { (ConvertTo-DashCsvSafe $v).StartsWith("'") | Should -BeTrue }
        ConvertTo-DashCsvSafe 'normal' | Should -Be 'normal'
        $row = @(ConvertTo-DashCsvRow -Rows @([pscustomobject]@{ n = '=cmd' }) -Columns @(@{ Header = 'Name'; Path = 'n' }))
        $row[0].Name | Should -Be "'=cmd"
    }
}

Describe 'RBAC' {
    BeforeAll { $script:Map = @{ Admin = @('nas-admins'); Operator = @('nas-ops'); Viewer = @('nas-view') } }
    It 'picks the highest matching role' {
        Resolve-DashRole -Groups @('nas-view', 'nas-ops') -RoleMap $script:Map | Should -Be 'Operator'
        Resolve-DashRole -Groups @('nas-admins') -RoleMap $script:Map | Should -Be 'Admin'
        Resolve-DashRole -Groups @('other') -RoleMap $script:Map | Should -BeNullOrEmpty
        Resolve-DashRole -Groups $null -RoleMap $script:Map | Should -BeNullOrEmpty
    }
    It 'enforces the permission matrix' -ForEach @(
        @{ Role = 'Viewer'; Perm = 'Read'; Ok = $true }, @{ Role = 'Viewer'; Perm = 'Operate'; Ok = $false }
        @{ Role = 'Operator'; Perm = 'Operate'; Ok = $true }, @{ Role = 'Operator'; Perm = 'Destroy'; Ok = $false }
        @{ Role = 'Operator'; Perm = 'Audit'; Ok = $false }, @{ Role = 'Admin'; Perm = 'Destroy'; Ok = $true }
        @{ Role = ''; Perm = 'Read'; Ok = $false }, @{ Role = 'Root'; Perm = 'Read'; Ok = $false }
    ) {
        Test-DashPermission -Role $Role -Permission $Perm | Should -Be $Ok
    }
}

Describe 'Audit log' {
    It 'chains records with HMAC and detects edits, deletions and a wrong key' {
        $path = Join-Path -Path $script:Dir -ChildPath 'audit1.jsonl'
        1..3 | ForEach-Object { Write-DashAudit -Path $path -Key $script:Key -Entry @{ user = 'u'; action = "a$_"; params = @{ password = 'p4ss' } } }
        (Test-DashAuditChain -Path $path -Key $script:Key).Valid | Should -BeTrue
        (Test-DashAuditChain -Path $path -Key $script:Key).Count | Should -Be 3
        (Get-Content $path -Raw) | Should -Not -Match 'p4ss'
        if (-not $IsWindows) { (Get-Item $path).UnixFileMode | Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite') }

        (Test-DashAuditChain -Path $path -Key ([byte[]](2..33))).Valid | Should -BeFalse

        $lines = Get-Content $path
        $tampered = Join-Path -Path $script:Dir -ChildPath 'audit2.jsonl'
        Set-Content $tampered -Value @($lines[0], $lines[1].Replace('"a2"', '"a9"'), $lines[2])
        $r = Test-DashAuditChain -Path $tampered -Key $script:Key
        $r.Valid | Should -BeFalse; $r.BrokenAtLine | Should -Be 2

        $removed = Join-Path -Path $script:Dir -ChildPath 'audit3.jsonl'
        Set-Content $removed -Value @($lines[0], $lines[2])
        (Test-DashAuditChain -Path $removed -Key $script:Key).Reason | Should -Match 'link'
        @(Read-DashAudit -Path $path -Last 2).Count | Should -Be 2
    }
    It 'requires a 32-byte key' {
        { Write-DashAudit -Path (Join-Path $script:Dir 'k.jsonl') -Key ([byte[]](1..8)) -Entry @{ a = 1 } } | Should -Throw '*32 bytes*'
    }
}

Describe 'Two-step change flow' {
    BeforeEach {
        Reset-FakeNmc
        $script:Share = @{ id = 5; name = 'Finance'; readonly = $false; volume_guid = 'g'; filer_serial_number = 's' }
        Add-FakeRoute -Method GET -Path '^/api/v1\.2/volumes/g/filers/s/shares/5/$' -Handler { New-FakeResponse -Body $script:Share }
        Add-FakeRoute -Method PATCH -Path '^/api/v1\.2/volumes/g/filers/s/shares/5/$' -Handler {
            param($req)
            $b = $req.BodyJson | ConvertFrom-Json
            $script:Share.readonly = [bool]$b.readonly
            New-FakeResponse -Status 202 -Body @{ message = @{ id = 'm1'; status = 'pending' } }
        }
        Add-FakeRoute -Method GET -Path '^/api/v1\.2/messages/m1/$' -Handler { New-FakeResponse -Body @{ id = 'm1'; status = 'synced' } }
        $script:AvExists = $true
        Add-FakeRoute -Method GET -Path '^/api/v1\.2/volumes/g/filers/s/antivirus-violations/9/$' -Handler {
            if ($script:AvExists) { New-FakeResponse -Body @{ id = 9; fpath = '/Finance/evil.exe' } } else { New-FakeResponse -Status 404 }
        }
        Add-FakeRoute -Method DELETE -Path '^/api/v1\.2/volumes/g/filers/s/antivirus-violations/9/$' -Handler {
            param($req)
            $script:AvAction = $req.Query['action']; $script:AvExists = $false
            New-FakeResponse -Status 202 -Body @{ message = @{ id = 'm1'; status = 'pending' } }
        }
        Mock -ModuleName Nasuni.Nmc Invoke-NmcHttp {
            $b = Get-Variable -Name BodyJson -ValueOnly -ErrorAction Ignore
            Invoke-FakeNmc -Method $Method -Uri $Uri -Headers $Headers -BodyJson $b
        }
        Mock -ModuleName Nasuni.Nmc Wait-NmcRateLimit { }
        Mock -ModuleName Nasuni.Nmc Start-Sleep { }
        Connect-Nasuni -ComputerName nmc.test.example -Credential (Get-CanaryCredential) | Out-Null
        $script:Audit = Join-Path -Path $script:Dir -ChildPath ("flow-" + [guid]::NewGuid() + '.jsonl')
    }
    AfterEach { InModuleScope Nasuni.Nmc { if ($script:NmcState.HttpClient) { Disconnect-Nasuni } } }

    It 'validates action parameters' {
        { Get-DashActionParameter -Action 'share-readonly' -Data @{ volume_guid = 'g'; filer_serial = 's'; share_id = '../5'; readonly = 'true' } } | Should -Throw '*share_id*'
        { Get-DashActionParameter -Action 'share-readonly' -Data @{ volume_guid = 'g'; filer_serial = 's'; share_id = '5'; readonly = 'maybe' } } | Should -Throw '*readonly*'
        { Get-DashActionParameter -Action 'rm-rf' -Data @{} } | Should -Throw '*Unknown action*'
        (Get-DashActionParameter -Action 'share-readonly' -Data @{ volume_guid = 'g'; filer_serial = 's'; share_id = '5'; readonly = 'true' }).readonly | Should -BeTrue
    }

    It 'previews without changing anything, then applies, verifies and audits on the exact phrase' {
        $params = Get-DashActionParameter -Action 'share-readonly' -Data @{ volume_guid = 'g'; filer_serial = 's'; share_id = '5'; readonly = 'true' }
        $pending = New-DashActionPreview -Action 'share-readonly' -Params $params -User alice -Role Operator
        $pending.ConfirmPhrase | Should -Be 'Finance'
        $pending.Summary | Should -Match 'from False to True'
        @($script:Fake.Calls | Where-Object Method -EQ 'PATCH').Count | Should -Be 0

        $r = Invoke-DashAction -Pending $pending -PendingId $pending.Id -TypedPhrase 'Finance' -User alice -Role Operator -AuditPath $script:Audit -AuditKey $script:Key -Confirm:$false
        $r.Success | Should -BeTrue
        $r.Verified | Should -BeTrue
        $script:Share.readonly | Should -BeTrue
        $entry = @(Read-DashAudit -Path $script:Audit)[-1]
        $entry.user | Should -Be 'alice'; $entry.result | Should -Be 'success'; $entry.action | Should -Be 'share-readonly'
        (Test-DashAuditChain -Path $script:Audit -Key $script:Key).Valid | Should -BeTrue
    }

    It 'refuses <Name> and sends nothing' -ForEach @(
        @{ Name = 'a wrong phrase'; Phrase = 'finance'; User = 'alice'; Role = 'Operator'; IdOk = $true; Expired = $false; Expect = '*does not match*' }
        @{ Name = 'a different user'; Phrase = 'Finance'; User = 'mallory'; Role = 'Operator'; IdOk = $true; Expired = $false; Expect = '*user who previewed*' }
        @{ Name = 'a role without permission'; Phrase = 'Finance'; User = 'alice'; Role = 'Viewer'; IdOk = $true; Expired = $false; Expect = '*may not run*' }
        @{ Name = 'a mismatched pending id (replay/forgery)'; Phrase = 'Finance'; User = 'alice'; Role = 'Operator'; IdOk = $false; Expired = $false; Expect = '*No matching pending*' }
        @{ Name = 'an expired preview'; Phrase = 'Finance'; User = 'alice'; Role = 'Operator'; IdOk = $true; Expired = $true; Expect = '*expired*' }
    ) {
        $params = Get-DashActionParameter -Action 'share-readonly' -Data @{ volume_guid = 'g'; filer_serial = 's'; share_id = '5'; readonly = 'true' }
        $pending = New-DashActionPreview -Action 'share-readonly' -Params $params -User alice -Role Operator
        if ($Expired) { $pending.ExpiresUtc = [datetime]::UtcNow.AddSeconds(-1) }
        $id = if ($IdOk) { $pending.Id } else { [guid]::NewGuid().ToString() }
        { Invoke-DashAction -Pending $pending -PendingId $id -TypedPhrase $Phrase -User $User -Role $Role -AuditPath $script:Audit -AuditKey $script:Key -Confirm:$false } | Should -Throw $Expect
        @($script:Fake.Calls | Where-Object Method -EQ 'PATCH').Count | Should -Be 0
    }

    It 'does not let an Operator preview a destructive action' {
        $params = Get-DashActionParameter -Action 'antivirus-delete' -Data @{ volume_guid = 'g'; filer_serial = 's'; antivirus_id = '9' }
        { New-DashActionPreview -Action 'antivirus-delete' -Params $params -User bob -Role Operator } | Should -Throw '*may not run*'
    }

    It 'requires "DELETE {path}" to delete an infected file, and verifies it is gone' {
        $params = Get-DashActionParameter -Action 'antivirus-delete' -Data @{ volume_guid = 'g'; filer_serial = 's'; antivirus_id = '9' }
        $pending = New-DashActionPreview -Action 'antivirus-delete' -Params $params -User root -Role Admin
        $pending.ConfirmPhrase | Should -Be 'DELETE /Finance/evil.exe'
        $r = Invoke-DashAction -Pending $pending -PendingId $pending.Id -TypedPhrase 'DELETE /Finance/evil.exe' -User root -Role Admin -AuditPath $script:Audit -AuditKey $script:Key -Confirm:$false
        $r.Verified | Should -BeTrue
        $script:AvAction | Should -Be 'delete_file'
    }

    It 'audits a failed change' {
        Add-FakeRoute -Method PATCH -Path '^/api/v1\.2/volumes/g/filers/s/shares/5/$' -Handler { New-FakeResponse -Status 400 -Body @{ error = 'bad' } }
        $params = Get-DashActionParameter -Action 'share-readonly' -Data @{ volume_guid = 'g'; filer_serial = 's'; share_id = '5'; readonly = 'true' }
        $pending = New-DashActionPreview -Action 'share-readonly' -Params $params -User alice -Role Operator
        $r = Invoke-DashAction -Pending $pending -PendingId $pending.Id -TypedPhrase 'Finance' -User alice -Role Operator -AuditPath $script:Audit -AuditKey $script:Key -Confirm:$false
        $r.Success | Should -BeFalse
        (@(Read-DashAudit -Path $script:Audit)[-1]).result | Should -Be 'failure'
    }

    It 'builds a redacted snapshot and records section errors' {
        Add-FakeRoute -Method GET -Path '^/api/v1\.2/account/cloud-credentials/$' -Handler { New-FakeResponse -Body @{ Paging = @{ total = 1 }; items = @(@{ cred_uuid = 'c'; secret = 'TOPSECRET' }) } }
        Add-FakeRoute -Method GET -Path '^/api/v1\.2/filers/$' -Handler { New-FakeResponse -Body @{ Paging = @{ total = 2 }; items = @(@{ serial_number = 's'; settings = @{ escrow_passphrase = 'ESCROW-VALUE-9' } }, @{ serial_number = 't' }) } }
        $snap = Get-DashSnapshot
        ($snap | ConvertTo-Json -Depth 10) | Should -Not -MatchExactly 'TOPSECRET|ESCROW-VALUE-9'
        $snap.Filers.Count | Should -Be 2
        $snap.Filers[1].serial_number | Should -Be 't'
        $snap.Errors.Count | Should -BeGreaterThan 0
    }
}

Describe 'Page builders' {
    BeforeAll {
        $script:Snap = @{
            At            = '2026-01-01 00:00:00'
            Errors        = @('Health: boom <b>')
            Filers        = @([pscustomobject]@{ serial_number = 's1'; status = [pscustomobject]@{ offline = $true } }, [pscustomobject]@{ serial_number = 's2'; status = [pscustomobject]@{ offline = $false } })
            Volumes       = @([pscustomobject]@{ guid = 'v1'; name = 'Finance' })
            Shares        = @([pscustomobject]@{ id = 5; name = 'Fin'; volume_guid = 'v1'; filer_serial_number = 's1'; readonly = $false })
            Antivirus     = @([pscustomobject]@{ id = 9; fpath = '/x.exe'; volume_guid = 'v1'; filer_serial_number = 's1' })
            Notifications = @([pscustomobject]@{ priority = 'error'; acknowledged = $false }, [pscustomobject]@{ priority = 'info'; acknowledged = $false })
            Connections   = @([pscustomobject]@{ volume_guid = 'v1'; filer_serial_number = 's2'; connected = $false })
            Credentials   = @()
            Health        = @([pscustomobject]@{ filer_serial_number = 's1'; disk = 'Healthy'; nested = [pscustomobject]@{ a = 1 }; links = 'x' })
        }
    }
    It 'renders the <Section> section for every role, including when it is empty' -ForEach @(
        @{ Section = 'filers' }, @{ Section = 'volumes' }, @{ Section = 'shares' }, @{ Section = 'antivirus' }, @{ Section = 'notifications' },
        @{ Section = 'connections' }, @{ Section = 'credentials' }, @{ Section = 'health' }
    ) {
        foreach ($role in 'Viewer', 'Operator', 'Admin') {
            $html = Format-DashSectionBody -Name $Section -Snapshot $script:Snap -Role $role
            $html | Should -Match "/reports/$Section\.csv"
        }
        $empty = @{} + $script:Snap
        $empty[(Get-DashSectionDefinition)[$Section].Key] = @()
        Format-DashSectionBody -Name $Section -Snapshot $empty -Role Admin | Should -Match 'No items'
    }
    It 'adds change links by role' {
        Format-DashSectionBody -Name shares -Snapshot $script:Snap -Role Viewer | Should -Not -Match '/actions/'
        Format-DashSectionBody -Name shares -Snapshot $script:Snap -Role Operator | Should -Match 'share-readonly\?volume_guid=v1&amp;filer_serial=s1&amp;share_id=5&amp;readonly=true'
        Format-DashSectionBody -Name antivirus -Snapshot $script:Snap -Role Operator | Should -Not -Match 'antivirus-delete'
        Format-DashSectionBody -Name antivirus -Snapshot $script:Snap -Role Admin | Should -Match 'antivirus-delete'
        { Format-DashSectionBody -Name nope -Snapshot $script:Snap -Role Admin } | Should -Throw '*Unknown section*'
    }
    It 'builds generic columns for undocumented schemas, skipping objects and links' {
        $html = Format-DashSectionBody -Name health -Snapshot $script:Snap -Role Viewer
        $html | Should -Match '<th>disk</th>'
        $html | Should -Not -Match '<th>nested</th>|<th>links</th>'
    }
    It 'computes overview tiles, shows errors encoded, and offers refresh to operators only' {
        $v = Format-DashOverviewBody -Snapshot $script:Snap -Role Viewer -CsrfToken 't'
        $v | Should -Match '<span class="n">1</span><span>Offline filers</span>'
        $v | Should -Match '<span class="n">1</span><span>Unacknowledged errors and alerts</span>'
        $v | Should -Match 'boom &lt;b&gt;'
        $v | Should -Not -Match '/refresh'
        Format-DashOverviewBody -Snapshot $script:Snap -Role Operator -CsrfToken 't' | Should -Match 'action="/refresh"'
    }
    It 'renders the action form, preview and audit pages with encoded values' {
        $form = Format-DashActionFormBody -Action 'share-readonly' -Params @{ volume_guid = 'v"1'; readonly = $true } -CsrfToken 'tok'
        $form | Should -Match 'value="v&quot;1"'
        $form | Should -Match 'name="readonly" value="true"'
        $pending = @{ Id = 'p1'; Action = 'antivirus-delete'; Summary = 'DELETE <x>'; Before = @{ a = 1 }; After = @{ a = 2 }; ConfirmPhrase = 'DELETE <x>'; ExpiresUtc = [datetime]::UtcNow }
        $p = Format-DashPreviewBody -Pending $pending -CsrfToken 'tok'
        $p | Should -Match 'preview danger'
        $p | Should -Match 'DELETE &lt;x&gt;'
        Format-DashAuditBody -Chain ([pscustomobject]@{ Valid = $true; Count = 3 }) -Entries @() | Should -Match 'Chain verified: 3'
        Format-DashAuditBody -Chain ([pscustomobject]@{ Valid = $false; BrokenAtLine = 2; Reason = 'HMAC <mismatch>' }) -Entries @() | Should -Match 'CHAIN BROKEN at record 2: HMAC &lt;mismatch&gt;'
    }
}

Describe 'Connect-DashNmc' {
    BeforeEach {
        Reset-FakeNmc
        Mock -ModuleName Nasuni.Nmc Invoke-NmcHttp {
            $b = Get-Variable -Name BodyJson -ValueOnly -ErrorAction Ignore
            Invoke-FakeNmc -Method $Method -Uri $Uri -Headers $Headers -BodyJson $b
        }
        Mock -ModuleName Nasuni.Nmc Wait-NmcRateLimit { }
    }
    AfterEach { InModuleScope Nasuni.Nmc { if ($script:NmcState.HttpClient) { Disconnect-Nasuni } } }
    It 'connects once, reuses the connection, and reconnects when the mode changes' {
        $nmc = @{ Host = 'nmc.test.example'; RevocationMode = 'NoCheck' }
        Connect-DashNmc -Nmc $nmc -Credential (Get-CanaryCredential) -ReadOnly
        Connect-DashNmc -Nmc $nmc -Credential (Get-CanaryCredential) -ReadOnly
        @($script:Fake.Calls | Where-Object Path -Like '*/auth/login/').Count | Should -Be 1
        (Get-NasuniConnection).ReadOnly | Should -BeTrue
        Connect-DashNmc -Nmc $nmc -Credential (Get-CanaryCredential)
        (Get-NasuniConnection).ReadOnly | Should -BeFalse
        @($script:Fake.Calls | Where-Object Path -Like '*/auth/login/').Count | Should -Be 2
    }
}

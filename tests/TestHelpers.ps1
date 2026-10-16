# DEBUG NOTES for writing tests (See docs/TROUBLESHOOTING.md, "Pester"):
#  - Never use $Host, $Args, $Input or $PID as -ForEach data keys: they are automatic variables.
#  - '<name>' in an It title is a data placeholder, so avoid literal <...> in titles.
#  - Should -Match ignores case; use -MatchExactly when checking that a secret value is absent.
#  - In Mock bodies, read optional parameters with Get-Variable -ErrorAction Ignore (strict mode).
#  - For functions that may return 0 or 1 items, return , @(...) so that .Count works under strict mode.
#  - Pester 6 rejects BeforeEach at the file root; put it inside a Describe.
# Shared test setup: imports the module with the development non-FIPS override and
# provides a fake NMC that stands in for the network layer (Invoke-NmcHttp).
Set-StrictMode -Version Latest

$env:NASUNI_ALLOW_NON_FIPS_HOST = if ($env:NASUNI_FIPS_CI -eq '1') { '0' } else { '1' }
$script:ModulePath = Join-Path -Path $PSScriptRoot -ChildPath '../src/Nasuni.Nmc/Nasuni.Nmc.psd1'
Import-Module $script:ModulePath -Force -WarningAction SilentlyContinue

$script:CanaryPassword = 'Canary"Pa\ss{0}-7f3c9e'
$script:CanaryToken = 'tok_CANARY_5b1d0c2e9a7f'

function New-FakeResponse {
    param([int]$Status = 200, [object]$Body, [string]$RetryAfter, [string]$Location)
    $text = if ($null -eq $Body) { '' } elseif ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
    [pscustomobject]@{ StatusCode = $Status; Body = $text; RetryAfter = $RetryAfter; Location = $Location }
}

function Reset-FakeNmc {
    $script:Fake = @{
        Calls  = [System.Collections.Generic.List[object]]::new()
        Routes = [System.Collections.Generic.List[object]]::new()
    }
    Add-FakeRoute -Method POST -Path '^/api/v1\.2/auth/login/$' -Handler {
        param($req)
        $body = $req.BodyJson | ConvertFrom-Json
        if ($body.password -ne $script:CanaryPassword) { return New-FakeResponse -Status 401 -Body @{ error = 'bad credentials' } }
        New-FakeResponse -Body @{ token = $script:CanaryToken; expires = [datetime]::UtcNow.AddHours(8).ToString('o') }
    }
    Add-FakeRoute -Method POST -Path '^/api/v1\.2/auth/logout/$' -Handler { New-FakeResponse -Status 200 }
}

function Add-FakeRoute {
    # Handlers are tried newest-first. A handler returning $null falls through to older routes.
    param([string]$Method, [string]$Path, [scriptblock]$Handler)
    $script:Fake.Routes.Insert(0, [pscustomobject]@{ Method = $Method; Path = $Path; Handler = $Handler })
}

function Invoke-FakeNmc {
    param($Method, $Uri, $Headers, $BodyJson)
    $req = [pscustomobject]@{
        Method   = $Method
        Uri      = [uri]$Uri
        Path     = ([uri]$Uri).AbsolutePath
        Query    = [System.Web.HttpUtility]::ParseQueryString(([uri]$Uri).Query)
        Headers  = $Headers
        BodyJson = $BodyJson
    }
    $script:Fake.Calls.Add($req)
    foreach ($route in $script:Fake.Routes) {
        if ($route.Method -eq $Method -and $req.Path -match $route.Path) {
            $resp = & $route.Handler $req
            if ($null -ne $resp) { return $resp }
        }
    }
    New-FakeResponse -Status 404 -Body @{ error = "no fake route for $Method $($req.Path)" }
}

function Get-CanaryCredential {
    $secure = [securestring]::new()
    foreach ($ch in $script:CanaryPassword.ToCharArray()) { $secure.AppendChar($ch) }
    [pscredential]::new('api-user', $secure)
}

function Add-FakeDataRoutes {
    # Serves GETs from $Data (path -> list for paged endpoints, or object) and answers every
    # write with 202 + a message that polls as synced. Writes are recorded in $script:Fake.Calls.
    param([Parameter(Mandatory)][hashtable]$Data)
    $script:FakeData = $Data
    foreach ($verb in 'POST', 'PUT', 'PATCH', 'DELETE') {
        Add-FakeRoute -Method $verb -Path '^/api/v1\.2/(?!auth/)' -Handler { New-FakeResponse -Status 202 -Body @{ message = @{ id = 'mw'; status = 'pending' } } }
    }
    Add-FakeRoute -Method GET -Path '.' -Handler {
        param($req)
        if (-not $script:FakeData.ContainsKey($req.Path)) { return $null }
        $e = $script:FakeData[$req.Path]
        if ($e -is [System.Collections.IList]) {
            $limit = if ($req.Query['limit']) { [int]$req.Query['limit'] } else { 50 }
            $offset = if ($req.Query['offset']) { [int]$req.Query['offset'] } else { 0 }
            $page = @($e | Select-Object -Skip $offset -First $limit)
            return New-FakeResponse -Body @{ Paging = @{ total = $e.Count; limit = $limit; offset = $offset; next = $null }; items = $page }
        }
        New-FakeResponse -Body $e
    }
    Add-FakeRoute -Method GET -Path '^/api/v1\.2/messages/mw/$' -Handler { New-FakeResponse -Body @{ id = 'mw'; status = 'synced' } }
}

function Get-FakeWrite {
    param([string]$Method, [string]$PathRegex = '.')
    , @($script:Fake.Calls | Where-Object { $_.Method -eq $Method -and $_.Path -match $PathRegex -and $_.Path -notlike '*/auth/*' })
}

function New-FakeSeedData {
    # A small but complete NMC estate used by the report and bulk-plan tests.
    $p = '/api/v1.2'
    $shares = [System.Collections.ArrayList]@(
        @{ id = 11; name = 'Finance'; volume_guid = 'v1'; filer_serial_number = 's1'; path = '\'; comment = '=HYPERLINK("x")'; readonly = $false; browseable = $true; hide_unreadable = $false; fruit_enabled = $false; enable_previous_vers = $true; veto_files = "Thumbs.db`r`n.DS_Store"; hosts_allow = '10.0.0.1 10.0.0.2'; auth = @{ authall = $true; ro_users = @(); rw_users = @(); deny_users = @(); ro_groups = @(); rw_groups = @(); deny_groups = @() }; browser_access_settings = @{ link_auth = @{ authall = $true } } }
        @{ id = 12; name = 'Archive'; volume_guid = 'v1'; filer_serial_number = 's1'; path = '\archive'; comment = 'a, b'; readonly = $true; browseable = $true; hide_unreadable = $true; fruit_enabled = $false; enable_previous_vers = $false; auth = @{ authall = $false; ro_users = @('DOM\bob'); rw_users = @(); deny_users = @(); ro_groups = @(); rw_groups = @('DOM\fin'); deny_groups = @() } }
        @{ id = 21; name = 'Eng'; volume_guid = 'v2'; filer_serial_number = 's2'; path = '\'; comment = ''; readonly = $false; browseable = $true; hide_unreadable = $false; fruit_enabled = $true; enable_previous_vers = $false }
    )
    @{
        "$p/filers/"                                  = [System.Collections.ArrayList]@(
            @{ serial_number = 's1'; description = 'NY'; guid = 'g1'; build = '10.2'; management_state = 'nmc'; status = @{ offline = $false; platform = @{ cpu = @{ cores = 8 }; cache_status = @{ percent_used = 42 } } }; settings = @{ escrow_passphrase = 'ESCROW-VALUE-7'; network_settings = @{ hostname = 'nea-ny'; ip_addresses = @('10.1.1.1', '10.1.1.2') }; qos = @{ rules = @(@{ days = @{ mon = $true; sun = $false }; start = 0; stop = 23; limit = 100; ingress_limit = 50 }) } } }
            @{ serial_number = 's2'; description = 'LA'; management_state = 'nmc'; status = @{ offline = $true }; settings = @{ qos = @{ rules = @() } } }
            @{ serial_number = 's3'; description = 'Unmanaged'; management_state = 'local'; status = @{ offline = $false } })
        "$p/volumes/"                                 = [System.Collections.ArrayList]@(
            @{ guid = 'v1'; name = 'Finance'; filer_serial_number = 's1'; provider = @{ name = 'S3' }; protocols = @{ protocols = @('CIFS', 'NFS') }; antivirus_service = @{ enabled = $true; days = @{ sun = $true; mon = $false } }; quota = -1 }
            @{ guid = 'v2'; name = 'Eng'; filer_serial_number = 's2'; provider = @{ name = 'Azure' }; antivirus_service = @{ enabled = $false } })
        "$p/volumes/filers/shares/"                   = $shares
        "$p/volumes/filers/exports/"                  = [System.Collections.ArrayList]@(
            @{ id = 1; name = 'nfs1'; volume_guid = 'v1'; filer_serial_number = 's1'; path = '/data'; hostspec = '10.0.0.0/8'; access_mode = 'root_squash'; perf_mode = 'sync'; sec_options = @('sys', 'krb5'); readonly = $false; nfs_host_options = @(@{ id = 7; hostspec = '10.2.0.0/16'; access_mode = 'all_squash'; readonly = $true; sec_options = @('sys'); perf_mode = 'async' }) }
            @{ id = 2; name = 'nfs1'; volume_guid = 'v2'; filer_serial_number = 's1'; path = '/eng'; hostspec = '*'; access_mode = 'no_root_squash'; perf_mode = 'sync'; sec_options = @('sys'); readonly = $false })
        "$p/volumes/filers/ftp-directories/"          = [System.Collections.ArrayList]@(@{ id = 3; name = 'ftp1'; volume_guid = 'v1'; filer_serial_number = 's1'; allow_users = @('u1', 'u2') })
        "$p/filers/cifsclients/"                      = [System.Collections.ArrayList]@(@{ filer_serial_number = 's1'; user = 'DOM\amy'; client_name = 'PC1'; client = '10.0.0.9'; share_id = 11 })
        "$p/filers/cifsclients/locks/"                = [System.Collections.ArrayList]@(@{ filer_serial_number = 's1'; type = 'exclusive'; client = '10.0.0.9'; path = '\a.xlsx' })
        "$p/filers/s1/cifsclients/locks/"             = [System.Collections.ArrayList]@(@{ filer_serial_number = 's1'; type = 'exclusive'; client = '10.0.0.9'; path = '\a.xlsx' })
        "$p/volumes/filers/antivirus-violations/"     = [System.Collections.ArrayList]@(
            @{ id = 501; fpath = '/Finance/bad.exe'; vname = 'Trojan'; volume_guid = 'v1'; filer_serial_number = 's1' }
            @{ id = 502; fpath = '/Eng/tool.zip'; vname = 'PUA'; volume_guid = 'v2'; filer_serial_number = 's2' })
        "$p/filers/blocked-clients/"                  = [System.Collections.ArrayList]@(@{ ip_address = '10.9.9.9'; filer_serial_number = 's1'; blocked_date = '2026-01-01' })
        "$p/filers/health/"                           = [System.Collections.ArrayList]@(@{ filer_serial_number = 's1'; network = 'Healthy'; disk = 'Healthy' })
        "$p/messages/"                                = [System.Collections.ArrayList]@(
            @{ id = 'm2'; code = 'volumes_shares_add'; status = 'failure'; send_time = '2026-01-02T00:00:00Z'; filer_serial_number = 's1' }
            @{ id = 'm1'; code = 'volumes_shares_add'; status = 'failure'; send_time = '2026-01-01T00:00:00Z'; filer_serial_number = 's1' }
            @{ id = 'm3'; code = 'volumes_shares_add'; status = 'pending'; send_time = '2026-01-03T00:00:00Z'; filer_serial_number = 's1' })
        "$p/notifications/"                           = [System.Collections.ArrayList]@(
            @{ id = 1; name = 'AR_NEW_ATTACK'; date = [datetime]::UtcNow.AddMinutes(-2).ToString('yyyy-MM-ddTHH:mm:ss.fff') + ' UTC'; message = 'Ransomware attack from client (10.6.6.6) on share (Finance)' }
            @{ id = 2; name = 'AR_NEW_ATTACK'; date = [datetime]::UtcNow.AddMinutes(-90).ToString('yyyy-MM-ddTHH:mm:ss') + ' UTC'; message = 'Old attack (10.7.7.7)' }
            @{ id = 3; name = 'AR_NEW_ATTACK'; date = [datetime]::UtcNow.AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ss') + ' UTC'; message = 'Repeat attack from (10.6.6.6)' }
            @{ id = 4; name = 'Other'; date = [datetime]::UtcNow.ToString('s'); message = 'x (10.8.8.8)' })
        "$p/volumes/filers/auto-cached-folders/"      = [System.Collections.ArrayList]@(@{ volume_guid = 'v1'; filer_serial_number = 's1'; path = '/hot'; mode = 'metadata' })
        "$p/volumes/filers/pinned-folders/"           = [System.Collections.ArrayList]@(@{ volume_guid = 'v1'; filer_serial_number = 's1'; path = '/pin'; mode = 'metadata_and_data' })
        "$p/volumes/folder-quotas/"                   = [System.Collections.ArrayList]@(
            @{ id = 'q1'; volume_guid = 'v1'; filer_serial_number = 's1'; path = '/Finance/Projects'; type = 'quota'; limit = 100; usage = 10 }
            @{ id = 'q2'; volume_guid = 'v2'; filer_serial_number = 's2'; path = '/Finance/Projects'; type = 'quota'; limit = 100; usage = 1 })
        "$p/volumes/filer-connections/"               = [System.Collections.ArrayList]@(@{ volume_guid = 'v1'; filer_serial_number = 's2'; connected = $true })
        "$p/volumes/v1/filers/"                       = [System.Collections.ArrayList]@(
            @{ guid = 'v1'; filer_serial_number = 's1'; name = 'Finance'; auditing = @{ enabled = $true; events = @{ delete = $true }; logs = @{ days_to_keep = 90 } }; snapshot_access = $true; snapshot_schedule = @{ days = @{ mon = $true }; frequency = 60 }; status = @{ accessible_data = 1000; data_not_yet_protected = 5000 }; file_alerts_service = @{ enabled = $false } }
            @{ guid = 'v1'; filer_serial_number = 's2'; name = 'Finance'; auditing = @{ enabled = $false }; status = @{ accessible_data = 1000; data_not_yet_protected = 0 } })
        "$p/volumes/v2/filers/"                       = [System.Collections.ArrayList]@(@{ guid = 'v2'; filer_serial_number = 's2'; name = 'Eng'; auditing = @{ enabled = $false }; status = @{ accessible_data = 77; data_not_yet_protected = 9 } })
        "$p/volumes/v1/filers/s1/"                    = @{ guid = 'v1'; filer_serial_number = 's1'; status = @{ accessible_data = 1000; snapshot_status = 'idle'; snapshot_percent = 100 } }
        "$p/volumes/v1/filers/s2/"                    = @{ guid = 'v1'; filer_serial_number = 's2'; status = @{ snapshot_status = 'in_progress'; snapshot_percent = 40 } }
        "$p/volumes/v2/filers/s2/"                    = @{ guid = 'v2'; filer_serial_number = 's2'; status = @{ accessible_data = 77 } }
        "$p/volumes/v1/filers/s1/path/"               = @{ path = '/'; size = 123456; cache_resident = $true; protected = $true }
        "$p/volumes/v1/filers/s1/path/archive"        = @{ path = '/archive'; size = 999; global_locking_enabled = $false }
        "$p/volumes/v2/filers/s2/path/"               = @{ path = '/'; size = 5 }
    }
}

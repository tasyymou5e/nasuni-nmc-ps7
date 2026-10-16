#Requires -Version 7.4
<#
.SYNOPSIS
    Local demo: runs the real dashboard against a fake NMC (over TLS) seeded with sample data.
.DESCRIPTION
    Development only. The dashboard serves plain HTTP on 127.0.0.1 with a pick-a-user sign-in
    page, so it can be opened in any browser. Every other control is the production code path:
    CSRF, same-origin checks, RBAC, preview/confirm/verify, audit chain and redaction. Changes
    made in the demo (read-only toggles, antivirus actions) really apply to the fake NMC.
.EXAMPLE
    pwsh -File tools/Start-DashboardDemo.ps1 -Port 8765
    # then open http://localhost:8765 and sign in as viewer, op or admin
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 8765,
    # 0.0.0.0 only inside the demo container (see docs/DOCKER.md); the default keeps it on loopback.
    [ValidateSet('127.0.0.1', '0.0.0.0')][string]$Address = '127.0.0.1'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..')
. (Join-Path -Path $repo -ChildPath 'tests/LocalTlsServer.ps1')

$dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'nasuni-dashboard-demo'
$null = New-Item -ItemType Directory -Path $dir -Force
$pki = New-TestPki -Directory $dir

function New-Share($id, $vol, $volName, $filer, $name, $path, [bool]$ro = $false) {
    @{ id = $id; name = $name; volume_guid = $vol; filer_serial_number = $filer; path = $path; readonly = $ro; browseable = $true; smb_encrypt = 'desired'; browser_access = ($id % 3 -eq 0); comment = "$volName share" }
}
$filers = @(
    @{ serial_number = 'NEA-NY-01'; description = 'New York HQ'; build = '10.2.1-115'; management_state = 'nmc'; settings = @{ escrow_passphrase = 'DEMO-ESCROW-SECRET' }; status = @{ offline = $false; osversion = '10.2.1'; uptime = 1843200 } }
    @{ serial_number = 'NEA-LA-02'; description = 'Los Angeles'; build = '10.2.1-115'; management_state = 'nmc'; status = @{ offline = $false; osversion = '10.2.1'; uptime = 922000 } }
    @{ serial_number = 'NEA-LON-03'; description = 'London'; build = '10.1.4-090'; management_state = 'nmc'; status = @{ offline = $true; osversion = '10.1.4'; uptime = 0 } }
    @{ serial_number = 'NEA-SG-04'; description = 'Singapore'; build = '10.2.1-115'; management_state = 'nmc'; status = @{ offline = $false; osversion = '10.2.1'; uptime = 401000 } }
)
$volumes = @(
    @{ guid = 'vol-finance'; name = 'Finance'; filer_serial_number = 'NEA-NY-01'; provider = @{ name = 'Amazon S3' }; protocols = @{ protocols = @('CIFS') }; auth = @{ policy = 'ads' }; antivirus_service = @{ enabled = $true }; remote_access = @{ enabled = $true }; quota = 0; snapshot_retention = @{ retain = 'INFINITE' } }
    @{ guid = 'vol-eng'; name = 'Engineering'; filer_serial_number = 'NEA-LA-02'; provider = @{ name = 'Azure Blob' }; protocols = @{ protocols = @('CIFS', 'NFS') }; auth = @{ policy = 'ads' }; antivirus_service = @{ enabled = $true }; remote_access = @{ enabled = $true }; quota = 0; snapshot_retention = @{ retain = 'BY_AGE' } }
    @{ guid = 'vol-media'; name = 'Media'; filer_serial_number = 'NEA-LA-02'; provider = @{ name = 'Azure Blob' }; protocols = @{ protocols = @('CIFS') }; auth = @{ policy = 'ads' }; antivirus_service = @{ enabled = $false }; remote_access = @{ enabled = $false }; quota = 50000; snapshot_retention = @{ retain = 'BY_COUNT' } }
    @{ guid = 'vol-hr'; name = 'HR'; filer_serial_number = 'NEA-NY-01'; provider = @{ name = 'Amazon S3' }; protocols = @{ protocols = @('CIFS') }; auth = @{ policy = 'ads' }; antivirus_service = @{ enabled = $true }; remote_access = @{ enabled = $true }; quota = 0; snapshot_retention = @{ retain = 'INFINITE' } }
)
$shares = @(
    New-Share 11 'vol-finance' 'Finance' 'NEA-NY-01' 'Finance' '/' $false
    New-Share 12 'vol-finance' 'Finance' 'NEA-NY-01' 'Finance-Archive' '/archive' $true
    New-Share 13 'vol-finance' 'Finance' 'NEA-LON-03' 'Finance' '/' $false
    New-Share 21 'vol-eng' 'Engineering' 'NEA-LA-02' 'Engineering' '/' $false
    New-Share 22 'vol-eng' 'Engineering' 'NEA-SG-04' 'Engineering' '/' $false
    New-Share 23 'vol-eng' 'Engineering' 'NEA-LA-02' 'Builds' '/builds' $false
    New-Share 31 'vol-media' 'Media' 'NEA-LA-02' 'Media' '/' $false
    New-Share 41 'vol-hr' 'HR' 'NEA-NY-01' 'HR-Confidential' '/confidential' $false
)
$av = @(
    @{ id = 501; fpath = '/Finance/Invoices/invoice_0412.pdf.exe'; vname = 'Finance'; volume_guid = 'vol-finance'; filer_serial_number = 'NEA-NY-01' }
    @{ id = 502; fpath = '/Engineering/tools/keygen.zip'; vname = 'Engineering'; volume_guid = 'vol-eng'; filer_serial_number = 'NEA-LA-02' }
    @{ id = 503; fpath = '/Engineering/tmp/eicar.com'; vname = 'Engineering'; volume_guid = 'vol-eng'; filer_serial_number = 'NEA-SG-04' }
)
$now = [datetime]::UtcNow
$notifications = @(
    @{ id = 9001; date = $now.AddMinutes(-12).ToString('s'); priority = 'error'; name = 'Edge Appliance offline'; message = 'NEA-LON-03 has not checked in for 2 hours'; origin = 'NEA-LON-03'; acknowledged = $false }
    @{ id = 9002; date = $now.AddMinutes(-47).ToString('s'); priority = 'alert'; name = 'Antivirus violation'; message = 'Infected file detected on Engineering'; origin = 'NEA-SG-04'; acknowledged = $false }
    @{ id = 9003; date = $now.AddHours(-3).ToString('s'); priority = 'warning'; name = 'Cache usage high'; message = 'Cache is 91% full'; origin = 'NEA-LA-02'; acknowledged = $true }
    @{ id = 9004; date = $now.AddHours(-6).ToString('s'); priority = 'info'; name = 'Snapshot complete'; message = 'Finance snapshot 18422 complete'; origin = 'NEA-NY-01'; acknowledged = $true }
)
$connections = @(
    @{ volume_guid = 'vol-finance'; filer_serial_number = 'NEA-NY-01'; connected = $true }
    @{ volume_guid = 'vol-finance'; filer_serial_number = 'NEA-LON-03'; connected = $false }
    @{ volume_guid = 'vol-eng'; filer_serial_number = 'NEA-LA-02'; connected = $true }
    @{ volume_guid = 'vol-eng'; filer_serial_number = 'NEA-SG-04'; connected = $true }
    @{ volume_guid = 'vol-media'; filer_serial_number = 'NEA-LA-02'; connected = $true }
    @{ volume_guid = 'vol-hr'; filer_serial_number = 'NEA-NY-01'; connected = $true }
)
$health = @(
    @{ filer_serial_number = 'NEA-NY-01'; network = 'Healthy'; filesystem = 'Healthy'; memory = 'Healthy'; cpu = 'Healthy'; nfs = 'Healthy'; smb = 'Healthy' }
    @{ filer_serial_number = 'NEA-LA-02'; network = 'Healthy'; filesystem = 'Healthy'; memory = 'Warning'; cpu = 'Healthy'; nfs = 'Healthy'; smb = 'Healthy' }
    @{ filer_serial_number = 'NEA-LON-03'; network = 'Unhealthy'; filesystem = 'Unknown'; memory = 'Unknown'; cpu = 'Unknown'; nfs = 'Unknown'; smb = 'Unknown' }
    @{ filer_serial_number = 'NEA-SG-04'; network = 'Healthy'; filesystem = 'Healthy'; memory = 'Healthy'; cpu = 'Healthy'; nfs = 'Healthy'; smb = 'Healthy' }
)
$creds = @(
    @{ cred_uuid = 'c-aws-1'; name = 'aws-prod'; cloud_provider = 'amazons3'; account = 'AKIAEXAMPLEDEMO'; hostname = 's3.amazonaws.com'; filer_serial_number = 'NEA-NY-01'; status = 'Active'; in_use = $true; secret = 'DEMO-CLOUD-SECRET-SHOULD-NEVER-SHOW' }
    @{ cred_uuid = 'c-az-1'; name = 'azure-prod'; cloud_provider = 'azure'; account = 'nasunidemo'; hostname = 'blob.core.windows.net'; filer_serial_number = 'NEA-LA-02'; status = 'Active'; in_use = $true; secret = 'DEMO-CLOUD-SECRET-SHOULD-NEVER-SHOW' }
)

$data = @{
    '/api/v1.2/filers/'                              = [System.Collections.ArrayList]$filers
    '/api/v1.2/volumes/'                             = [System.Collections.ArrayList]$volumes
    '/api/v1.2/volumes/filers/shares/'               = [System.Collections.ArrayList]$shares
    '/api/v1.2/volumes/filers/antivirus-violations/' = [System.Collections.ArrayList]$av
    '/api/v1.2/notifications/'                       = [System.Collections.ArrayList]$notifications
    '/api/v1.2/volumes/filer-connections/'           = [System.Collections.ArrayList]$connections
    '/api/v1.2/filers/health/'                       = [System.Collections.ArrayList]$health
    '/api/v1.2/account/cloud-credentials/'           = [System.Collections.ArrayList]$creds
}
foreach ($s in $shares) { $data["/api/v1.2/volumes/$($s.volume_guid)/filers/$($s.filer_serial_number)/shares/$($s.id)/"] = $s }
foreach ($v in $av) { $data["/api/v1.2/volumes/$($v.volume_guid)/filers/$($v.filer_serial_number)/antivirus-violations/$($v.id)/"] = $v }

# DEBUG NOTE (See docs/TROUBLESHOOTING.md, "Demo"): -MaxLifetimeMinutes 0 keeps the fake NMC up for
# the whole demo. With the test default (5 min) the dashboard showed 'Connection refused' and then
# an open circuit breaker for every section.
$nmc = Start-TestTlsServer -Pfx $pki.Pfx -Data $data -MaxLifetimeMinutes 0
Write-Host "Fake NMC (TLS) on port $($nmc.State.Port)"

$cfgPath = Join-Path -Path $dir -ChildPath 'demo-config.psd1'
@"
@{
    Address = '$Address'; Port = $Port; PublicOrigin = 'http://localhost:$Port'; Threads = 2; RefreshSeconds = 30
    AuditLogPath = '$(Join-Path -Path $dir -ChildPath 'audit.jsonl')'
    Nmc = @{ Host = 'localhost'; Port = $($nmc.State.Port); TrustedCaCertificatePath = '$($pki.CaPemPath)'; RevocationMode = 'NoCheck' }
    Auth = @{ Mode = 'DevLogin'; DevUsers = @{ viewer = 'Viewer'; op = 'Operator'; admin = 'Admin' } }
    SecretsSource = 'DevEnvironment'
    Dev = @{ Http = `$true; PublishedToHostLoopbackOnly = `$$($Address -eq '0.0.0.0') }
}
"@ | Set-Content -LiteralPath $cfgPath

$env:NASUNI_ALLOW_NON_FIPS_HOST = '1'
$env:NASUNI_DEV_NMC_USER = 'demo-svc'
$env:NASUNI_DEV_NMC_PASSWORD = 'demo-password'
Write-Host "Dashboard: http://localhost:$Port  (sign in as viewer, op or admin)"
& (Join-Path -Path $repo -ChildPath 'src/Nasuni.Nmc.Dashboard/Start-NasuniDashboard.ps1') -ConfigPath $cfgPath

#Requires -Version 7.4
<#
.SYNOPSIS
    Saves a static, offline copy of the running local demo dashboard (tools/Start-DashboardDemo.ps1).
.DESCRIPTION
    Signs in through the demo's development sign-in page, crawls every same-site link from
    -StartPath, and writes each page, CSV report and stylesheet under -OutDir with links
    rewritten to relative local files. The copy opens from disk or any static web server.
    - Every form posts to the live server, so forms are made inert and CSRF tokens are removed.
    - A banner on each page marks it as a snapshot of sample data.
    Development only: the demo's sign-in exists only on a loopback development dashboard.
.EXAMPLE
    docker compose up -d demo
    pwsh -File tools/Export-DemoSnapshot.ps1 -OutDir demo
    # then open demo/audit.html
#>
[CmdletBinding()]
param(
    [ValidatePattern('^http://(localhost|127\.0\.0\.1):\d+$')][string]$BaseUri = 'http://localhost:8765',
    [Parameter(Mandatory)][string]$OutDir,
    [ValidatePattern('^/')][string]$StartPath = '/audit',
    [ValidateSet('admin', 'op', 'viewer')][string]$User = 'admin'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Base = $BaseUri

# The demo's session cookie is Secure. Browsers send it to http://localhost, but .NET's
# CookieContainer does not over plain HTTP, so the cookie is carried by hand.
$script:Cookie = $null
function Invoke-DemoRequest([string]$Path, [string]$Method = 'GET', [hashtable]$Body) {
    # Sec-Fetch-Site satisfies the dashboard's same-origin check, as a browser's would.
    $p = @{ Uri = $script:Base + $Path; Method = $Method; MaximumRedirection = 0; SkipHttpErrorCheck = $true; ErrorAction = 'SilentlyContinue'; Headers = @{ 'Sec-Fetch-Site' = 'same-origin' } }
    if ($script:Cookie) { $p.Headers.Cookie = $script:Cookie }
    if ($Body) { $p.Body = $Body }
    $r = Invoke-WebRequest @p
    $set = @($r.Headers['Set-Cookie']) | Where-Object { $_ -like 'pode.sid=*' } | Select-Object -Last 1
    if ($set) { $script:Cookie = ($set -split ';')[0] }
    $r
}

function Get-LocalName([string]$Path) {
    $u = [uri]::new([uri]$script:Base, $Path)
    $p = $u.AbsolutePath
    if ($p -eq '/') { return 'index.html' }
    if ($p -like '/static/*' -or $p -like '/reports/*.csv') { return $p.TrimStart('/') }
    $name = $p.Trim('/').Replace('/', '-')
    if ($u.Query) {
        $values = $u.Query.TrimStart('?').Split('&') | ForEach-Object { [uri]::UnescapeDataString(($_ -split '=', 2)[-1]) }
        $name += '-' + ($values -join '-')
    }
    ($name -replace '[^A-Za-z0-9._-]', '_') + '.html'
}

# The demo sign-in page offers each user with a fixed development password; nothing secret.
$login = Invoke-DemoRequest -Path '/login'
$token = [System.Net.WebUtility]::HtmlDecode([regex]::Match($login.Content, 'name="pode\.csrf" value="([^"]+)"').Groups[1].Value)
$demoField = [regex]::Match($login.Content, 'name="password" value="([^"]*)"').Groups[1].Value
$null = Invoke-DemoRequest -Path '/login' -Method POST -Body @{ 'pode.csrf' = $token; username = $User; password = $demoField }
$probe = Invoke-DemoRequest -Path $StartPath
if ($probe.StatusCode -ne 200) { throw "Demo sign-in failed: $StartPath returned $($probe.StatusCode). Is the demo running at $BaseUri?" }

$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
$banner = "<p class=`"note`" style=`"margin:0;padding:6px 16px;border-bottom:1px solid currentColor;opacity:.8`">Static snapshot of the local demo, taken $stamp. All data is sample data from the fake NMC; buttons and forms are disabled.</p>"

$seen = @{}
$queue = [System.Collections.Generic.Queue[string]]::new()
$queue.Enqueue($StartPath)
$null = New-Item -ItemType Directory -Force -Path $OutDir
while ($queue.Count) {
    $path = $queue.Dequeue()
    if ($seen.ContainsKey($path)) { continue }
    $local = Get-LocalName -Path $path
    $seen[$path] = $local
    $r = Invoke-DemoRequest -Path $path
    if ($r.StatusCode -ne 200) { Write-Warning "$path returned $($r.StatusCode); skipped."; continue }
    $target = Join-Path -Path $OutDir -ChildPath $local
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Path $target)
    if ("$($r.Headers['Content-Type'])" -notmatch 'html') {
        [System.IO.File]::WriteAllBytes($target, $r.RawContentStream.ToArray())
        continue
    }
    # Queue every same-site href/src and rewrite it to its local file.
    $html = [regex]::Replace($r.Content, '(href|src)="(/[^"]*)"', {
            param($m)
            $raw = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value)
            if (-not $seen.ContainsKey($raw) -and -not $queue.Contains($raw)) { $queue.Enqueue($raw) }
            '{0}="{1}"' -f $m.Groups[1].Value, (Get-LocalName -Path $raw)
        })
    $html = $html -replace '<input type="hidden" name="pode\.csrf" value="[^"]*">', ''
    $html = $html -replace '<form method="post" action="[^"]*"', '<form method="post" action="#" onsubmit="alert(''Static snapshot: actions are disabled.'');return false;"'
    $html = $html -replace '<body>', "<body>$banner"
    [System.IO.File]::WriteAllText($target, $html, [System.Text.UTF8Encoding]::new($false))
}
$seen.GetEnumerator() | Sort-Object -Property Value | ForEach-Object { [pscustomobject]@{ File = $_.Value; Source = $_.Key } }

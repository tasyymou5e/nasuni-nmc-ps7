#Requires -Version 7.4
<#
.SYNOPSIS
    Build gates: Generate check, Parse, Lint, Test. Any failure exits non-zero.
.EXAMPLE
    ./build/build.ps1                 # all gates
    ./build/build.ps1 -Task Lint
    ./build/build.ps1 -Task Format    # auto-fix formatting in place (Invoke-Formatter)
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Generate', 'Parse', 'Lint', 'Test', 'Format')][string[]]$Task = 'All',
    [ValidateRange(0, 100)][int]$MinimumCoverage = 85
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $root
try {
    $sourceFiles = Get-ChildItem -Path src, build, docker, tools -Recurse -Include *.ps1, *.psm1, *.psd1 -File
    $all = $Task -contains 'All'

    if ($all -or $Task -contains 'Generate') {
        Write-Output '== Generate: committed cmdlets must match Endpoints.psd1'
        $gen = 'src/Nasuni.Nmc/Public/Endpoints.Generated.ps1'
        $before = (Get-FileHash $gen -Algorithm SHA256).Hash
        & ./build/New-EndpointCmdlets.ps1 | Out-Null
        if ((Get-FileHash $gen -Algorithm SHA256).Hash -ne $before) { throw "$gen was stale. It has been regenerated; review and commit it." }
    }

    if ($all -or $Task -contains 'Parse') {
        Write-Output "== Parse: $($sourceFiles.Count) files"
        $failed = 0
        foreach ($f in $sourceFiles) {
            $tokens = $null; $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            foreach ($e in $errors) { $failed++; Write-Output ("{0}:{1}: {2}" -f $f, $e.Extent.StartLineNumber, $e.Message) }
        }
        if ($failed) { throw "Parse gate failed with $failed error(s)." }
    }

    if ($Task -contains 'Format') {
        foreach ($f in $sourceFiles | Where-Object Extension -NE '.psd1') {
            $text = Get-Content -LiteralPath $f.FullName -Raw
            $fixed = Invoke-Formatter -ScriptDefinition $text -Settings ./build/PSScriptAnalyzerSettings.psd1
            if ($fixed -ne $text) { Set-Content -LiteralPath $f.FullName -Value $fixed -NoNewline; Write-Output "formatted $($f.Name)" }
        }
    }

    if ($all -or $Task -contains 'Lint') {
        Write-Output '== Lint: PSScriptAnalyzer (default + Nasuni security rules)'
        $findings = foreach ($dir in 'src', 'build') {
            Invoke-ScriptAnalyzer -Path $dir -Recurse -Settings ./build/PSScriptAnalyzerSettings.psd1
        }
        $findings = @($findings | Where-Object { $_.ScriptName -ne 'NasuniSecurityRules.psm1' })
        $findings | Sort-Object ScriptName, Line | Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 220 | Write-Output
        $blocking = @($findings | Where-Object { $_.Severity -in 'Error', 'Warning' -or $_.RuleName -like 'Nasuni*' })
        if ($blocking.Count) { throw "Lint gate failed with $($blocking.Count) error/warning finding(s)." }
    }

    if ($all -or $Task -contains 'Test') {
        Write-Output '== Test: Pester'
        $env:NASUNI_ALLOW_NON_FIPS_HOST = if ($env:NASUNI_FIPS_CI -eq '1') { '0' } else { '1' }
        $cfg = New-PesterConfiguration
        $cfg.Run.Path = './tests'
        $cfg.Run.Exit = $false
        $cfg.Run.PassThru = $true
        $cfg.Output.Verbosity = 'Normal'
        $cfg.Filter.ExcludeTag = @('Network', 'Fips') | Where-Object { $_ -ne 'Fips' -or $env:NASUNI_FIPS_CI -ne '1' }
        $cfg.CodeCoverage.Enabled = $true
        $cfg.CodeCoverage.Path = @('./src/Nasuni.Nmc/Private', './src/Nasuni.Nmc/Public', './src/Nasuni.Nmc.Mcp/Nasuni.Nmc.Mcp.psm1', './src/Nasuni.Nmc.Dashboard/Nasuni.Nmc.Dashboard.psm1', './src/Nasuni.Nmc.Dashboard/Pages.ps1')
        $cfg.CodeCoverage.OutputPath = './coverage.xml'
        $cfg.TestResult.Enabled = $true
        $cfg.TestResult.OutputPath = './testResults.xml'
        $result = Invoke-Pester -Configuration $cfg
        $coverage = [math]::Round($result.CodeCoverage.CoveragePercent, 1)
        Write-Output "Coverage: $coverage% (minimum $MinimumCoverage%)"
        if ($result.FailedCount -gt 0) { throw "$($result.FailedCount) test(s) failed." }
        if ($coverage -lt $MinimumCoverage) { throw "Coverage $coverage% is below $MinimumCoverage%." }
    }
}
finally { Pop-Location }

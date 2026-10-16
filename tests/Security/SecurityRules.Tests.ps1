BeforeAll {
    $script:RulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../build/Rules/NasuniSecurityRules.psm1'
    function Get-RuleHit([string]$Code) {
        , @(Invoke-ScriptAnalyzer -ScriptDefinition $Code -CustomRulePath $script:RulePath | Where-Object RuleName -Like 'Nasuni*')
    }
}

Describe 'Custom security lint rules' {
    It 'flags <Name>' -ForEach @(
        @{ Name = '-SkipCertificateCheck'; Code = 'Invoke-RestMethod -Uri https://x -SkipCertificateCheck' }
        @{ Name = 'ServicePointManager'; Code = '[System.Net.ServicePointManager]::SecurityProtocol = 3072' }
        @{ Name = 'CertificatePolicy'; Code = '[System.Net.ServicePointManager]::CertificatePolicy = $p' }
        @{ Name = 'ServerCertificateCustomValidationCallback'; Code = '$h.ServerCertificateCustomValidationCallback = $cb' }
        @{ Name = 'MD5'; Code = '[System.Security.Cryptography.MD5]::Create()' }
        @{ Name = 'SHA1'; Code = '[System.Security.Cryptography.SHA1]::Create()' }
        @{ Name = 'GetHashCode'; Code = '$name = $path.GetHashCode()' }
        @{ Name = 'Invoke-Expression'; Code = 'Invoke-Expression $cmd' }
        @{ Name = 'Add-Type'; Code = 'Add-Type -TypeDefinition $src' }
        @{ Name = 'AsPlainText'; Code = 'ConvertTo-SecureString "pw" -AsPlainText -Force' }
        @{ Name = 'string password parameter'; Code = 'function f { param([string]$Password) }' }
        @{ Name = '0..(Count-1) loop'; Code = 'foreach ($i in 0..($r.items.Count-1)) { }' }
    ) {
        (Get-RuleHit $Code).Count | Should -BeGreaterThan 0
    }

    It 'does not flag safe code' {
        (Get-RuleHit 'function f { param([pscredential]$Credential) foreach ($i in $r.items) { [System.Security.Cryptography.SHA256]::HashData([byte[]]@(1)) } }').Count | Should -Be 0
    }

    It 'finds no banned pattern anywhere in src/' {
        $hits = Invoke-ScriptAnalyzer -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src') -Recurse -CustomRulePath $script:RulePath | Where-Object RuleName -Like 'Nasuni*'
        @($hits).Count | Should -Be 0
    }
}

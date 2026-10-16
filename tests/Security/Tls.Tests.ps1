# Live TLS checks against public test endpoints (badssl.com). Tagged Network, so they are
# excluded from the default run; use: Invoke-Pester -Path tests/Security/Tls.Tests.ps1 -TagFilter Network
BeforeAll { . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1') }

Describe 'TLS policy against real servers' -Tag 'Network' {
    It 'accepts a valid certificate and reports an approved suite' {
        $r = Test-NasuniNmcTls -ComputerName 'sha256.badssl.com' -RevocationMode NoCheck
        $r.Error | Should -BeNullOrEmpty
        $r.CertificateValid | Should -BeTrue
        $r.Protocol | Should -BeIn @('Tls12', 'Tls13')
        $r.SpkiSha256 | Should -Match '^[A-Za-z0-9+/]{43}=$'
    }
    It 'rejects <Name>' -ForEach @(
        @{ Name = 'an expired certificate'; Server = 'expired.badssl.com'; Port = 443 }
        @{ Name = 'a wrong host name'; Server = 'wrong.host.badssl.com'; Port = 443 }
        @{ Name = 'a self-signed certificate'; Server = 'self-signed.badssl.com'; Port = 443 }
        @{ Name = 'an untrusted root'; Server = 'untrusted-root.badssl.com'; Port = 443 }
        @{ Name = 'TLS 1.0 only'; Server = 'tls-v1-0.badssl.com'; Port = 1010 }
        @{ Name = 'TLS 1.1 only'; Server = 'tls-v1-1.badssl.com'; Port = 1011 }
    ) {
        $r = Test-NasuniNmcTls -ComputerName $Server -Port $Port -RevocationMode NoCheck
        $r.CertificateValid | Should -BeFalse
        $r.Error | Should -Not -BeNullOrEmpty
    }
    It 'refuses to send credentials when the SPKI pin does not match' {
        $wrongPin = [Convert]::ToBase64String([byte[]]::new(32))
        { Connect-Nasuni -ComputerName 'sha256.badssl.com' -Credential (Get-CanaryCredential) -PinnedSpkiSha256 $wrongPin -RevocationMode NoCheck } |
            Should -Throw '*pin mismatch*No credentials were sent*'
    }
}

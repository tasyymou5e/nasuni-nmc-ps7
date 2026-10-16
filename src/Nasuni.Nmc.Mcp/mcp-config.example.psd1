@{
    # NMC host name (no scheme). There is no default host.
    NmcHost                  = 'nmc.corp.example'
    Port                     = 443

    # Optional: trust only your private CA, and/or pin the NMC public key.
    # Get the pin with: Test-NasuniNmcTls -ComputerName nmc.corp.example | Select-Object SpkiSha256
    TrustedCaCertificatePath = '/etc/nasuni/nmc-ca.pem'
    PinnedSpkiSha256         = ''
    RevocationMode           = 'Online'          # Online | Offline | NoCheck

    # Fraction of the NMC rate limit this process may use (the dashboard uses the rest).
    RateShare                = 0.4
    MaxResultItems           = 500
    MaxResultBytes           = 200000
    LogLevel                 = 'Warning'

    # The NMC credential (a read-only NMC API account) comes from Vault KV v2. No secrets live in this file.
    Vault                    = @{
        Address                  = 'https://vault.corp.example:8200'
        Namespace                = ''
        Mount                    = 'kv'
        SecretPath               = 'nasuni/nmc-ro'
        AuthMethod               = 'Cert'          # Cert | AppRole
        CertRole                 = 'nasuni-mcp'
        # Windows: certificate in Cert:\CurrentUser\My or LocalMachine\My (non-exportable key)
        ClientCertificateThumbprint = ''
        # Linux/macOS: PEM files; the key must be chmod 600
        ClientCertificatePath    = '/etc/nasuni/vault-client.crt'
        ClientKeyPath            = '/etc/nasuni/vault-client.key'
        TrustedCaCertificatePath = '/etc/nasuni/vault-ca.pem'
    }
}

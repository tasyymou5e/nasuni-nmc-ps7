@{
    Address        = '0.0.0.0'
    Port           = 8443
    PublicOrigin   = 'https://nasuni-dash.corp.example:8443'   # used for the same-origin check and OIDC redirect
    Threads        = 4
    RefreshSeconds = 60
    RateShare      = 0.6                                       # share of the NMC rate limit (the MCP server uses the rest)
    AuditLogPath   = '/var/log/nasuni-dashboard/audit.jsonl'   # forward to your SIEM; verify on the Audit page

    Nmc            = @{
        Host                     = 'nmc.corp.example'
        Port                     = 443
        TrustedCaCertificatePath = '/etc/nasuni/nmc-ca.pem'
        PinnedSpkiSha256         = ''
        RevocationMode           = 'Online'
        LogLevel                 = 'Warning'
    }

    Auth           = @{
        Mode         = 'Oidc'
        # Example values for Microsoft Entra ID; any OIDC provider works.
        ClientId     = '00000000-0000-0000-0000-000000000000'
        AuthoriseUrl = 'https://login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize'
        TokenUrl     = 'https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token'
        UserUrl      = 'https://graph.microsoft.com/oidc/userinfo'
        Scopes       = @('openid', 'profile', 'email')
        NameClaim    = 'email'
        GroupsClaim  = 'groups'                # the user-info response must include group ids
        RoleMap      = @{
            Admin    = @('<entra-group-id-nasuni-admins>')
            Operator = @('<entra-group-id-nasuni-operators>')
            Viewer   = @('<entra-group-id-nasuni-viewers>')
        }
    }

    SecretsSource  = 'Vault'
    Vault          = @{
        Address            = 'https://vault.corp.example:8200'
        AuthMethod         = 'Cert'
        CertRole           = 'nasuni-dashboard'
        ClientCertificatePath    = '/etc/nasuni/vault-client.crt'
        ClientKeyPath            = '/etc/nasuni/vault-client.key'
        TrustedCaCertificatePath = '/etc/nasuni/vault-ca.pem'
        Mount              = 'kv'
        ReadOnlySecretPath = 'nasuni/nmc-ro'       # username/password: NMC account without write permission (snapshots)
        OperatorSecretPath = 'nasuni/nmc-ops'      # username/password: NMC account used for confirmed changes
        SessionSecretPath  = 'nasuni/dashboard-session'   # field 'secret'
        AuditKeyPath       = 'nasuni/audit-hmac'          # field 'key' (base64, at least 32 bytes)
        OidcSecretPath     = 'nasuni/dashboard-oidc'      # field 'client_secret'
        PkiMount           = 'pki'
        PkiRole            = 'nasuni-dashboard'
        CertTtlHours       = 720
        RenewBeforeDays    = 7
    }
}

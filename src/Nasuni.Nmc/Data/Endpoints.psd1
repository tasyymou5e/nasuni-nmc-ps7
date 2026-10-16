@{
    ApiVersion = 'v1.2'
    Source     = 'https://docs.api.nasuni.com/api/nmc/v120/'
    Endpoints  = @(
        @{
            Id          = 'Login'
            Group       = 'Auth'
            Method      = 'POST'
            Path        = '/auth/login/'
            PathParams  = @()
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Login'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Auth/paths/~1auth~1login~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'Logout'
            Group       = 'Auth'
            Method      = 'POST'
            Path        = '/auth/logout/'
            PathParams  = @()
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Logout'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Auth/paths/~1auth~1logout~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'GetIndex'
            Group       = 'Index'
            Method      = 'GET'
            Path        = '/'
            PathParams  = @()
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'View top-level endpoints'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Index/paths/~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListCloudCredentials'
            Group       = 'Account'
            Method      = 'GET'
            Path        = '/account/cloud-credentials/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List all cloud credentials'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Account/paths/~1account~1cloud-credentials~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetCloudCredential'
            Group       = 'Account'
            Method      = 'GET'
            Path        = '/account/cloud-credentials/{cred_uuid}/'
            PathParams  = @('cred_uuid')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'Get a list of cloud credentials by UUID'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Account/paths/~1account~1cloud-credentials~1%7Bcred_uuid%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetFilerCloudCredential'
            Group       = 'Account'
            Method      = 'GET'
            Path        = '/account/cloud-credentials/{cred_uuid}/filers/{filer_serial}/'
            PathParams  = @('cred_uuid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get one cloud credential on a filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Account/paths/~1account~1cloud-credentials~1%7Bcred_uuid%7D~1filers~1%7Bfiler_serial%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'UpdateFilerCloudCredential'
            Group       = 'Account'
            Method      = 'PATCH'
            Path        = '/account/cloud-credentials/{cred_uuid}/filers/{filer_serial}/'
            PathParams  = @('cred_uuid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Update a cloud credential on a filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Account/paths/~1account~1cloud-credentials~1%7Bcred_uuid%7D~1filers~1%7Bfiler_serial%7D~1/patch/'
            Verified    = $true
        }
        @{
            Id          = 'ListFilers'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List Filers'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetFiler'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/'
            PathParams  = @('filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'UpdateFiler'
            Group       = 'Filers'
            Method      = 'PATCH'
            Path        = '/filers/{filer_serial}/'
            PathParams  = @('filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Update a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1/patch/'
            Verified    = $true
        }
        @{
            Id          = 'ListAmqpDestinations'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/amqp-audit-destinations/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List AMQP Destinations'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1amqp-audit-destinations~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListFilerAmqpDestinations'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/amqp-audit-destinations/'
            PathParams  = @('filer_serial')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List AMQP Destinations for a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1amqp-audit-destinations~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'NewAmqpDestination'
            Group       = 'Filers'
            Method      = 'POST'
            Path        = '/filers/{filer_serial}/amqp-audit-destinations/'
            PathParams  = @('filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Create an AMQP Destination'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1amqp-audit-destinations~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'GetAmqpDestination'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/amqp-audit-destinations/{amqp_destination_name}'
            PathParams  = @('filer_serial','amqp_destination_name')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get a single AMQP destination'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1amqp-audit-destinations~1%7Bamqp_destination_name%7D/get/'
            Verified    = $true
        }
        @{
            Id          = 'RemoveAmqpDestination'
            Group       = 'Filers'
            Method      = 'DELETE'
            Path        = '/filers/{filer_serial}/amqp-audit-destinations/{amqp_destination_name}'
            PathParams  = @('filer_serial','amqp_destination_name')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $true
            Summary     = 'Delete an AMQP destination'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1amqp-audit-destinations~1%7Bamqp_destination_name%7D/delete/'
            Verified    = $true
        }
        @{
            Id          = 'UpdateAmqpDestination'
            Group       = 'Filers'
            Method      = 'PATCH'
            Path        = '/filers/{filer_serial}/amqp-audit-destinations/{amqp_destination_name}'
            PathParams  = @('filer_serial','amqp_destination_name')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Update an AMQP destination'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1amqp-audit-destinations~1%7Bamqp_destination_name%7D/patch/'
            Verified    = $true
        }
        @{
            Id          = 'ListCifsClients'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/cifsclients/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List CIFS clients'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1cifsclients~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListFilerCifsClients'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/cifsclients/'
            PathParams  = @('filer_serial')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List CIFS clients for a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1cifsclients~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetCifsClient'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/cifsclients/{cifs_client_id}'
            PathParams  = @('filer_serial','cifs_client_id')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get CIFS client'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1cifsclients~1%7Bcifs_client_id%7D/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListCifsLocks'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/cifsclients/locks/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List CIFS file locks'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1cifsclients~1locks~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListFilerCifsLocks'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/cifsclients/locks/'
            PathParams  = @('filer_serial')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List CIFS file locks for a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1cifsclients~1locks~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListCifsClientLocks'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/cifsclients/{cifs_client_id}/locks/'
            PathParams  = @('filer_serial','cifs_client_id')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List CIFS file locks for a client'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1cifsclients~1%7Bcifs_client_id%7D~1locks~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListFtpClients'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/ftpclients/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List FTP clients'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1ftpclients~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListFilerFtpClients'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/ftpclients/'
            PathParams  = @('filer_serial')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List FTP clients for a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1ftpclients~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetFtpClient'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/ftpclients/{ftp_client_id}'
            PathParams  = @('filer_serial','ftp_client_id')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get FTP client'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1ftpclients~1%7Bftp_client_id%7D/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListEncryptionKeys'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/encryption-keys/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List encryption keys'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1encryption-keys~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListFilerEncryptionKeys'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/encryption-keys/'
            PathParams  = @('filer_serial')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List encryption keys for a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1encryption-keys~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'AddFilerEncryptionKey'
            Group       = 'Filers'
            Method      = 'POST'
            Path        = '/filers/{filer_serial}/encryption-keys/'
            PathParams  = @('filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Upload encryption keys for a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1encryption-keys~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'GetFilerEncryptionKey'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/encryption-keys/{encryption_key_id}/'
            PathParams  = @('filer_serial','encryption_key_id')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get a Filer encryption key'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1encryption-keys~1%7Bencryption_key_id%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListFilerHealth'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/health/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List health status for all Filers'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1health~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetFilerHealth'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/health/'
            PathParams  = @('filer_serial')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List health status for a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1health~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListBlockedClients'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/blocked-clients/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List blocked clients across all Filers'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1blocked-clients~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListFilerBlockedClients'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/blocked-clients/'
            PathParams  = @('filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'List blocked clients on a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1blocked-clients~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'BlockFilerClient'
            Group       = 'Filers'
            Method      = 'POST'
            Path        = '/filers/{filer_serial}/blocked-clients/'
            PathParams  = @('filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Block a client IP address on a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1blocked-clients~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'GetFilerBlockedClient'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/blocked-clients/{blocked_ip}/'
            PathParams  = @('filer_serial','blocked_ip')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get specific blocked client on specific Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1blocked-clients~1%7Bblocked_ip%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'UnblockFilerClient'
            Group       = 'Filers'
            Method      = 'DELETE'
            Path        = '/filers/{filer_serial}/blocked-clients/{blocked_ip}/'
            PathParams  = @('filer_serial','blocked_ip')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $true
            Summary     = 'Unblock a client IP address on a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1blocked-clients~1%7Bblocked_ip%7D~1/delete/'
            Verified    = $true
        }
        @{
            Id          = 'ListBlockedIpAddresses'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/blocked-sources/ip-addresses/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List blocked IP addresses across all Filers'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1blocked-sources~1ip-addresses~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListBlockedUsernames'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/blocked-sources/usernames/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List blocked usernames across all Filers'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1blocked-sources~1usernames~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListFilerBlockedIpAddresses'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/blocked-sources/ip-addresses/'
            PathParams  = @('filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'List blocked IP addresses on a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1blocked-sources~1ip-addresses~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListFilerBlockedUsernames'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/blocked-sources/usernames/'
            PathParams  = @('filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'List blocked usernames on a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1blocked-sources~1usernames~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetFilerBlockedIpAddress'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/blocked-sources/ip-addresses/{blocked_ip}/'
            PathParams  = @('filer_serial','blocked_ip')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get specific blocked IP address on specific Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1blocked-sources~1ip-addresses~1%7Bblocked_ip%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'BlockFilerIpAddress'
            Group       = 'Filers'
            Method      = 'PUT'
            Path        = '/filers/{filer_serial}/blocked-sources/ip-addresses/{blocked_ip}/'
            PathParams  = @('filer_serial','blocked_ip')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Block an IP address on a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1blocked-sources~1ip-addresses~1%7Bblocked_ip%7D~1/put/'
            Verified    = $true
        }
        @{
            Id          = 'UnblockFilerIpAddress'
            Group       = 'Filers'
            Method      = 'DELETE'
            Path        = '/filers/{filer_serial}/blocked-sources/ip-addresses/{blocked_ip}/'
            PathParams  = @('filer_serial','blocked_ip')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $true
            Summary     = 'Unblock an IP address on a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1blocked-sources~1ip-addresses~1%7Bblocked_ip%7D~1/delete/'
            Verified    = $true
        }
        @{
            Id          = 'GetFilerBlockedUsername'
            Group       = 'Filers'
            Method      = 'GET'
            Path        = '/filers/{filer_serial}/blocked-sources/usernames/{blocked_username}/'
            PathParams  = @('filer_serial','blocked_username')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get specific blocked username on specific Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1blocked-sources~1usernames~1%7Bblocked_username%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'BlockFilerUsername'
            Group       = 'Filers'
            Method      = 'PUT'
            Path        = '/filers/{filer_serial}/blocked-sources/usernames/{blocked_username}/'
            PathParams  = @('filer_serial','blocked_username')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Block a username on a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1blocked-sources~1usernames~1%7Bblocked_username%7D~1/put/'
            Verified    = $true
        }
        @{
            Id          = 'UnblockFilerUsername'
            Group       = 'Filers'
            Method      = 'DELETE'
            Path        = '/filers/{filer_serial}/blocked-sources/usernames/{blocked_username}/'
            PathParams  = @('filer_serial','blocked_username')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $true
            Summary     = 'Unblock a username on a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Filers/paths/~1filers~1%7Bfiler_serial%7D~1blocked-sources~1usernames~1%7Bblocked_username%7D~1/delete/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumes'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List volumes'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'NewVolume'
            Group       = 'Volumes'
            Method      = 'POST'
            Path        = '/volumes/'
            PathParams  = @()
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Create volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'GetVolume'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/'
            PathParams  = @('volume_guid')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'UpdateVolume'
            Group       = 'Volumes'
            Method      = 'PATCH'
            Path        = '/volumes/{volume_guid}/'
            PathParams  = @('volume_guid')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Update volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1/patch/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeFilerSettings'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/'
            PathParams  = @('volume_guid')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List Filer settings for a volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetVolumeFilerSettings'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get volume settings for a Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'UpdateVolumeFilerSettings'
            Group       = 'Volumes'
            Method      = 'PATCH'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Update the settings for a volume on a specific Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1/patch/'
            Verified    = $true
        }
        @{
            Id          = 'ListShares'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/filers/shares/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List shares'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1filers~1shares~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeShares'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/shares/'
            PathParams  = @('volume_guid')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List shares for a volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1shares~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeFilerShares'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/shares/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List shares for a volume and Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1shares~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'NewShare'
            Group       = 'Volumes'
            Method      = 'POST'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/shares/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Create share'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1shares~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'GetShare'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/shares/{share_id}/'
            PathParams  = @('volume_guid','filer_serial','share_id')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get share'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1shares~1%7Bshare_id%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'RemoveShare'
            Group       = 'Volumes'
            Method      = 'DELETE'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/shares/{share_id}/'
            PathParams  = @('volume_guid','filer_serial','share_id')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $true
            Summary     = 'Delete a share'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1shares~1%7Bshare_id%7D~1/delete/'
            Verified    = $true
        }
        @{
            Id          = 'UpdateShare'
            Group       = 'Volumes'
            Method      = 'PATCH'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/shares/{share_id}/'
            PathParams  = @('volume_guid','filer_serial','share_id')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Update share'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1shares~1%7Bshare_id%7D~1/patch/'
            Verified    = $true
        }
        @{
            Id          = 'ListExports'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/filers/exports/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List exports'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1filers~1exports~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeExports'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/exports/'
            PathParams  = @('volume_guid')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List exports for a volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1exports~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeFilerExports'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/exports/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List exports for a volume and Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1exports~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'NewExport'
            Group       = 'Volumes'
            Method      = 'POST'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/exports/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Create export'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1exports~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'GetExport'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/exports/{export_id}/'
            PathParams  = @('volume_guid','filer_serial','export_id')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get export'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1exports~1%7Bexport_id%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'RemoveExport'
            Group       = 'Volumes'
            Method      = 'DELETE'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/exports/{export_id}/'
            PathParams  = @('volume_guid','filer_serial','export_id')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $true
            Summary     = 'Delete export'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1exports~1%7Bexport_id%7D~1/delete/'
            Verified    = $true
        }
        @{
            Id          = 'UpdateExport'
            Group       = 'Volumes'
            Method      = 'PATCH'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/exports/{export_id}/'
            PathParams  = @('volume_guid','filer_serial','export_id')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Update export'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1exports~1%7Bexport_id%7D~1/patch/'
            Verified    = $true
        }
        @{
            Id          = 'ListNfsHostOptions'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/exports/{export_id}/nfs_host_options/'
            PathParams  = @('volume_guid','filer_serial','export_id')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List NFS host options for an export'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1exports~1%7Bexport_id%7D~1nfs_host_options~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'NewNfsHostOption'
            Group       = 'Volumes'
            Method      = 'POST'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/exports/{export_id}/nfs_host_options/'
            PathParams  = @('volume_guid','filer_serial','export_id')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Create NFS host option'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1exports~1%7Bexport_id%7D~1nfs_host_options~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'GetNfsHostOption'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/exports/{export_id}/nfs_host_options/{host_option_id}/'
            PathParams  = @('volume_guid','filer_serial','export_id','host_option_id')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get a host option for an export'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1exports~1%7Bexport_id%7D~1nfs_host_options~1%7Bhost_option_id%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'RemoveNfsHostOption'
            Group       = 'Volumes'
            Method      = 'DELETE'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/exports/{export_id}/nfs_host_options/{host_option_id}/'
            PathParams  = @('volume_guid','filer_serial','export_id','host_option_id')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $true
            Summary     = 'Delete host option'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1exports~1%7Bexport_id%7D~1nfs_host_options~1%7Bhost_option_id%7D~1/delete/'
            Verified    = $true
        }
        @{
            Id          = 'UpdateNfsHostOption'
            Group       = 'Volumes'
            Method      = 'PATCH'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/exports/{export_id}/nfs_host_options/{host_option_id}/'
            PathParams  = @('volume_guid','filer_serial','export_id','host_option_id')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Update an existing host option'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1exports~1%7Bexport_id%7D~1nfs_host_options~1%7Bhost_option_id%7D~1/patch/'
            Verified    = $true
        }
        @{
            Id          = 'ListFtpDirectories'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/filers/ftp-directories/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List FTP directories'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1filers~1ftp-directories~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeFtpDirectories'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/ftp-directories/'
            PathParams  = @('volume_guid')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List FTP directories for a volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1ftp-directories~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeFilerFtpDirectories'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/ftp-directories/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List FTP directories for a volume and Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1ftp-directories~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetFtpDirectory'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/ftp-directories/{ftpdir_id}/'
            PathParams  = @('volume_guid','filer_serial','ftpdir_id')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get FTP directory'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1ftp-directories~1%7Bftpdir_id%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeConnections'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/filer-connections/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List volume connections'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1filer-connections~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeConnectionsForVolume'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filer-connections/'
            PathParams  = @('volume_guid')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List volume connections for a volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filer-connections~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetVolumeConnection'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filer-connections/{filer_serial}/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get volume connection'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filer-connections~1%7Bfiler_serial%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListAntivirusViolations'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/filers/antivirus-violations/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List antivirus violations'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1filers~1antivirus-violations~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeAntivirusViolations'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/antivirus-violations/'
            PathParams  = @('volume_guid')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List antivirus violations for a volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1antivirus-violations~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeFilerAntivirusViolations'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/antivirus-violations/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List antivirus violations for a volume and Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1antivirus-violations~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetAntivirusViolation'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/antivirus-violations/{antivirus_id}/'
            PathParams  = @('volume_guid','filer_serial','antivirus_id')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get antivirus violation'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1antivirus-violations~1%7Bantivirus_id%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'RemoveAntivirusViolation'
            Group       = 'Volumes'
            Method      = 'DELETE'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/antivirus-violations/{antivirus_id}/'
            PathParams  = @('volume_guid','filer_serial','antivirus_id')
            QueryParams = @('action')
            Paged       = $false
            Async       = $true
            Destructive = $true
            Summary     = 'Delete antivirus violation (action=delete_file deletes the infected file; ignore_violation clears it)'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1antivirus-violations~1%7Bantivirus_id%7D~1/delete/'
            Verified    = $true
        }
        @{
            Id          = 'ListFolderQuotas'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/folder-quotas/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List folder quotas'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1folder-quotas~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeFolderQuotas'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/folder-quotas/'
            PathParams  = @('volume_guid')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List folder quotas for a volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1folder-quotas~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'NewFolderQuota'
            Group       = 'Volumes'
            Method      = 'POST'
            Path        = '/volumes/{volume_guid}/folder-quotas/'
            PathParams  = @('volume_guid')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Create folder quota'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1folder-quotas~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'GetFolderQuota'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/folder-quotas/{folder_quota_id}/'
            PathParams  = @('volume_guid','folder_quota_id')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get folder quota'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1folder-quotas~1%7Bfolder_quota_id%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'RemoveFolderQuota'
            Group       = 'Volumes'
            Method      = 'DELETE'
            Path        = '/volumes/{volume_guid}/folder-quotas/{folder_quota_id}/'
            PathParams  = @('volume_guid','folder_quota_id')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $true
            Summary     = 'Delete folder quota'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1folder-quotas~1%7Bfolder_quota_id%7D~1/delete/'
            Verified    = $true
        }
        @{
            Id          = 'UpdateFolderQuota'
            Group       = 'Volumes'
            Method      = 'PATCH'
            Path        = '/volumes/{volume_guid}/folder-quotas/{folder_quota_id}/'
            PathParams  = @('volume_guid','folder_quota_id')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Update folder quota'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1folder-quotas~1%7Bfolder_quota_id%7D~1/patch/'
            Verified    = $true
        }
        @{
            Id          = 'ListSnapshotStatuses'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/filers/snapshots/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List snapshot statuses'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1filers~1snapshots~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeSnapshotStatuses'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/snapshots/'
            PathParams  = @('volume_guid')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List snapshot statuses for a volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1snapshots~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetVolumeFilerSnapshotStatus'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/snapshots/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'List snapshot status for a volume and Filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1snapshots~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'RequestSnapshot'
            Group       = 'Volumes'
            Method      = 'POST'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/snapshots/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Request snapshot for volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1snapshots~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'EnableGlobalLockFolder'
            Group       = 'Volumes'
            Method      = 'POST'
            Path        = '/volumes/{volume_guid}/global-lock-folders/'
            PathParams  = @('volume_guid')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Enable global locking and its various modes on a specified path'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1global-lock-folders~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'DisableGlobalLockFolder'
            Group       = 'Volumes'
            Method      = 'DELETE'
            Path        = '/volumes/{volume_guid}/global-lock-folders/{path}'
            PathParams  = @('volume_guid','path')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $true
            Summary     = 'Disable global locking on a specified path'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1global-lock-folders~1%7Bpath%7D/delete/'
            Verified    = $true
        }
        @{
            Id          = 'ListKnownPaths'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/filers/paths/'
            PathParams  = @()
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get a list of all known paths'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1filers~1paths~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeKnownPaths'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/paths/'
            PathParams  = @('volume_guid')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get a list of all known paths with a specific volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1paths~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeFilerKnownPaths'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/paths/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get a list of all known paths with a specific volume and filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1paths~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetPathInfo'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/path/{path}'
            PathParams  = @('volume_guid','filer_serial','path')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get info on a specific path'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1path~1%7Bpath%7D/get/'
            Verified    = $true
        }
        @{
            Id          = 'RefreshPathInfo'
            Group       = 'Volumes'
            Method      = 'POST'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/path/{path}'
            PathParams  = @('volume_guid','filer_serial','path')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Refresh info about a given path'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1path~1%7Bpath%7D/post/'
            Verified    = $true
        }
        @{
            Id          = 'BringPathIntoCache'
            Group       = 'Volumes'
            Method      = 'POST'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/cache-path/{path}'
            PathParams  = @('volume_guid','filer_serial','path')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Bring path into cache'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1cache-path~1%7Bpath%7D/post/'
            Verified    = $true
        }
        @{
            Id          = 'NewDirectoryPath'
            Group       = 'Volumes'
            Method      = 'POST'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/make-dir-path/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Try to make the given directory path'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1make-dir-path~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'ListPinnedFolders'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/filers/pinned-folders/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'Get a list of all pinned folders'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1filers~1pinned-folders~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumePinnedFolders'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/pinned-folders/'
            PathParams  = @('volume_guid')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'Get a list of all pinned folders in a volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1pinned-folders~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeFilerPinnedFolders'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/pinned-folders/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'Get a list of pinned folders in a volume for a specific filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1pinned-folders~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'SetPinnedFolder'
            Group       = 'Volumes'
            Method      = 'POST'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/pinned-folders/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Set pinning mode'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1pinned-folders~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'GetPinnedFolder'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/pinned-folder/{path}'
            PathParams  = @('volume_guid','filer_serial','path')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get pinning status for the path'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1pinned-folder~1%7Bpath%7D/get/'
            Verified    = $true
        }
        @{
            Id          = 'DisablePinnedFolder'
            Group       = 'Volumes'
            Method      = 'DELETE'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/pinned-folder/{path}'
            PathParams  = @('volume_guid','filer_serial','path')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $true
            Summary     = 'Disable pinning mode on a folder'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1pinned-folder~1%7Bpath%7D/delete/'
            Verified    = $true
        }
        @{
            Id          = 'ListAutoCachedFolders'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/filers/auto-cached-folders/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'Get a list of all auto cache enabled folders'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1filers~1auto-cached-folders~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeAutoCachedFolders'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/auto-cached-folders/'
            PathParams  = @('volume_guid')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'Get a list of all auto cache enabled folders in a volume'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1auto-cached-folders~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListVolumeFilerAutoCachedFolders'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/auto-cached-folders/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List auto cache enabled folders for a volume on a filer'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1auto-cached-folders~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'SetAutoCachedFolder'
            Group       = 'Volumes'
            Method      = 'POST'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/auto-cached-folders/'
            PathParams  = @('volume_guid','filer_serial')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $false
            Summary     = 'Set auto caching mode'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1auto-cached-folders~1/post/'
            Verified    = $true
        }
        @{
            Id          = 'GetAutoCachedFolder'
            Group       = 'Volumes'
            Method      = 'GET'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/auto-cached-folder/{path}'
            PathParams  = @('volume_guid','filer_serial','path')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get auto cache folder status for a folder'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1auto-cached-folder~1%7Bpath%7D/get/'
            Verified    = $true
        }
        @{
            Id          = 'DisableAutoCachedFolder'
            Group       = 'Volumes'
            Method      = 'DELETE'
            Path        = '/volumes/{volume_guid}/filers/{filer_serial}/auto-cached-folder/{path}'
            PathParams  = @('volume_guid','filer_serial','path')
            QueryParams = @()
            Paged       = $false
            Async       = $true
            Destructive = $true
            Summary     = 'Disable auto cache mode on a folder'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Volumes/paths/~1volumes~1%7Bvolume_guid%7D~1filers~1%7Bfiler_serial%7D~1auto-cached-folder~1%7Bpath%7D/delete/'
            Verified    = $true
        }
        @{
            Id          = 'ListNotifications'
            Group       = 'Notifications'
            Method      = 'GET'
            Path        = '/notifications/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List notifications'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Notifications/paths/~1notifications~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetNotification'
            Group       = 'Notifications'
            Method      = 'GET'
            Path        = '/notifications/{notification_id}/'
            PathParams  = @('notification_id')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get notification'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Notifications/paths/~1notifications~1%7Bnotification_id%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'ListMessages'
            Group       = 'Messages'
            Method      = 'GET'
            Path        = '/messages/'
            PathParams  = @()
            QueryParams = @('limit','offset')
            Paged       = $true
            Async       = $false
            Destructive = $false
            Summary     = 'List messages'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Messages/paths/~1messages~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'GetMessage'
            Group       = 'Messages'
            Method      = 'GET'
            Path        = '/messages/{message_id}/'
            PathParams  = @('message_id')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $false
            Summary     = 'Get message'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Messages/paths/~1messages~1%7Bmessage_id%7D~1/get/'
            Verified    = $true
        }
        @{
            Id          = 'RemoveMessage'
            Group       = 'Messages'
            Method      = 'DELETE'
            Path        = '/messages/{message_id}/'
            PathParams  = @('message_id')
            QueryParams = @()
            Paged       = $false
            Async       = $false
            Destructive = $true
            Summary     = 'Delete message'
            DocUrl      = 'https://docs.api.nasuni.com/api/nmc/v120/reference/tag/Messages/paths/~1messages~1%7Bmessage_id%7D~1/delete/'
            Verified    = $true
        }
    )
}

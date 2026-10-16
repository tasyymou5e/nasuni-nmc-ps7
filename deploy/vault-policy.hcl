# Vault policies for Nasuni.Nmc. Each consumer gets only its own secret, read-only.
#
#   vault policy write nasuni-mcp       - <<< "$(sed -n '/^# --- nasuni-mcp/,/^# --- end/p' vault-policy.hcl)"
#   vault policy write nasuni-dashboard - <<< "$(sed -n '/^# --- nasuni-dashboard/,/^# --- end/p' vault-policy.hcl)"
#
# Cert auth role (MCP host), bound to that host's client certificate:
#   vault write auth/cert/certs/nasuni-mcp display_name=nasuni-mcp policies=nasuni-mcp \
#       certificate=@mcp-client-ca.pem allowed_common_names=nasuni-mcp token_ttl=5m token_max_ttl=15m
#
# FIPS: run a Vault Enterprise FIPS 140-3 build (+fips1403) with an HSM-backed seal.
# Vault Community is not FIPS-validated.

# --- nasuni-mcp (read-only NMC account for the MCP server)
path "kv/data/nasuni/nmc-ro" {
  capabilities = ["read"]
}
# --- end

# --- nasuni-dashboard (read-only account for snapshots; operator account only for confirmed changes)
path "kv/data/nasuni/nmc-ro" {
  capabilities = ["read"]
}
path "kv/data/nasuni/nmc-ops" {
  capabilities = ["read"]
}
path "kv/data/nasuni/dashboard-session" {
  capabilities = ["read"]
}
path "kv/data/nasuni/dashboard-oidc" {
  capabilities = ["read"]
}
path "kv/data/nasuni/audit-hmac" {
  capabilities = ["read"]
}
path "pki/issue/nasuni-dashboard" {
  capabilities = ["update"]
}
# --- end

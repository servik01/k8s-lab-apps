resource "vault_policy" "netbird_read" {
  name = "netbird-read"

  policy = <<-EOT
    path "secret/data/netbird" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "netbird" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "netbird"
  bound_service_account_names      = ["netbird-vault-auth"]
  bound_service_account_namespaces = ["netbird"]
  audience                         = "vault"
  token_policies                   = [vault_policy.netbird_read.name]
  token_ttl                        = 600
  token_max_ttl                    = 1800
}

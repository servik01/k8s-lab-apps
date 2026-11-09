resource "vault_policy" "netbird_operator_read" {
  name = "netbird-operator-read"

  policy = <<-EOT
    path "secret/data/netbird-operator" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "netbird_operator" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "netbird-operator"
  bound_service_account_names      = ["netbird-operator-vault-auth"]
  bound_service_account_namespaces = ["netbird"]
  audience                         = "vault"
  token_policies                   = [vault_policy.netbird_operator_read.name]
  token_ttl                        = 600
  token_max_ttl                    = 1800
}

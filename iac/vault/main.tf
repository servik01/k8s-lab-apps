resource "vault_mount" "secret" {
  path    = "secret"
  type    = "kv"
  options = { version = "2" }
}

resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

# Vault сам ходит в API по токену своего ServiceAccount и CA пода
resource "vault_kubernetes_auth_backend_config" "this" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = "https://kubernetes.default.svc:443"
}

resource "vault_policy" "demo_read" {
  name   = "demo-read"
  policy = <<-EOT
    path "secret/data/demo/*" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "demo" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "demo"
  bound_service_account_names      = ["vault-demo"]
  bound_service_account_namespaces = ["vault-demo"]
  token_policies                   = [vault_policy.demo_read.name]
  token_ttl                        = 3600
}

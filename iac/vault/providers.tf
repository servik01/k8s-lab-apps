terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
    }
  }
}

# адрес и токен берутся из окружения: VAULT_ADDR и VAULT_TOKEN
provider "vault" {}

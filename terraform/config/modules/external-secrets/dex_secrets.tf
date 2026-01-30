locals {
  vault_id       = data.oci_kms_vaults.existing_vault.vaults[0].id
  vault_endpoint = data.oci_kms_vaults.existing_vault.vaults[0].management_endpoint

  dex_secrets = {
    "dex-grafana-client"         = "Dex client secret for Grafana"
    "dex-s3-proxy-client-secret" = "Dex client secret for S3 Proxy"
    "dex-envoy-client-secret"    = "Dex client secret for Envoy Gateway"
  }

  existing_secret_names = [for s in data.oci_vault_secrets.existing_dex_secrets.secrets : s.secret_name]
  # Only create secrets that don't already exist
  secrets_to_create = {
    for name, description in local.dex_secrets :
    name => description if !contains(local.existing_secret_names, name)
  }

  key_id = data.oci_kms_keys.existing_key.keys[0].id
}

# Data source to check if secrets already exist
data "oci_vault_secrets" "existing_dex_secrets" {
  vault_id       = local.vault_id
  compartment_id = var.compartment_id
}

# Data source to get the KMS key for encrypting vault secrets
data "oci_kms_keys" "existing_key" {
  compartment_id      = var.compartment_id
  management_endpoint = local.vault_endpoint

  filter {
    name   = "display_name"
    values = ["k8s-master-key"]
  }
}

# Generate random secrets for Dex clients
# Using alphanumeric only to avoid URL encoding issues in OAuth token exchange
# Special characters like %, +, =, [, ], {, } cause issues with HTTP Basic auth
resource "random_password" "dex_client" {
  for_each = local.dex_secrets

  length  = 32
  special = false
}

# Create OCI Vault secrets only if they don't exist
resource "oci_vault_secret" "dex_client" {
  for_each = local.secrets_to_create

  compartment_id = var.compartment_id
  vault_id       = local.vault_id
  key_id         = local.key_id

  secret_name = each.key
  description = each.value

  secret_content {
    content      = base64encode(random_password.dex_client[each.key].result)
    content_type = "BASE64"
  }
}

locals {
  vault_id       = data.oci_kms_vaults.existing_vault.vaults[0].id
  vault_endpoint = data.oci_kms_vaults.existing_vault.vaults[0].management_endpoint

  dex_secrets = {
    "dex-grafana-client"             = "Dex client secret for Grafana"
    "dex-s3-proxy-client-secret"     = "Dex client secret for S3 Proxy"
    "dex-envoy-client-secret"        = "Dex client secret for Envoy Gateway"
    "dex-actualbudget-client-secret" = "Dex client secret for Actual Budget"
  }

  key_id = data.oci_kms_keys.existing_key.keys[0].id
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

# Secrets created before they were managed here are adopted with import blocks (see ../../main.tf)
resource "oci_vault_secret" "dex_client" {
  for_each = local.dex_secrets

  compartment_id = var.compartment_id
  vault_id       = local.vault_id
  key_id         = local.key_id

  secret_name = each.key
  description = each.value

  secret_content {
    content      = base64encode(random_password.dex_client[each.key].result)
    content_type = "BASE64"
  }

  # never rotate a client secret that Dex and its client already use
  lifecycle {
    ignore_changes = [secret_content]
  }
}

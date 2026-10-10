data "oci_kms_vaults" "existing_vault" {
  compartment_id = var.compartment_id

  filter {
    name   = "display_name"
    values = ["k8s-vault"]
  }
}

data "oci_kms_keys" "existing_key" {
  compartment_id      = var.compartment_id
  management_endpoint = data.oci_kms_vaults.existing_vault.vaults[0].management_endpoint

  filter {
    name   = "display_name"
    values = ["k8s-master-key"]
  }
}

# One JSON secret with everything Longhorn needs; the ExternalSecret in
# gitops/core/longhorn/secret.yaml extracts each property into the K8s Secret.
resource "oci_vault_secret" "longhorn_backup_s3" {
  compartment_id = var.compartment_id
  vault_id       = data.oci_kms_vaults.existing_vault.vaults[0].id
  key_id         = data.oci_kms_keys.existing_key.keys[0].id

  secret_name = "longhorn-backup-s3"
  description = "S3-compatible credentials and target for Longhorn backups"

  secret_content {
    content_type = "BASE64"
    content = base64encode(jsonencode({
      AWS_ACCESS_KEY_ID     = oci_identity_customer_secret_key.longhorn_backup.id
      AWS_SECRET_ACCESS_KEY = oci_identity_customer_secret_key.longhorn_backup.key
      AWS_ENDPOINTS         = "https://${data.oci_objectstorage_namespace.ns.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
      BACKUP_TARGET         = "s3://${oci_objectstorage_bucket.longhorn_backups.name}@${var.region}/"
    }))
  }
}

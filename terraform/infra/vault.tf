resource "oci_kms_vault" "main" {
  compartment_id = var.compartment_id
  display_name   = "k8s-vault"
  vault_type     = "DEFAULT"
}

resource "oci_kms_key" "main" {
  compartment_id      = var.compartment_id
  display_name        = "k8s-master-key"
  management_endpoint = oci_kms_vault.main.management_endpoint

  key_shape {
    algorithm = "AES"
    length    = 32
  }
}

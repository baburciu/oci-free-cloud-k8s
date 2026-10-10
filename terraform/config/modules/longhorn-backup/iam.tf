# Dedicated user whose only permission is the backup bucket; its Customer Secret Key
# is the S3-compatible access/secret key pair used by Longhorn.
resource "oci_identity_group" "longhorn_backup" {
  compartment_id = var.compartment_id
  description    = "LonghornBackup"
  name           = "LonghornBackup"
}

resource "oci_identity_user" "longhorn_backup" {
  compartment_id = var.compartment_id
  description    = "LonghornBackup"
  name           = "LonghornBackup"
  email          = var.user_email
}

resource "oci_identity_user_group_membership" "longhorn_backup" {
  group_id = oci_identity_group.longhorn_backup.id
  user_id  = oci_identity_user.longhorn_backup.id
}

resource "oci_identity_user_capabilities_management" "longhorn_backup" {
  user_id = oci_identity_user.longhorn_backup.id

  can_use_customer_secret_keys = "true"
}

resource "oci_identity_policy" "longhorn_backup" {
  compartment_id = var.compartment_id
  description    = "allow Longhorn backups to its bucket"
  name           = "LonghornBackup"
  statements = [
    "Allow group 'Default'/'LonghornBackup' to read buckets in tenancy where target.bucket.name = '${var.bucket_name}'",
    "Allow group 'Default'/'LonghornBackup' to manage objects in tenancy where target.bucket.name = '${var.bucket_name}'"
  ]
}

resource "oci_identity_customer_secret_key" "longhorn_backup" {
  display_name = "longhorn-backup"
  user_id      = oci_identity_user.longhorn_backup.id
}

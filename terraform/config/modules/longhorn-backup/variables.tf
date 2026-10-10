variable "compartment_id" {
  type        = string
  description = "The compartment to create the resources in"
}

variable "region" {
  description = "OCI region"
  type        = string
}

variable "bucket_name" {
  description = "Object Storage bucket used as the Longhorn backup target"
  type        = string

  default = "longhorn-backups"
}

variable "user_email" {
  description = "Email of the IAM user owning the S3-compatible key"
  type        = string

  default = "bogdanadrian.burciu@yahoo.com"
}

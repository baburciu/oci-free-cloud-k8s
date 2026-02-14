variable "compartment_id" {
  type        = string
  description = "The compartment to create the resources in"
}

variable "region" {
  description = "OCI region"
  type        = string

  default = "eu-frankfurt-1"
}

variable "ssh_public_key" {
  description = "SSH Public Key used to access all instances"
  type        = string

  default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPchScRWzoyDuYXI2DF2HRcUN/GWFbjhFPpWRX9wa9oM bogdanadrian.burciu@yahoo.com"
}

variable "kubernetes_version" {
  # https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengaboutk8sversions.htm
  description = "Version of Kubernetes"
  type        = string

  default = "v1.34.1"
}

variable "kubernetes_worker_nodes" {
  description = "Worker node count"
  type        = number

  default = 2
}

variable "budget_alert_amount" {
  # Amount is in the account's billing currency (see OCI Console > Billing & Cost Management > Payment Method)
  description = "Monthly budget amount (in account's billing currency) that triggers an alert when reached"
  type        = number

  default     = 1
}

variable "budget_alert_email" {
  description = "Email address to receive budget alert notifications"
  type        = string

  default = "bogdanadrian.burciu@yahoo.com"
}

module "externalsecrets" {
  source = "./modules/external-secrets"

  compartment_id = var.compartment_id
}

module "fluxcd" {
  source = "./modules/fluxcd"

  compartment_id             = var.compartment_id
  github_app_id              = var.github_app_id
  github_app_installation_id = var.github_app_installation_id
  github_app_pem             = var.github_app_pem
}

module "ingress" {
  source = "./modules/ingress"

  compartment_id = var.compartment_id
}

module "grafana" {
  source = "./modules/grafana"

  compartment_id = var.compartment_id
}

module "longhorn_backup" {
  source = "./modules/longhorn-backup"

  compartment_id = var.compartment_id
  region         = var.region
}

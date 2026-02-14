resource "oci_budget_budget" "monthly" {
  compartment_id         = var.compartment_id
  amount                 = var.budget_alert_amount
  reset_period           = "MONTHLY"
  processing_period_type = "MONTH"
  display_name           = "monthly-cost-budget"
  description            = "Monthly budget alert for OCI Free Cloud K8s infrastructure"
  target_type            = "COMPARTMENT"
  targets                = [var.compartment_id]
}

resource "oci_budget_alert_rule" "actual_spend" {
  budget_id      = oci_budget_budget.monthly.id
  display_name   = "actual-spend-alert"
  description    = "Alert when actual monthly spend reaches the budget threshold"
  type           = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_email
  message        = "OCI monthly spend has reached the configured budget threshold of ${var.budget_alert_amount}."
}

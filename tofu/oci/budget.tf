# Open item from the plan: $1 budget alert. 60 + 140 GB uses the whole
# 200 GB Always Free block storage, so any stray volume would start billing.
resource "oci_budget_budget" "guard" {
  compartment_id = var.tenancy_ocid
  display_name   = "vaultnet-1usd"
  amount         = 1
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]
}

resource "oci_budget_alert_rule" "any_spend" {
  budget_id      = oci_budget_budget.guard.id
  display_name   = "any-actual-spend"
  type           = "ACTUAL"
  threshold_type = "PERCENTAGE"
  threshold      = 1 # 1% of $1 = first cent
  recipients     = var.budget_alert_email
  message        = "OCI spend detected on the vaultnet tenancy."
}

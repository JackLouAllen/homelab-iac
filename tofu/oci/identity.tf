# Dedicated compartment so every vaultnet resource is grouped, tagged,
# and can get its own IAM policies later. Lives directly under the tenancy.
resource "oci_identity_compartment" "vaultnet" {
  compartment_id = var.tenancy_ocid
  name           = "vaultnet"
  description    = "vaultnet homelab: oci1 host, network, images"
  enable_delete  = false # tofu destroy only drops it from state; deleting is a manual step

  lifecycle {
    prevent_destroy = true
  }
}

# New compartments take a minute to propagate; creating resources in one
# immediately can fail with "compartment not found".
resource "time_sleep" "compartment_propagation" {
  create_duration = "90s"
  triggers = {
    compartment_id = oci_identity_compartment.vaultnet.id
  }
}

# Everything else reads the ID through the sleep, so it waits for propagation.
locals {
  compartment_id = time_sleep.compartment_propagation.triggers["compartment_id"]
}

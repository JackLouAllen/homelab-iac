terraform {
  required_version = ">= 1.8"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.11"
    }
  }
}

# Auth comes from ~/.oci/config (API signing key). Nothing secret lives in this repo.
provider "oci" {
  region              = var.region
  config_file_profile = var.oci_profile
  private_key_path     = var.oci_private_key_path
  private_key_password = var.oci_private_key_password
}

variable "tenancy_ocid" {
  description = "Tenancy OCID (Object Storage namespace, availability domains, budget)."
  type        = string
}

variable "region" {
  description = "OCI home region, e.g. us-ashburn-1. Always Free A1 must run in the home region."
  type        = string
}

variable "oci_profile" {
  description = "Profile name in ~/.oci/config."
  type        = string
  default     = "DEFAULT"
}

variable "oci_private_key_path" {
  type = string
}

variable "oci_private_key_password" {
  type      = string
  sensitive = true
}

# --- Image ---

variable "image_path" {
  description = "Local path to the RHEL 10 aarch64 QCOW2 from Image Builder."
  type        = string
}

variable "image_version" {
  description = "Label for this image build (e.g. 2026-10-22). Bump it when importing a new build."
  type        = string
}

# --- Network ---

variable "vcn_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.10.1.0/24"
}

variable "ssh_source_cidrs" {
  description = "CIDRs allowed to reach TCP 22. Set to [] once Tailscale is up to close every inbound port."
  type        = list(string)

  validation {
    condition     = !contains(var.ssh_source_cidrs, "0.0.0.0/0")
    error_message = "Don't open SSH to the whole internet; use your own /32."
  }
}

# --- Instance ---

variable "hostname" {
  type    = string
  default = "oci1"
}

variable "ad_index" {
  description = "Availability domain index (0-based). Change it if A1 reports 'Out of host capacity'."
  type        = number
  default     = 0
}

variable "ocpus" {
  type    = number
  default = 4
}

variable "memory_gb" {
  type    = number
  default = 24
}

variable "boot_volume_gb" {
  type    = number
  default = 60
}

variable "data_volume_gb" {
  type    = number
  default = 140
}

# --- Budget ---

variable "budget_alert_email" {
  description = "Where the $1 budget alert goes."
  type        = string
}

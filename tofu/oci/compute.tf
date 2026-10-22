data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

locals {
  ad = data.oci_identity_availability_domains.ads.availability_domains[var.ad_index].name
}

resource "oci_core_instance" "oci1" {
  compartment_id      = local.compartment_id
  availability_domain = local.ad
  display_name        = var.hostname
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = oci_core_image.rhel10.id
    boot_volume_size_in_gbs = var.boot_volume_gb
    boot_volume_vpus_per_gb = 10 # Balanced; free tier
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true # needed for outbound without a NAT gateway; no ports open
    hostname_label   = var.hostname
    display_name     = "${var.hostname}-vnic"
  }

  # IMDSv2 only (blocks SSRF-style metadata theft).
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  metadata = {
    user_data = base64encode(file("${path.module}/cloud-init.yaml"))
  }

  preserve_boot_volume = false

  # Encrypt boot and paravirtualized volume traffic between host and storage.
  is_pv_encryption_in_transit_enabled = true

  depends_on = [
    oci_core_compute_image_capability_schema.rhel10,
    oci_core_shape_management.a1,
  ]

  lifecycle {
    # Importing a newer image or editing cloud-init must not silently rebuild the host.
    ignore_changes = [source_details[0].source_id, metadata]
  }
}

resource "oci_core_volume" "data" {
  compartment_id      = local.compartment_id
  availability_domain = local.ad
  display_name        = "${var.hostname}-data"
  size_in_gbs         = var.data_volume_gb
  vpus_per_gb         = 10

  lifecycle {
    prevent_destroy = true # holds GitLab, Wazuh, CouchDB data
  }
}

resource "oci_core_volume_attachment" "data" {
  attachment_type = "paravirtualized" # shows up as a plain virtio disk; no iSCSI setup
  instance_id     = oci_core_instance.oci1.id
  volume_id       = oci_core_volume.data.id
  display_name    = "${var.hostname}-data-attach"
  is_read_only    = false
}

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "images" {
  compartment_id = local.compartment_id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "vaultnet-images"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
}

# Uploads the QCOW2 from your machine. Large files go up as multipart automatically.
resource "oci_objectstorage_object" "rhel10" {
  namespace    = data.oci_objectstorage_namespace.ns.namespace
  bucket       = oci_objectstorage_bucket.images.name
  object       = "rhel-10-aarch64-${var.image_version}.qcow2"
  source       = var.image_path
  content_type = "application/octet-stream"
}

resource "oci_core_image" "rhel10" {
  compartment_id = local.compartment_id
  display_name   = "rhel-10-aarch64-${var.image_version}"
  launch_mode    = "PARAVIRTUALIZED" # virtio disk and NIC

  image_source_details {
    source_type              = "objectStorageTuple"
    namespace_name           = data.oci_objectstorage_namespace.ns.namespace
    bucket_name              = oci_objectstorage_bucket.images.name
    object_name              = oci_objectstorage_object.rhel10.object
    source_image_type        = "QCOW2"
    operating_system         = "RHEL"
    operating_system_version = "10"
  }

  timeouts {
    create = "60m"
  }
}

# ARM instances boot UEFI only; imported images need this declared explicitly.
data "oci_core_compute_global_image_capability_schemas" "global" {}

resource "oci_core_compute_image_capability_schema" "rhel10" {
  compartment_id = local.compartment_id
  image_id       = oci_core_image.rhel10.id
  display_name   = "rhel-10-aarch64-${var.image_version}-caps"

  compute_global_image_capability_schema_version_name = (
    data.oci_core_compute_global_image_capability_schemas.global
    .compute_global_image_capability_schemas[0].current_version_name
  )

  schema_data = {
    "Compute.Firmware" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "UEFI_64"
      values         = ["UEFI_64"]
    })
  }
}

resource "oci_core_shape_management" "a1" {
  compartment_id = local.compartment_id
  image_id       = oci_core_image.rhel10.id
  shape_name     = "VM.Standard.A1.Flex"
}

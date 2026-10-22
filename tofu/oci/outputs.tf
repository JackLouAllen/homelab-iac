output "public_ip" {
  value = oci_core_instance.oci1.public_ip
}

output "instance_id" {
  value = oci_core_instance.oci1.id
}

output "image_id" {
  value = oci_core_image.rhel10.id
}

output "data_volume_id" {
  value = oci_core_volume.data.id
}

output "compartment_id" {
  value = oci_identity_compartment.vaultnet.id
}

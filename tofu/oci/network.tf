resource "oci_core_vcn" "main" {
  compartment_id = local.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "vaultnet-vcn"
  dns_label      = "vaultnet"
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "vaultnet-igw"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "vaultnet-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

# Strip the VCN's default security list (it allows SSH from 0.0.0.0/0).
# Nothing uses it, but an empty list can't be attached by accident.
resource "oci_core_default_security_list" "default" {
  manage_default_resource_id = oci_core_vcn.main.default_security_list_id
  display_name               = "vaultnet-default-empty"
}

resource "oci_core_security_list" "ssh_only" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "vaultnet-ssh-only"

  # Outbound: package repos, Red Hat registration, Tailscale, Cloudflare Tunnel.
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # Inbound SSH from your own IPs only. Empty list = no inbound TCP at all.
  dynamic "ingress_security_rules" {
    for_each = var.ssh_source_cidrs
    content {
      description = "SSH"
      protocol    = "6"
      source      = ingress_security_rules.value
      stateless   = false
      tcp_options {
        min = 22
        max = 22
      }
    }
  }

  # ICMP "fragmentation needed" so path MTU discovery works. Not a listening port.
  ingress_security_rules {
    description = "Path MTU discovery"
    protocol    = "1"
    source      = "0.0.0.0/0"
    stateless   = false
    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    description = "ICMP unreachable within VCN"
    protocol    = "1"
    source      = var.vcn_cidr
    stateless   = false
    icmp_options {
      type = 3
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = local.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.subnet_cidr
  display_name               = "vaultnet-public"
  dns_label                  = "pub"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.ssh_only.id]
  prohibit_public_ip_on_vnic = false
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns both zones and the tunnel."
  type        = string
}

variable "public_zone" {
  description = "Zone for everything reachable from the internet, through the tunnel."
  type        = string
  default     = "jacklouallen.info"
}

variable "private_zone" {
  description = "Zone for tailnet-only names. Its records point at Tailscale addresses."
  type        = string
  default     = "vaultnet.xyz"
}

variable "tunnel_name" {
  type    = string
  default = "oci1"
}

variable "public_hostnames" {
  description = "Subdomains of the public zone served by this tunnel."
  type        = list(string)
  default     = ["git", "auth"]

  validation {
    condition     = alltrue([for h in var.public_hostnames : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", h))])
    error_message = "Hostnames must be lowercase letters, digits and hyphens."
  }
}

variable "origin_service" {
  description = "Where cloudflared sends public traffic: nginx's loopback listener (edge_public_port)."
  type        = string
  default     = "http://127.0.0.1:8008"
}

variable "tailnet_ip" {
  description = "oci1's Tailscale IPv4 address (tailscale ip -4). The wildcard private record points here."
  type        = string

  validation {
    condition     = can(regex("^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9]+\\.[0-9]+$", var.tailnet_ip))
    error_message = "Expected an address in the Tailscale range 100.64.0.0/10."
  }
}

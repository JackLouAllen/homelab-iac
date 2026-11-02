data "cloudflare_zero_trust_tunnel_cloudflared_token" "oci1" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.oci1.id
}

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.oci1.id
}

# Read with: tofu output -raw tunnel_token (goes into a SOPS file, never into Git)
output "tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.oci1.token
  sensitive = true
}

output "public_urls" {
  value = [for h in var.public_hostnames : "https://${h}.${var.public_zone}"]
}

output "ovh1_tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.ovh1.id
}

# Read with: tofu output -raw ovh1_tunnel_token (goes into a SOPS file, never into Git)
output "ovh1_tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.ovh1.token
  sensitive = true
}

output "ovh1_public_urls" {
  value = [for fqdn in values(local.ovh1_public_fqdns) : "https://${fqdn}"]
}

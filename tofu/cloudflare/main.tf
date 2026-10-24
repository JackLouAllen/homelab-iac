data "cloudflare_zone" "public" {
  filter = {
    name    = var.public_zone
    account = { id = var.cloudflare_account_id }
  }
}

data "cloudflare_zone" "private" {
  filter = {
    name    = var.private_zone
    account = { id = var.cloudflare_account_id }
  }
}

# --- Tunnel: the only public path into oci1; no inbound ports are open ---

# random_password keeps the value out of plan output; random_id would print it as its ID.
resource "random_password" "tunnel_secret" {
  length  = 32
  special = false
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "oci1" {
  account_id    = var.cloudflare_account_id
  name          = var.tunnel_name
  config_src    = "cloudflare"
  tunnel_secret = base64encode(random_password.tunnel_secret.result)
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "oci1" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.oci1.id

  config = {
    ingress = concat(
      [for h in var.public_hostnames : {
        hostname = "${h}.${var.public_zone}"
        service  = var.origin_service
      }],
      [{ service = "http_status:404" }],
    )
  }
}

resource "cloudflare_dns_record" "public" {
  for_each = toset(var.public_hostnames)

  zone_id = data.cloudflare_zone.public.id
  name    = "${each.key}.${var.public_zone}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.oci1.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # automatic; required for proxied records
}

# --- Private names: resolve to a Tailscale address that only tailnet devices can reach ---

resource "cloudflare_dns_record" "private_wildcard" {
  zone_id = data.cloudflare_zone.private.id
  name    = "*.${var.private_zone}"
  type    = "A"
  content = var.tailnet_ip
  proxied = false
  ttl     = 300
  comment = "Tailnet only; 100.64.0.0/10 is not routable on the internet"
}

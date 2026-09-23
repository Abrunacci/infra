# DNS lives in Cloudflare (the domain is registered with Cloudflare Registrar).
# Records are DNS only (proxied = false): traffic goes straight to the Droplet
# and Caddy obtains and renews certificates itself.

resource "cloudflare_dns_record" "a" {
  for_each = local.hostnames

  zone_id = var.cloudflare_zone_id
  name    = "${each.key}.${var.domain}"
  type    = "A"
  content = digitalocean_droplet.server.ipv4_address
  ttl     = 300
  proxied = false
  comment = "Managed by Terraform (infra repo)"
}

resource "cloudflare_dns_record" "aaaa" {
  for_each = local.hostnames

  zone_id = var.cloudflare_zone_id
  name    = "${each.key}.${var.domain}"
  type    = "AAAA"
  content = digitalocean_droplet.server.ipv6_address
  ttl     = 300
  proxied = false
  comment = "Managed by Terraform (infra repo)"
}

# CAA: only the two CAs Caddy uses may issue certificates for the domain,
# and no one may issue wildcards.
locals {
  caa_records = {
    letsencrypt = { tag = "issue", value = "letsencrypt.org" }
    zerossl     = { tag = "issue", value = "sectigo.com" } # ZeroSSL issues through Sectigo
    nowildcard  = { tag = "issuewild", value = ";" }
  }
}

resource "cloudflare_dns_record" "caa" {
  for_each = local.caa_records

  zone_id = var.cloudflare_zone_id
  name    = var.domain
  type    = "CAA"
  ttl     = 3600
  comment = "Managed by Terraform (infra repo)"

  data = {
    flags = 0
    tag   = each.value.tag
    value = each.value.value
  }
}

# DNS lives in Cloudflare (the domain is registered with Cloudflare Registrar).
# Records are DNS only (proxied = false): traffic goes straight to the Droplet
# and Caddy obtains and renews certificates itself.

resource "cloudflare_dns_record" "a" {
  for_each = local.hostnames

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "A"
  content = digitalocean_droplet.server.ipv4_address
  ttl     = 300
  proxied = false
  comment = "Managed by Terraform (infra repo)"

  lifecycle {
    # projects.yml is hand-edited: fail the plan instead of silently merging or
    # dropping records.
    precondition {
      # An empty list is far more often a mistake (a bad merge, a stray
      # `projects: []`) than a decision, and it would delete every project's records.
      condition     = length(local.subdomains) > 0 || var.allow_zero_projects
      error_message = "projects.yml has no projects. To remove every project on purpose, set it for that run only: terraform plan -var=allow_zero_projects=true (never in .env)."
    }
    precondition {
      # YAML turns unquoted true, yes or 0123 into a bool or a number, which
      # Terraform would then silently convert into "true" or "123".
      condition     = alltrue([for s in local.subdomains : startswith(jsonencode(s), "\"")])
      error_message = "projects.yml: every subdomain must be a string (quote values such as \"yes\" or \"0123\")."
    }
    precondition {
      condition     = alltrue([for s in local.subdomains : s == "@" || can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", s))])
      error_message = "projects.yml: every subdomain must be a lowercase DNS label (a-z, 0-9, hyphens), or \"@\" for the root domain."
    }
    precondition {
      condition     = length(distinct(local.subdomains)) == length(local.subdomains)
      error_message = "projects.yml: two projects use the same subdomain."
    }
    precondition {
      condition     = length(setintersection(toset(local.subdomains), toset(local.reserved))) == 0
      error_message = "projects.yml: 'server', 'status' and 'www' are reserved subdomains."
    }
  }
}

resource "cloudflare_dns_record" "aaaa" {
  for_each = local.hostnames

  zone_id = var.cloudflare_zone_id
  name    = each.value
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

# Nothing is proxied, so Cloudflare's edge certificates are never used. With
# Universal SSL on, Cloudflare also publishes hidden CAA records for its own CAs
# (including issuewild), which would defeat the records above.
# Removing this block does NOT turn Universal SSL back on: the provider only
# drops it from the state. To revert, set enabled = true.
resource "cloudflare_universal_ssl_setting" "this" {
  zone_id = var.cloudflare_zone_id
  enabled = false
}

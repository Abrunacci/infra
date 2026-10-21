# DNS lives in Cloudflare: one zone per domain in projects.yml (domains), its
# ID in TF_VAR_cloudflare_zone_ids. Records are DNS only (proxied = false):
# traffic goes straight to the Droplet and Caddy obtains and renews
# certificates itself.

resource "cloudflare_dns_record" "a" {
  for_each = local.hostnames

  # lookup(): a project whose domain is not in domains gets "" here, and the
  # precondition below says so.
  zone_id = lookup(local.zone_ids, each.value.zone, "")
  name    = each.value.name
  type    = "A"
  # lookup(): a server with no Droplet gets "" here, and the precondition
  # below says so.
  content = lookup(local.server_ipv4, each.value.server, "")
  ttl     = 300
  proxied = false
  comment = "Managed by Terraform (infra repo)"

  lifecycle {
    # projects.yml is hand-edited: fail the plan instead of silently merging or
    # dropping records.
    precondition {
      condition     = alltrue([for d in local.domains : can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", d))])
      error_message = "projects.yml: every domain must be a lowercase domain, such as example.com.ar."
    }
    precondition {
      condition     = length(distinct(local.domains)) == length(local.domains)
      error_message = "projects.yml: a domain is listed twice."
    }
    precondition {
      # One zone per domain: a domain under another one would put its records
      # in two zones.
      condition     = !anytrue([for a in local.domains : anytrue([for b in local.domains : endswith(a, ".${b}")])])
      error_message = "projects.yml: a domain is a subdomain of another one in domains."
    }
    precondition {
      condition     = alltrue([for p in local.public_projects : contains(local.domains, p.domain)])
      error_message = "projects.yml: a project's domain is not in domains."
    }
    precondition {
      condition     = length(distinct(local.servers)) == length(local.servers)
      error_message = "projects.yml: a server is listed twice."
    }
    precondition {
      condition     = alltrue([for s in local.servers : local.server_zones[s] != ""])
      error_message = "projects.yml: every server must be a name under a domain in domains."
    }
    precondition {
      # Internal projects too: they have no record, but they run somewhere.
      condition     = alltrue([for p in local.projects : contains(local.servers, lookup(p, "server", local.primary_server))])
      error_message = "projects.yml: a project's server is not in servers."
    }
    precondition {
      condition     = alltrue([for s in local.servers : contains(keys(local.server_ipv4), s)])
      error_message = "projects.yml lists a server with no Droplet in Terraform: ${join(", ", [for s in local.servers : s if !contains(keys(local.server_ipv4), s)])}. Add its Droplet (main.tf) first."
    }
    precondition {
      condition     = alltrue([for h in local.redirect_hosts : h.zone != ""])
      error_message = "projects.yml: every redirect_from must be a domain in domains or a name under one."
    }
    precondition {
      condition     = alltrue([for d in local.domains : local.zone_ids[d] != ""])
      error_message = "TF_VAR_cloudflare_zone_ids has no zone ID for ${join(", ", [for d in local.domains : d if local.zone_ids[d] == ""])}: add it in .env (see \"Credentials\" in the README)."
    }
    precondition {
      # An empty list is far more often a mistake (a bad merge, a stray
      # `projects: []`) than a decision, and it would delete every project's records.
      # Internal projects (no subdomain) do not count: they have no record.
      condition     = length(local.subdomains) > 0 || var.allow_zero_projects
      error_message = "projects.yml has no project with a subdomain. To remove every project on purpose, set it for that run only: terraform plan -var=allow_zero_projects=true (never in .env)."
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
      condition     = length(distinct([for h in local.hostname_list : h.name])) == length(local.hostname_list)
      error_message = "projects.yml: two projects use the same subdomain of the same domain."
    }
    precondition {
      condition     = length(setintersection(toset(local.subdomains), toset(local.reserved))) == 0
      error_message = "projects.yml: 'server', 'status' and 'www' are reserved subdomains."
    }
  }
}

resource "cloudflare_dns_record" "aaaa" {
  for_each = local.hostnames

  zone_id = lookup(local.zone_ids, each.value.zone, "")
  name    = each.value.name
  type    = "AAAA"
  content = lookup(local.server_ipv6, each.value.server, "")
  ttl     = 300
  proxied = false
  comment = "Managed by Terraform (infra repo)"
}

# CAA, on every domain: only the two CAs Caddy uses may issue certificates,
# and no one may issue wildcards.
locals {
  caa_records = {
    letsencrypt = { tag = "issue", value = "letsencrypt.org" }
    zerossl     = { tag = "issue", value = "sectigo.com" } # ZeroSSL issues through Sectigo
    nowildcard  = { tag = "issuewild", value = ";" }
  }
}

resource "cloudflare_dns_record" "caa" {
  # Keyed <domain>/<record>, such as abrunacci.dev/letsencrypt.
  for_each = {
    for pair in setproduct(local.domains, keys(local.caa_records)) :
    "${pair[0]}/${pair[1]}" => merge(local.caa_records[pair[1]], { domain = pair[0] })
  }

  zone_id = local.zone_ids[each.value.domain]
  name    = each.value.domain
  type    = "CAA"
  ttl     = 3600
  comment = "Managed by Terraform (infra repo)"

  data = {
    flags = 0
    tag   = each.value.tag
    value = each.value.value
  }
}

# Proves to Google Search Console that the domain is ours, so it shows how the
# landing appears in Google Search and lets us ask Google to index it. It sits next to the SPF record
# Email Routing writes on the root domain (see email.tf); each TXT record is
# separate, so neither replaces the other. Google checks it again from time to
# time: removing it unverifies the domain.
resource "cloudflare_dns_record" "google_site_verification" {
  zone_id = local.zone_ids[local.primary_domain]
  name    = local.primary_domain
  type    = "TXT"
  # Quoted, as Cloudflare stores TXT content (see the DMARC record in email.tf).
  content = "\"google-site-verification=9etRIHVIkfNP-vuYwCDkogM_Q8NmroSHfTFtHXrCtYI\""
  ttl     = 3600
  proxied = false
  comment = "Managed by Terraform (infra repo)"
}

# Nothing is proxied, so Cloudflare's edge certificates are never used. With
# Universal SSL on, Cloudflare also publishes hidden CAA records for its own CAs
# (including issuewild), which would defeat the records above.
# Removing this block does NOT turn Universal SSL back on: the provider only
# drops it from the state. To revert, set enabled = true.
resource "cloudflare_universal_ssl_setting" "this" {
  for_each = toset(local.domains)

  zone_id = local.zone_ids[each.key]
  enabled = false
}

# DNSSEC: Cloudflare signs each zone, so a resolver that validates (1.1.1.1,
# 8.8.8.8, most ISPs') rejects forged answers for the domain. For a domain
# registered with Cloudflare Registrar (abrunacci.dev), Cloudflare publishes
# the DS record in the parent zone by itself; for any other, the DS from
# terraform output dnssec_ds goes in by hand at the registrar. The status
# reads "pending" until it is there, then "active".
# Never removed by mistake: turning DNSSEC off while the DS record is still in
# .dev makes the whole domain fail to resolve on those resolvers, for as long
# as the DS stays cached (up to a day). To turn it off, do it in the
# dashboard (DNS → Settings → Disable DNSSEC), which removes the DS first, and
# only then drop this block (prevent_destroy first, then terraform state rm).
resource "cloudflare_zone_dnssec" "this" {
  for_each = toset(local.domains)

  zone_id = local.zone_ids[each.key]
  status  = "active"

  lifecycle {
    prevent_destroy = true
  }
}

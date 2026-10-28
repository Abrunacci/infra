# Mail for the domains, each one in one of three ways (projects.yml, domains):
#   mail_forward  Cloudflare Email Routing forwards the addresses listed to one
#                 inbox (var.email_forward_to)
#   proton        Proton Mail hosts the domain's mail: it receives, and sends
#                 from, the domain's addresses
#   neither       the domain receives no mail and sends none
# Resend also sends the projects' mail from mail.<domain> (records at the
# end).

locals {
  # The domains that receive mail, with the local parts each one forwards.
  mail_domains = { for d in local.registry.domains : d.name => d.mail_forward if lookup(d, "mail_forward", null) != null }
  # The domains whose mail is in Proton, with their settings.
  proton_domains = { for d in local.registry.domains : d.name => d.proton if lookup(d, "proton", null) != null }
  # The domains with no mail at all.
  no_mail_domains = [for d in local.domains : d if !contains(keys(local.mail_domains), d) && !contains(keys(local.proton_domains), d)]
  # Every forwarded address, such as hello@abrunacci.dev, with its domain.
  email_forwarded = merge([
    for domain, local_parts in local.mail_domains : { for l in local_parts : "${l}@${domain}" => domain }
  ]...)
}

# Turns Email Routing on, on each domain that receives mail. Cloudflare then
# writes the MX, SPF and DKIM records it needs on the domain and locks them:
# their values (MX priorities, the DKIM key) are Cloudflare's, so they are not
# declared here. Destroying this resource turns Email Routing off.
# No `name`: it turns Email Routing on for a subdomain of the zone, and the API
# rejects the domain itself there ("must be a subdomain"). Without it, the call
# applies to the domain itself.
resource "cloudflare_email_routing_dns" "this" {
  for_each = local.mail_domains

  zone_id = local.zone_ids[each.key]
}

# Cloudflare emails this address a verification link on creation. Until it is
# clicked the address is unverified, and no rule can forward to it.
resource "cloudflare_email_routing_address" "forward" {
  account_id = var.cloudflare_account_id
  email      = var.email_forward_to

  lifecycle {
    # Changing the inbox replaces the address. The new one is created first;
    # the rules' precondition stops them from moving to it until it is
    # verified, and the old one is destroyed only after they move. Mail keeps
    # reaching the old inbox meanwhile (see "Mail" in the README).
    create_before_destroy = true
  }
}

resource "cloudflare_email_routing_rule" "forward" {
  for_each = local.email_forwarded

  zone_id = local.zone_ids[each.value]
  name    = "${each.key} (Terraform, infra repo)"
  enabled = true

  matchers = [{
    type  = "literal"
    field = "to"
    value = each.key
  }]
  actions = [{
    type  = "forward"
    value = [cloudflare_email_routing_address.forward.email]
  }]

  lifecycle {
    precondition {
      condition     = cloudflare_email_routing_address.forward.verified != null
      error_message = "The destination address is not verified yet: click the link in Cloudflare's verification email, then plan and apply again."
    }
    precondition {
      # Forwarding to an address of a domain that forwards would loop.
      condition     = !anytrue([for d in keys(local.mail_domains) : endswith(lower(var.email_forward_to), "@${d}")])
      error_message = "email_forward_to must be an address outside the domains that receive mail (forwarding to one of them would loop)."
    }
  }
}

# Any other address is rejected while the message is being delivered, so the
# sender gets a bounce. Declared, disabled, so turning it on from the dashboard
# shows up in the next plan. Every zone has exactly one catch-all rule: creating
# this resource only sets it, and destroying it only drops it from the state,
# leaving the rule as it was last set.
resource "cloudflare_email_routing_catch_all" "this" {
  for_each = local.mail_domains

  zone_id = local.zone_ids[each.key]
  name    = "Catch-all (Terraform, infra repo): off"
  enabled = false

  matchers = [{ type = "all" }]
  actions  = [{ type = "drop" }]
}

# Only Resend (from mail.<domain> on the domains in local.resend_domains,
# through its DKIM signature, records below) and Proton (from its domains, through SPF and its DKIM signature)
# send mail. Any other message that claims to come from one of the domains or
# a subdomain is forged: receivers must reject it. The policy covers
# subdomains too, since there is no sp= tag. SPF on each domain that forwards
# comes from Email Routing (above) and does not cover senders such as Gmail's
# "Send mail as".
resource "cloudflare_dns_record" "dmarc" {
  for_each = toset(local.domains)

  zone_id = local.zone_ids[each.key]
  name    = "_dmarc.${each.key}"
  type    = "TXT"
  # Quoted, as Cloudflare stores TXT content; unquoted, every plan shows a diff.
  content = "\"v=DMARC1; p=reject\""
  ttl     = 3600
  proxied = false
  comment = "Managed by Terraform (infra repo)"
}

# Proton Mail: the records its "Domain names" page asks for. The MX and SPF
# values are the same for every Proton domain; the verification and DKIM
# values are the domain's own (projects.yml). Proton shows the DKIM values
# only once the domain is verified: until they are here, mail from the domain
# passes DMARC through SPF alone.
locals {
  proton_mx = merge([
    for d in keys(local.proton_domains) : {
      "${d}/mail"    = { domain = d, priority = 10, content = "mail.protonmail.ch" }
      "${d}/mailsec" = { domain = d, priority = 20, content = "mailsec.protonmail.ch" }
    }
  ]...)
}

resource "cloudflare_dns_record" "proton_mx" {
  # Keyed <domain>/<server>, such as epbstock.com.ar/mail.
  for_each = local.proton_mx

  zone_id  = local.zone_ids[each.value.domain]
  name     = each.value.domain
  type     = "MX"
  priority = each.value.priority
  content  = each.value.content
  ttl      = 3600
  proxied  = false
  comment  = "Managed by Terraform (infra repo)"

  lifecycle {
    precondition {
      # One set of MX records per domain.
      condition     = length(setintersection(keys(local.mail_domains), keys(local.proton_domains))) == 0
      error_message = "projects.yml: a domain has both mail_forward and proton; it can have only one."
    }
  }
}

resource "cloudflare_dns_record" "proton_txt" {
  # Keyed <domain>/<record>, such as epbstock.com.ar/spf.
  for_each = merge([
    for d, proton in local.proton_domains : {
      "${d}/verification" = { domain = d, content = "protonmail-verification=${proton.verification}" }
      "${d}/spf"          = { domain = d, content = "v=spf1 include:_spf.protonmail.ch ~all" }
    }
  ]...)

  zone_id = local.zone_ids[each.value.domain]
  name    = each.value.domain
  type    = "TXT"
  # Quoted, as Cloudflare stores TXT content (see the DMARC record above).
  content = "\"${each.value.content}\""
  ttl     = 3600
  proxied = false
  comment = "Managed by Terraform (infra repo)"
}

# Proton signs mail with three keys and rotates them on its side: each
# selector is a CNAME to Proton's key, so a rotation needs no change here.
resource "cloudflare_dns_record" "proton_dkim" {
  # Keyed <domain>/<selector>, such as epbstock.com.ar/protonmail2.
  for_each = merge([
    for d, proton in local.proton_domains : {
      for s in ["protonmail", "protonmail2", "protonmail3"] :
      "${d}/${s}" => { domain = d, selector = s, dkim = proton.dkim }
    } if lookup(proton, "dkim", null) != null
  ]...)

  zone_id = local.zone_ids[each.value.domain]
  name    = "${each.value.selector}._domainkey.${each.value.domain}"
  type    = "CNAME"
  content = "${each.value.selector}.domainkey.${each.value.dkim}.domains.proton.ch"
  ttl     = 3600
  proxied = false
  comment = "Managed by Terraform (infra repo)"
}

# A domain with no mail says so (RFC 7505 null MX, and SPF that allows no
# sender), so senders bounce at once and receivers reject forged mail even
# without checking DMARC.
resource "cloudflare_dns_record" "null_mx" {
  for_each = toset(local.no_mail_domains)

  zone_id  = local.zone_ids[each.key]
  name     = each.key
  type     = "MX"
  priority = 0
  content  = "."
  ttl      = 3600
  proxied  = false
  comment  = "Managed by Terraform (infra repo)"
}

resource "cloudflare_dns_record" "no_mail_spf" {
  for_each = toset(local.no_mail_domains)

  zone_id = local.zone_ids[each.key]
  name    = each.key
  type    = "TXT"
  content = "\"v=spf1 -all\""
  ttl     = 3600
  proxied = false
  comment = "Managed by Terraform (infra repo)"
}

# Resend sends the projects' mail from mail.<domain>, on each domain below,
# from the region where the domain was added in Resend. Three records each:
#   send.mail, rsend.mail  -> Resend's sending subdomains (bounces, SPF);
#                             rsend.mail points at the domain's region
#   resend._domainkey.mail -> DKIM public key; mail is signed for mail.<domain>,
#                             which aligns with the domain's DMARC policy
# Changing any of them breaks sending from that domain until Resend verifies it
# again.
#   abrunacci.dev    created on 2026-09-28 by Resend's Domain Connect flow
#                    (North Virginia) and adopted into Terraform with the
#                    import blocks below, so declared exactly as Resend wrote
#                    them: no comment, TTL 1 h, DNS only
#   epbstock.com.ar  EPB Stock's, added in Resend by hand (São Paulo) and
#                    created here, with the values Resend shows for the domain
locals {
  resend_domains = {
    "abrunacci.dev" = {
      rsend   = "rsend.forge.rmta.net"
      dkim    = "p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDL9T/C/Q5cYd/AlUpzKN75GuSHDXkdvosuw598BFIndbYII9nIZ8VBSLT/I8lsaLmyHkm8yd3bhvhj9R1J1Tae7qssXsRlughwdFxWU9ZsG3dV5IhVNqrb7uLYO/Vgw8+q5B7USU8Wo+huKPKJXmGXSar2C9irkNcwPkhne6lqRQIDAQAB"
      comment = null
    }
    "epbstock.com.ar" = {
      rsend   = "rsend-sae1.forge.rmta.net"
      dkim    = "p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC4plpT3/uny9DJ5wSag30ilBJfaAU0UXbPE3J7Vha1Fruu7SysjNYoTmW1KuGPzj9nyVUZ6ZTN1IQqYe1EOA+LxoAiJxJg6adVKrf1FSSUmsPdXMJTBUUdEuFJ0dhSyJTkL0j2TFe36DxAmvIFQ4sseGr6jp5BsuvFxMSKYVPLIQIDAQAB"
      comment = "Managed by Terraform (infra repo)"
    }
  }
  # Keyed <domain>/<record>, such as epbstock.com.ar/dkim.
  resend_records = merge([
    for d, r in local.resend_domains : {
      "${d}/send"  = { domain = d, name = "send.mail", type = "CNAME", content = "send.forge.rmta.net", comment = r.comment }
      "${d}/rsend" = { domain = d, name = "rsend.mail", type = "CNAME", content = r.rsend, comment = r.comment }
      # Quoted, as Cloudflare stores TXT content (see the DMARC record above).
      "${d}/dkim" = { domain = d, name = "resend._domainkey.mail", type = "TXT", content = "\"${r.dkim}\"", comment = r.comment }
    }
  ]...)
}

resource "cloudflare_dns_record" "resend" {
  for_each = local.resend_records

  zone_id = local.zone_ids[each.value.domain]
  name    = "${each.value.name}.${each.value.domain}"
  type    = each.value.type
  content = each.value.content
  ttl     = 3600
  proxied = false
  comment = each.value.comment
}

# Adopted abrunacci.dev's records instead of creating duplicates. Inert unless
# resend_record_ids is passed, which happened once, in the import run (see
# "Mail" in the README); afterwards the records are in the state.
import {
  for_each = var.resend_record_ids

  to = cloudflare_dns_record.resend["${local.primary_domain}/${each.key}"]
  id = "${local.zone_ids[local.primary_domain]}/${each.value}"
}

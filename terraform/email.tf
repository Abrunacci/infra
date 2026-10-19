# Mail for the domains: Cloudflare Email Routing forwards the addresses each
# domain lists in projects.yml (mail_forward) to one inbox
# (var.email_forward_to), and Resend sends the projects' mail from
# mail.<first domain> (records at the end). Nothing else sends from any domain.

locals {
  # The domains that receive mail, with the local parts each one forwards.
  mail_domains = { for d in local.registry.domains : d.name => d.mail_forward if lookup(d, "mail_forward", null) != null }
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

# Only Resend sends mail, from mail.<first domain>, and it passes DMARC
# through its DKIM signature (records below). Any other message that claims to
# come from one of the domains or a subdomain is forged: receivers must reject
# it. The policy covers subdomains too, since there is no sp= tag. SPF on each
# domain that receives mail comes from Email Routing (above) and does not
# cover senders such as Gmail's "Send mail as".
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

# Resend sends the projects' mail (EPB Stock's, for now) from
# mail.<first domain>.
# These records were created on 2026-09-28 by Resend's Domain Connect flow and
# adopted into Terraform with the import blocks below, so they are declared
# exactly as Resend wrote them: no comment, TTL 1 h, DNS only. Changing any of
# them breaks sending until Resend verifies the domain again.
#   send.mail, rsend.mail  -> Resend's sending subdomains (bounces, SPF)
#   resend._domainkey.mail -> DKIM public key; mail is signed for mail.<domain>,
#                             which aligns with the domain's DMARC policy
locals {
  resend_records = {
    send  = { name = "send.mail", type = "CNAME", content = "send.forge.rmta.net" }
    rsend = { name = "rsend.mail", type = "CNAME", content = "rsend.forge.rmta.net" }
    # Quoted, as Cloudflare stores TXT content (see the DMARC record above).
    dkim = {
      name    = "resend._domainkey.mail"
      type    = "TXT"
      content = "\"p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDL9T/C/Q5cYd/AlUpzKN75GuSHDXkdvosuw598BFIndbYII9nIZ8VBSLT/I8lsaLmyHkm8yd3bhvhj9R1J1Tae7qssXsRlughwdFxWU9ZsG3dV5IhVNqrb7uLYO/Vgw8+q5B7USU8Wo+huKPKJXmGXSar2C9irkNcwPkhne6lqRQIDAQAB\""
    }
  }
}

resource "cloudflare_dns_record" "resend" {
  for_each = local.resend_records

  zone_id = local.zone_ids[local.primary_domain]
  name    = "${each.value.name}.${local.primary_domain}"
  type    = each.value.type
  content = each.value.content
  ttl     = 3600
  proxied = false
}

# Adopts the existing records instead of creating duplicates. Inert unless
# resend_record_ids is passed, which happens once, in the import run (see
# "Mail" in the README); afterwards the records are in the state.
import {
  for_each = var.resend_record_ids

  to = cloudflare_dns_record.resend[each.key]
  id = "${local.zone_ids[local.primary_domain]}/${each.value}"
}

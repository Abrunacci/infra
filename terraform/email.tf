# Mail for the domain: Cloudflare Email Routing forwards a few addresses to one
# inbox (var.email_forward_to). Nothing is hosted here and nothing is sent from
# the domain.

locals {
  # Local parts forwarded to the inbox. hello is the public contact address;
  # postmaster and abuse are the addresses RFC 5321 and RFC 2142 expect.
  email_forwarded = toset(["hello", "postmaster", "abuse"])
}

# Turns Email Routing on. Cloudflare then writes the MX, SPF and DKIM records
# it needs on the root domain and locks them: their values (MX priorities, the
# DKIM key) are Cloudflare's, so they are not declared here. Destroying this
# resource turns Email Routing off.
resource "cloudflare_email_routing_dns" "this" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain
}

# Cloudflare emails this address a verification link on creation. Until it is
# clicked the address is unverified, and no rule can forward to it.
resource "cloudflare_email_routing_address" "forward" {
  account_id = var.cloudflare_account_id
  email      = var.email_forward_to
}

resource "cloudflare_email_routing_rule" "forward" {
  for_each = local.email_forwarded

  zone_id = var.cloudflare_zone_id
  name    = "${each.key}@${var.domain} (Terraform, infra repo)"
  enabled = true

  matchers = [{
    type  = "literal"
    field = "to"
    value = "${each.key}@${var.domain}"
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
  }
}

# Any other address is rejected while the message is being delivered, so the
# sender gets a bounce. Declared, disabled, so turning it on from the dashboard
# shows up in the next plan.
resource "cloudflare_email_routing_catch_all" "this" {
  zone_id = var.cloudflare_zone_id
  name    = "Catch-all (Terraform, infra repo): off"
  enabled = false

  matchers = [{ type = "all" }]
  actions  = [{ type = "drop" }]
}

# The domain sends no mail, so any message that claims to come from it is
# forged: receivers must reject it. SPF comes from Email Routing (above) and
# does not cover senders such as Gmail's "Send mail as".
resource "cloudflare_dns_record" "dmarc" {
  zone_id = var.cloudflare_zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  # Quoted, as Cloudflare stores TXT content; unquoted, every plan shows a diff.
  content = "\"v=DMARC1; p=reject\""
  ttl     = 3600
  proxied = false
  comment = "Managed by Terraform (infra repo)"
}

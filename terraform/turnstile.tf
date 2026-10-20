# Turnstile, Cloudflare's CAPTCHA alternative, on the landing's contact form
# (the abrunacci-dev backend in projects.yml). The page shows the widget with
# the site key, which is public; the backend checks each answer with the
# secret key, against challenges.cloudflare.com.
# Managed: Cloudflare decides, per visitor, whether a click is needed.
# Only the first domain itself: www just redirects there (site.caddy.j2).
# The secret key is in the Terraform state (R2, infra-tfstate), like every
# attribute of a resource: whoever can read the state can read it.
# Never removed or replaced by mistake: a new widget has new keys, and the form
# rejects every message until the server and projects.yml have both of them.
resource "cloudflare_turnstile_widget" "contact_form" {
  account_id = var.cloudflare_account_id
  name       = "${local.primary_domain} contact form"
  domains    = [local.primary_domain]
  mode       = "managed"

  lifecycle {
    prevent_destroy = true
  }
}

# The same for EPB Stock's landing (epb-landing in projects.yml): its own
# widget, so rotating or losing one pair of keys never touches the other form.
# Invisible: no box is ever shown; the page asks for a token when the form is
# sent. The landing's build takes the site key (EPB_Stock's repository variable
# LANDING_TURNSTILE_SITE_KEY); the secret key is for its backend.
resource "cloudflare_turnstile_widget" "epb_landing" {
  account_id = var.cloudflare_account_id
  name       = "epbstock.com.ar contact form"
  domains    = ["epbstock.com.ar"]
  mode       = "invisible"

  lifecycle {
    prevent_destroy = true
  }
}

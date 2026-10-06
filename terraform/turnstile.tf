# Turnstile, Cloudflare's CAPTCHA alternative, on the landing's contact form
# (the abrunacci-dev backend in projects.yml). The page shows the widget with
# the site key, which is public; the backend checks each answer with the
# secret key, against challenges.cloudflare.com.
# Managed: Cloudflare decides, per visitor, whether a click is needed.
# Only the root domain: www just redirects there (site.caddy.j2).
# The secret key is in the Terraform state (R2, infra-tfstate), like every
# attribute of a resource: whoever can read the state can read it.
# Never removed or replaced by mistake: a new widget has new keys, and the form
# rejects every message until the server and projects.yml have both of them.
resource "cloudflare_turnstile_widget" "contact_form" {
  account_id = var.cloudflare_account_id
  name       = "${var.domain} contact form"
  domains    = [var.domain]
  mode       = "managed"

  lifecycle {
    prevent_destroy = true
  }
}

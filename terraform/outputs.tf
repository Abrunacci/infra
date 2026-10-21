output "server_fqdn" {
  description = "Hostname to reach the first server over SSH and from Ansible."
  value       = local.primary_server
}

output "ipv4_address" {
  description = "Public IPv4 address of the Droplet."
  value       = digitalocean_droplet.server.ipv4_address
}

output "ipv6_address" {
  description = "Public IPv6 address of the Droplet."
  value       = digitalocean_droplet.server.ipv6_address
}

output "hostnames" {
  description = "Every hostname that points at a Droplet."
  value       = sort(keys(local.hostnames))
}

output "server_hostnames" {
  description = "The hostnames that point at each server, by server."
  value       = { for srv in distinct(local.servers) : srv => sort([for h in values(local.hostnames) : h.name if h.server == srv]) }
}

output "dnssec_ds" {
  description = "Each domain's DS record, which goes in its parent zone: Cloudflare Registrar publishes it by itself; other registrars, by hand (compare with dig DS)."
  value       = { for d, dnssec in cloudflare_zone_dnssec.this : d => dnssec.ds }
}

output "turnstile_site_key" {
  description = "Public site key of the contact form's Turnstile widget (TURNSTILE_SITE_KEY of abrunacci-dev in projects.yml)."
  value       = cloudflare_turnstile_widget.contact_form.sitekey
}

output "turnstile_secret_key" {
  description = "Secret key of the contact form's Turnstile widget. Set it on the server with sudo project-secret abrunacci-dev set TURNSTILE_SECRET_KEY; read it with terraform output -raw turnstile_secret_key."
  value       = cloudflare_turnstile_widget.contact_form.secret
  sensitive   = true
}

output "epb_landing_turnstile_site_key" {
  description = "Public site key of EPB Stock's landing Turnstile widget (EPB_Stock's repository variable LANDING_TURNSTILE_SITE_KEY)."
  value       = cloudflare_turnstile_widget.epb_landing.sitekey
}

output "epb_landing_turnstile_secret_key" {
  description = "Secret key of EPB Stock's landing Turnstile widget, for the landing's backend; read it with terraform output -raw epb_landing_turnstile_secret_key."
  value       = cloudflare_turnstile_widget.epb_landing.secret
  sensitive   = true
}

output "epb_landing_web_analytics_token" {
  description = "Site token of EPB Stock's landing in Cloudflare Web Analytics (EPB_Stock's repository variable LANDING_CF_BEACON_TOKEN). Public: every visitor's browser gets it."
  value       = cloudflare_web_analytics_site.epb_landing.site_token
}

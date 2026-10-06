output "server_fqdn" {
  description = "Hostname to reach the server over SSH and from Ansible."
  value       = "server.${var.domain}"
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
  description = "Every hostname that points at the Droplet."
  value       = sort(values(local.hostnames))
}

output "dnssec_ds" {
  description = "The DS record Cloudflare Registrar publishes in .dev for the domain (compare with dig DS)."
  value       = cloudflare_zone_dnssec.this.ds
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

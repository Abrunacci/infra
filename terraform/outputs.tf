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
  description = "Each signed domain's DS record, which goes in its parent zone: Cloudflare Registrar publishes it by itself; other registrars, by hand (compare with dig DS). Domains in dnssec_off (dns.tf) have none."
  value       = { for d, dnssec in cloudflare_zone_dnssec.this : d => dnssec.ds if !contains(local.dnssec_off, d) }
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

output "production_droplet" {
  description = "Name of EPB Stock's production Droplet, and of its device in Tailscale: reach it over SSH as <name>.<tailnet>.ts.net (MagicDNS), never by its public address."
  value       = digitalocean_droplet.production.name
}

output "production_db_host" {
  description = "Private hostname of the production PostgreSQL cluster, reachable only from the production Droplet, over the VPC."
  value       = digitalocean_database_cluster.production.private_host
}

output "production_db_port" {
  description = "Port of the production PostgreSQL cluster."
  value       = digitalocean_database_cluster.production.port
}

output "production_db_ca" {
  description = "CA certificate of the production PostgreSQL cluster, to connect with sslmode=verify-full. Not a secret."
  value       = data.digitalocean_database_ca.production.certificate
}

output "production_database" {
  description = "What Ansible needs of the production cluster (ansible/roles/projects, projects_managed_db): its private host, port, admin user and CA. No secret in it."
  value = {
    host = digitalocean_database_cluster.production.private_host
    port = digitalocean_database_cluster.production.port
    user = digitalocean_database_cluster.production.user
    ca   = data.digitalocean_database_ca.production.certificate
  }
}

output "production_db_password" {
  description = "Password of the production cluster's admin user. Only for sudo database-credentials on the production server: terraform output -raw production_db_password."
  value       = digitalocean_database_cluster.production.password
  sensitive   = true
}

output "production_db_pools" {
  description = "The PgBouncer pools of the production cluster, by project (none until a project with a database is on the production server)."
  value       = { for name, pool in digitalocean_database_connection_pool.production : name => { port = pool.port, mode = pool.mode, size = pool.size } }
}

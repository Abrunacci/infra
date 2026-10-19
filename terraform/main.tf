locals {
  # No try() here on purpose: a missing or broken projects.yml, or one without
  # top-level "domains" and "projects" keys, must stop the plan. Falling back to
  # an empty list would plan the deletion of every project's DNS records.
  registry = yamldecode(file("${path.module}/../projects.yml"))
  projects = local.registry.projects

  # Every domain, each a Cloudflare zone. The first one is the server's own:
  # server and status live there, and so does every project without a domain.
  domains        = [for d in local.registry.domains : d.name]
  primary_domain = local.domains[0]
  # Each domain's zone ID (TF_VAR_cloudflare_zone_ids), or "" when it is
  # missing: the preconditions in dns.tf then say which one.
  zone_ids = { for d in local.domains : d => lookup(var.cloudflare_zone_ids, d, "") }

  # Public projects (the ones with a subdomain), each with its domain.
  # Internal projects have no subdomain, and no DNS record.
  public_projects = [
    for p in local.projects : merge(p, { domain = lookup(p, "domain", local.primary_domain) })
    if lookup(p, "subdomain", null) != null
  ]
  subdomains = [for p in local.public_projects : p.subdomain]
  reserved   = ["server", "status", "www"]

  # Every hostname that points at the Droplet, with the domain whose zone
  # holds its records:
  #   server.<first domain> -> SSH/Ansible target, so no IP address is ever
  #                            written in the repo
  #   status.<first domain> -> Gatus status page
  #   one per public project: its subdomain under its domain, or the domain
  #   itself for "@"; plus www.<domain> when a project with a site is on the
  #   domain itself (its redirect lives in that site's Caddy file)
  hostname_list = concat(
    [for h in ["server", "status"] : { name = "${h}.${local.primary_domain}", zone = local.primary_domain }],
    [
      for p in local.public_projects :
      { name = p.subdomain == "@" ? p.domain : "${p.subdomain}.${p.domain}", zone = p.domain }
    ],
    [for p in local.public_projects : { name = "www.${p.domain}", zone = p.domain } if p.subdomain == "@" && p.site],
  )
  # distinct(): a repeated hostname must reach the preconditions in dns.tf,
  # which say what is wrong, instead of failing here as a duplicate key.
  hostnames = { for h in distinct(local.hostname_list) : h.name => h }

  tags = ["infra", "portfolio"]
}

resource "digitalocean_tag" "this" {
  for_each = toset(local.tags)
  name     = each.value
}

resource "digitalocean_ssh_key" "admin" {
  name       = "${var.droplet_name}-admin"
  public_key = var.admin_ssh_public_key
}

resource "digitalocean_droplet" "server" {
  name       = var.droplet_name
  image      = var.droplet_image
  region     = var.region
  size       = var.droplet_size
  ipv6       = true
  monitoring = true
  # Off on purpose, and reverted if enabled from the panel: see "No DigitalOcean
  # Droplet backups" in the README.
  backups = false

  # Resizing powers the Droplet off: shut down cleanly (PostgreSQL runs on it) and
  # resize only CPU/RAM, so the change can be reverted to a smaller size later.
  graceful_shutdown = true
  resize_disk       = false
  ssh_keys          = [digitalocean_ssh_key.admin.id]
  tags              = [for t in digitalocean_tag.this : t.id]

  # Minimal cloud-init: creates the admin user and locks down SSH.
  # Everything else is provisioned (and re-provisioned) by Ansible.
  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    admin_user           = var.admin_user
    admin_ssh_public_key = trimspace(var.admin_ssh_public_key)
  })

  lifecycle {
    # The Droplet holds the shared PostgreSQL data: never destroy it by accident.
    # To rebuild on purpose, remove this flag in a reviewed PR and restore the
    # PostgreSQL backups from R2.
    prevent_destroy = true

    # These attributes only matter at creation and changing them would force a
    # replacement. After the first boot, Ansible owns the server's configuration.
    ignore_changes = [user_data, ssh_keys, image]
  }
}

resource "digitalocean_project" "portfolio" {
  name        = "portfolio"
  description = "Portfolio projects infrastructure, managed by Terraform."
  purpose     = "Web Application"
  environment = "Production"
  resources   = [digitalocean_droplet.server.urn]
}

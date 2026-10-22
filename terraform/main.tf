locals {
  # No try() here on purpose: a missing or broken projects.yml, or one without
  # top-level "domains" and "projects" keys, must stop the plan. Falling back to
  # an empty list would plan the deletion of every project's DNS records.
  registry = yamldecode(file("${path.module}/../projects.yml"))
  projects = local.registry.projects

  # Every domain, each a Cloudflare zone. The first one holds the status page,
  # and every project without a domain.
  domains        = [for d in local.registry.domains : d.name]
  primary_domain = local.domains[0]

  # Every server, by its hostname. The first one serves the status page and
  # runs every project without a server.
  servers        = [for s in local.registry.servers : s.name]
  primary_server = local.servers[0]
  # The zone each server's records go in ("" when it is under none of the
  # domains: the precondition in dns.tf says so). distinct(): a repeated
  # server must reach the precondition, not fail here as a duplicate key.
  server_zones = {
    for s in distinct(local.servers) : s => concat([for d in local.domains : d if endswith(s, ".${d}")], [""])[0]
  }
  # Each server's Droplet, by hostname. A server in projects.yml with no
  # Droplet here gets "" and the precondition in dns.tf says so.
  server_ipv4 = {
    (local.primary_server)    = digitalocean_droplet.server.ipv4_address
    (local.production_server) = digitalocean_droplet.production.ipv4_address
  }
  server_ipv6 = {
    (local.primary_server)    = digitalocean_droplet.server.ipv6_address
    (local.production_server) = digitalocean_droplet.production.ipv6_address
  }
  # Each domain's zone ID (TF_VAR_cloudflare_zone_ids), or "" when it is
  # missing: the preconditions in dns.tf then say which one.
  zone_ids = { for d in local.domains : d => lookup(var.cloudflare_zone_ids, d, "") }

  # Public projects (the ones with a subdomain), each with its domain and its
  # server. Internal projects have no subdomain, and no DNS record.
  public_projects = [
    for p in local.projects : merge(p, {
      domain = lookup(p, "domain", local.primary_domain)
      server = lookup(p, "server", local.primary_server)
    })
    if lookup(p, "subdomain", null) != null
  ]
  subdomains = [for p in local.public_projects : p.subdomain]
  reserved   = ["server", "status", "www"]

  # Each project's redirect_from, in the zone of the domain it is, or is
  # under ("" when none is: the precondition in dns.tf says so), on the
  # project's server, whose Caddy answers it.
  redirect_hosts = flatten([
    for p in local.public_projects : [
      for r in lookup(p, "redirect_from", []) : {
        name   = r
        zone   = concat([for d in local.domains : d if r == d || endswith(r, ".${d}")], [""])[0]
        server = p.server
      }
    ]
  ])

  # Each project's also_serves: other names that serve the same site, in the
  # zone of the domain they are, or are under ("" when none is: the
  # precondition in dns.tf says so), on the project's server.
  also_served_hosts = flatten([
    for p in local.public_projects : [
      for a in lookup(p, "also_serves", []) : {
        name   = a.name
        zone   = concat([for d in local.domains : d if a.name == d || endswith(a.name, ".${d}")], [""])[0]
        server = p.server
      }
    ]
  ])

  # Every hostname that points at a Droplet, with the domain whose zone holds
  # its records and the server it points at:
  #   each server's own name -> SSH/Ansible target, so no IP address is ever
  #                             written in the repo
  #   status.<first domain>  -> Gatus status page, on the first server
  #   one per public project: its subdomain under its domain, or the domain
  #   itself for "@"; plus www.<domain> when a project with a site is on the
  #   domain itself, and each of its redirect_from (their redirects live in
  #   that site's Caddy file), and each of its also_serves (served by the
  #   same site); all on the project's server
  hostname_list = concat(
    [for s in local.servers : { name = s, zone = local.server_zones[s], server = s }],
    [{ name = "status.${local.primary_domain}", zone = local.primary_domain, server = local.primary_server }],
    [
      for p in local.public_projects :
      { name = p.subdomain == "@" ? p.domain : "${p.subdomain}.${p.domain}", zone = p.domain, server = p.server }
    ],
    [
      for p in local.public_projects : { name = "www.${p.domain}", zone = p.domain, server = p.server }
      if p.subdomain == "@" && p.site
    ],
    local.redirect_hosts,
    local.also_served_hosts,
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
    tailscale_auth_key   = ""
    tailscale_hostname   = ""
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
  resources = [
    digitalocean_droplet.server.urn,
    digitalocean_droplet.production.urn,
    digitalocean_database_cluster.production.urn,
  ]
}

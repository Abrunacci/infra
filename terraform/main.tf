locals {
  # No try() here on purpose: a missing or broken projects.yml, or one without a
  # top-level "projects" key, must stop the plan. Falling back to an empty list
  # would plan the deletion of every project's DNS records.
  projects   = yamldecode(file("${path.module}/../projects.yml")).projects
  subdomains = [for p in local.projects : p.subdomain]
  reserved   = ["server", "status", "www"]
  # "@" is the root domain. www exists only when a site is served there: its
  # redirect lives in that site's Caddy file.
  has_root_site = contains([for p in local.projects : p.subdomain if p.site], "@")

  # Every hostname that points at the Droplet, keyed by its label ("@" for the
  # root domain):
  #   server -> SSH/Ansible target, so no IP address is ever written in the repo
  #   status -> Gatus status page
  #   one per project subdomain, and www when a project is on the root domain
  # distinct(): a repeated or reserved subdomain must reach the preconditions
  # in dns.tf, which say what is wrong, instead of failing here as a duplicate key.
  hostnames = {
    for h in distinct(concat(["server", "status"], local.subdomains, local.has_root_site ? ["www"] : [])) :
    h => h == "@" ? var.domain : "${h}.${var.domain}"
  }

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

locals {
  projects = yamldecode(file("${path.module}/../projects.yml")).projects

  # Every hostname that points at the Droplet:
  #   server -> SSH/Ansible target, so no IP address is ever written in the repo
  #   status -> Gatus status page
  #   one per project subdomain
  hostnames = toset(concat(["server", "status"], [for p in local.projects : p.subdomain]))

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
  ssh_keys   = [digitalocean_ssh_key.admin.id]
  tags       = [for t in digitalocean_tag.this : t.id]

  # Minimal cloud-init: creates the admin user and locks down SSH.
  # Everything else is provisioned (and re-provisioned) by Ansible.
  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    admin_user           = var.admin_user
    admin_ssh_public_key = trimspace(var.admin_ssh_public_key)
  })

  lifecycle {
    # The Droplet holds the shared PostgreSQL data: never destroy it by accident.
    # To rebuild on purpose, remove this flag in a reviewed PR and restore from backup.
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

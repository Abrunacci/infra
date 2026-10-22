# EPB Stock's production: a Droplet of its own and a managed PostgreSQL
# cluster, in a VPC of their own, in the same region as the first server.
#
#   - The Droplet answers HTTP(S) to anyone and SSH to no one: its port 22 is
#     reached only through Tailscale (tailscale.tf). It joins the tailnet on
#     its first boot, with a one-use key (cloud-init), so 22 is never open.
#   - The cluster is reached only from that Droplet, over the VPC: its
#     firewall lists the Droplet and nothing else. The first server is in
#     another VPC and outside that firewall: demo never reaches this database.
#   - The Droplet holds no data of its own (the database is the cluster's,
#     backed up by DigitalOcean and by the nightly dumps), so it has no
#     Droplet backups either.
#
# The Droplet goes into projects.yml's servers, and gets its A/AAAA records,
# once Ansible can provision it (server_ipv4 in main.tf already maps it).

locals {
  production_server  = "server.epbstock.com.ar"
  production_droplet = "epb-prod-01"
}

resource "digitalocean_vpc" "production" {
  name        = "epb-production"
  region      = var.region
  description = "EPB Stock production: its Droplet and its database cluster (Terraform, infra repo)."
}

resource "digitalocean_droplet" "production" {
  name       = local.production_droplet
  image      = var.droplet_image
  region     = var.region
  size       = var.production_droplet_size
  vpc_uuid   = digitalocean_vpc.production.id
  ipv6       = true
  monitoring = true
  backups    = false

  graceful_shutdown = true
  resize_disk       = false
  ssh_keys          = [digitalocean_ssh_key.admin.id]
  tags              = [for t in digitalocean_tag.this : t.id]

  # The same minimal cloud-init as the first server's, plus Tailscale: it
  # installs it and joins the tailnet as tag:prod with a one-use key that
  # expires an hour after this apply (tailscale.tf).
  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    admin_user           = var.admin_user
    admin_ssh_public_key = trimspace(var.admin_ssh_public_key)
    tailscale_auth_key   = tailscale_tailnet_key.production.key
    tailscale_hostname   = local.production_droplet
  })

  lifecycle {
    # Not for its data (it has none of its own) but for what points at it:
    # its addresses in DNS, its node in the tailnet, the cluster's firewall.
    prevent_destroy = true
    ignore_changes  = [user_data, ssh_keys, image]
  }
}

# Like the first server's (firewall.tf), without SSH. UDP 41641 is
# Tailscale's: open, it lets peers connect directly instead of through
# Tailscale's relays. Only Tailscale (WireGuard) answers on it.
resource "digitalocean_firewall" "production" {
  name        = "${local.production_droplet}-fw"
  droplet_ids = [digitalocean_droplet.production.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = local.anywhere
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = local.anywhere
  }

  inbound_rule {
    protocol         = "udp"
    port_range       = "443"
    source_addresses = local.anywhere
  }

  inbound_rule {
    protocol         = "udp"
    port_range       = "41641"
    source_addresses = local.anywhere
  }

  inbound_rule {
    protocol         = "icmp"
    source_addresses = local.anywhere
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = local.anywhere
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = local.anywhere
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = local.anywhere
  }
}

resource "digitalocean_database_cluster" "production" {
  name                 = "epb-production-db"
  engine               = "pg"
  version              = "17"
  size                 = var.production_db_size
  region               = var.region
  node_count           = 1
  private_network_uuid = digitalocean_vpc.production.id
  tags                 = local.tags

  # Minor updates and patches, on Sunday at 07:00 UTC (04:00 in Argentina).
  maintenance_window {
    day  = "sunday"
    hour = "07:00:00"
  }

  lifecycle {
    # Destroying it destroys the database and DigitalOcean's backups of it.
    # Removing it on purpose means a reviewed PR that drops this flag.
    prevent_destroy = true
  }
}

# Only the production Droplet: not the first server, not the internet.
resource "digitalocean_database_firewall" "production" {
  cluster_id = digitalocean_database_cluster.production.id

  rule {
    type  = "droplet"
    value = digitalocean_droplet.production.id
  }
}

# The cluster's CA, to connect with TLS verify-full (sslrootcert).
data "digitalocean_database_ca" "production" {
  cluster_id = digitalocean_database_cluster.production.id
}

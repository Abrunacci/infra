# Cloud firewall, enforced by DigitalOcean before traffic reaches the Droplet.
# Only SSH and HTTP(S) are open. UDP 443 is included because Caddy serves HTTP/3.
# ICMP is the one deliberate exception: IPv6 needs ICMPv6 ("Packet Too Big")
# for path MTU discovery, and ping and traceroute are needed to diagnose the
# network. The "icmp" protocol with an IPv6 source covers ICMPv6.
# The host firewall (ufw, managed by Ansible) applies the same rules as a second layer.
locals {
  anywhere = ["0.0.0.0/0", "::/0"]
}

resource "digitalocean_firewall" "server" {
  name        = "${var.droplet_name}-fw"
  droplet_ids = [digitalocean_droplet.server.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = local.anywhere
  }

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

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
  value       = sort([for h in local.hostnames : "${h}.${var.domain}"])
}

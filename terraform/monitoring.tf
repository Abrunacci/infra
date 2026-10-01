# Resource alerts: DigitalOcean emails var.alert_email when the Droplet runs
# short of CPU, memory or disk. Every project, PostgreSQL and Caddy share it,
# so one of them taking the machine takes them all down.
#
# CPU is measured by the hypervisor. Memory and disk come from the monitoring
# agent (do-agent), installed by Ansible (roles/monitoring): if it stops, those
# two alerts go quiet instead of firing.
#
# DigitalOcean compares the metric's average over the window with the value.
# The daily backup (03:30 UTC) and a deploy last a few seconds to a couple of
# minutes, so they do not move a 5-minute average past the threshold.

locals {
  resource_alerts = {
    cpu = {
      type        = "v1/insights/droplet/cpu"
      description = "CPU usage"
    }
    memory = {
      type        = "v1/insights/droplet/memory_utilization_percent"
      description = "Memory usage"
    }
    disk = {
      type        = "v1/insights/droplet/disk_utilization_percent"
      description = "Disk usage"
    }
  }
}

resource "digitalocean_monitor_alert" "resource" {
  for_each = local.resource_alerts

  description = "${var.droplet_name}: ${each.value.description} above ${var.alert_thresholds[each.key]}% for 5 minutes (Terraform, infra repo)"
  type        = each.value.type
  compare     = "GreaterThan"
  value       = var.alert_thresholds[each.key]
  window      = "5m"
  entities    = [digitalocean_droplet.server.id]
  enabled     = true

  alerts {
    email = [var.alert_email]
  }
}

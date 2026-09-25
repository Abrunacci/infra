variable "domain" {
  description = "Apex domain. Its DNS zone is hosted in Cloudflare."
  type        = string
  default     = "abrunacci.dev"

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a lowercase apex domain, e.g. example.dev."
  }
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID of var.domain. Passed as a variable so the Cloudflare token does not need Zone:Read."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be a 32-character hex string."
  }
}

variable "region" {
  description = "DigitalOcean region slug for the Droplet."
  type        = string
  default     = "nyc3"
}

variable "droplet_size" {
  description = "DigitalOcean Droplet size slug."
  type        = string
  default     = "s-1vcpu-2gb"

  validation {
    condition     = can(regex("^s-[0-9]+vcpu-[0-9]+gb", var.droplet_size))
    error_message = "droplet_size must be a Basic Droplet slug such as s-1vcpu-2gb."
  }
}

variable "droplet_image" {
  description = "Base image slug. Changing it on an existing Droplet is ignored (see lifecycle in main.tf)."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "droplet_name" {
  description = "Droplet hostname, also used to name the firewall and SSH key."
  type        = string
  default     = "portfolio-01"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.droplet_name))
    error_message = "droplet_name may only contain lowercase letters, digits and hyphens."
  }
}

variable "admin_user" {
  description = "Non-root sudo user that Ansible connects as. Root login is disabled."
  type        = string
  default     = "ops"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_user)) && var.admin_user != "root"
    error_message = "admin_user must be a valid Linux username other than root."
  }
}

variable "admin_ssh_public_key" {
  description = "Public SSH key (OpenSSH format) of the administrator, installed for admin_user."
  type        = string

  validation {
    condition = (
      can(regex("^(ssh-ed25519|sk-ssh-ed25519@openssh\\.com|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+( [^\\n]*)?$", trimspace(var.admin_ssh_public_key)))
      && !strcontains(trimspace(var.admin_ssh_public_key), "\n")
    )
    error_message = "admin_ssh_public_key must be a single-line OpenSSH public key (ssh-ed25519 recommended)."
  }
}

variable "allow_zero_projects" {
  description = "Set to true only to remove every project on purpose, with -var for that run (never in .env). With the default (false), a projects.yml with no projects fails the plan instead of deleting every project's DNS records."
  type        = bool
  default     = false
  nullable    = false
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID. Email Routing destination addresses belong to the account, not to the zone."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "cloudflare_account_id must be a 32-character hex string."
  }
}

variable "email_forward_to" {
  description = "Inbox that receives the mail sent to the domain's addresses. Kept out of the repo (it is public): set it in .env. It is stored in the state, which lives in the private R2 bucket."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[a-z]{2,}$", var.email_forward_to)) && !endswith(var.email_forward_to, "@${var.domain}")
    error_message = "email_forward_to must be an address outside the domain (forwarding to itself would loop)."
  }
}

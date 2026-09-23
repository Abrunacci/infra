terraform {
  # use_lockfile (native S3 state locking) needs Terraform >= 1.10.
  required_version = "~> 1.16"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.102"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.25"
    }
  }
}

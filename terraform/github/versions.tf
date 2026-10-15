terraform {
  # use_lockfile (native S3 state locking) needs Terraform >= 1.10.
  required_version = "~> 1.16"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }
}

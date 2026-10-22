# Off-site backups: one R2 bucket per server, which that server writes its
# encrypted database dumps and secrets to (the backup job lives in Ansible),
# each with its own S3 credentials, so a server never reads or lists
# another's backups (D7a). R2 is a different provider from DigitalOcean, so
# the backups survive the loss of a Droplet or of the DigitalOcean account. A configuration of its own (README.md): only the
# backups admin token, kept out of every file, can change it.
#
# Retention is by prefix: the job writes a copy to daily/ every day, to weekly/
# on Sundays and to monthly/ on the 1st. Two sets of rules act on each prefix:
#   lock       objects cannot be deleted or overwritten for that long through
#              the S3 API: a compromised server, whose credentials are S3 ones
#              for this bucket only, cannot erase the backups it already wrote
#   lifecycle  R2 deletes objects some time after the lock expires
#
#   prefix    locked for   deleted after   so there are at least
#   daily/     7 days       8 days          7 daily backups
#   weekly/   28 days      35 days          4 weekly backups
#   monthly/ 180 days     186 days          6 monthly backups
# (R2 applies lifecycle rules within a day, so there may be one more.)
#
# The lock is not immutable for R2's administrators: anything with
# `Workers R2 Storage: Edit` on the account (this configuration's token, the
# dashboard) can change or remove its rules and then delete. That is why the
# token that can do it is not the everyday one. The server's S3 credentials
# are created by hand in the dashboard, so their secret never reaches the
# Terraform state.

locals {
  # Bucket => the server that writes to it (projects.yml's servers; Ansible's
  # roles/backup has the same map, backup_buckets).
  backup_buckets = {
    "infra-backups"          = "server.abrunacci.dev"
    "epb-production-backups" = "server.epbstock.com.ar"
  }

  # Days: [locked, deleted after].
  backup_retention = {
    daily   = [7, 8]
    weekly  = [28, 35]
    monthly = [180, 186]
  }

  # Sorted by id: Cloudflare returns the rules in that order, and Terraform
  # compares this list by position, so any other order shows up as a change
  # in every plan. The precondition below keeps it that way.
  backup_lifecycle_rules = concat(
    # An upload the job never finished (a reboot midway) is not an object and
    # is not locked; its parts are removed after a day. This replaces the
    # 7-day rule R2 adds to new buckets, like every rule not declared here.
    [{
      id         = "abort-incomplete-uploads"
      enabled    = true
      conditions = { prefix = "" }
      abort_multipart_uploads_transition = {
        condition = {
          type    = "Age"
          max_age = 86400
        }
      }
    }],
    # expire-daily, expire-monthly, expire-weekly: a map is iterated in key
    # order.
    [for prefix, days in local.backup_retention : {
      id         = "expire-${prefix}"
      enabled    = true
      conditions = { prefix = "${prefix}/" }
      delete_objects_transition = {
        condition = {
          type    = "Age"
          max_age = days[1] * 86400
        }
      }
    }],
  )
}

resource "cloudflare_r2_bucket" "backups" {
  for_each = local.backup_buckets

  account_id = var.cloudflare_account_id
  name       = each.key
  # A hint, not a guarantee: Western Europe, another continent from the
  # Droplet (nyc3), so one regional outage does not take both.
  location = "weur"

  lifecycle {
    # Destroying it would destroy the backups. Removing it on purpose means
    # emptying it by hand and removing this flag in a reviewed PR.
    prevent_destroy = true
    # Only used when the bucket is created; the API may return it spelled
    # differently, which must not plan a replacement.
    ignore_changes = [location]
  }
}

resource "cloudflare_r2_bucket_lock" "backups" {
  for_each = cloudflare_r2_bucket.backups

  account_id  = var.cloudflare_account_id
  bucket_name = each.value.name

  rules = [for prefix, days in local.backup_retention : {
    id      = "lock-${prefix}"
    enabled = true
    prefix  = "${prefix}/"
    condition = {
      type            = "Age"
      max_age_seconds = days[0] * 86400
    }
  }]

  lifecycle {
    # Removing (or renaming) this block would drop every lock rule with no
    # error, leaving the backups deletable by the server.
    prevent_destroy = true
  }
}

resource "cloudflare_r2_bucket_lifecycle" "backups" {
  for_each = cloudflare_r2_bucket.backups

  account_id  = var.cloudflare_account_id
  bucket_name = each.value.name

  rules = local.backup_lifecycle_rules

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = join(",", local.backup_lifecycle_rules[*].id) == join(",", sort(local.backup_lifecycle_rules[*].id))
      error_message = "cloudflare_r2_bucket_lifecycle.backups: keep the rules sorted by id, the order Cloudflare returns them in."
    }
    precondition {
      # A lifecycle rule that fires while the lock still holds would fail to
      # delete, silently.
      condition     = alltrue([for days in values(local.backup_retention) : days[1] > days[0]])
      error_message = "backup_retention: every prefix must be deleted after its lock expires."
    }
  }
}

# The first bucket, from before there was one per server: the same objects,
# now under its name.
moved {
  from = cloudflare_r2_bucket.backups
  to   = cloudflare_r2_bucket.backups["infra-backups"]
}

moved {
  from = cloudflare_r2_bucket_lock.backups
  to   = cloudflare_r2_bucket_lock.backups["infra-backups"]
}

moved {
  from = cloudflare_r2_bucket_lifecycle.backups
  to   = cloudflare_r2_bucket_lifecycle.backups["infra-backups"]
}

# Protection of `main` in every repository of the account with activity in
# 2026 (forks aside), one ruleset each:
#   - changes reach `main` only through a pull request; no approval is
#     required, since a single person writes and merges
#   - the pull request needs the repository's CI checks below to pass
#   - `main` cannot be deleted or force-pushed
#   - nobody can bypass it, the account's owner included
#
# A required check is the name a CI job reports (its `name:`, or its key when
# it has none), and only GitHub Actions can report it. Each one must run on
# every pull request of its repository: a check that does not run (a workflow
# with `paths:`, a job that is renamed or removed) leaves every pull request
# waiting for it forever. So a job that only runs when some paths change is
# left out, and renaming a required job means changing it here first.
locals {
  # strict: the pull request's branch must contain the latest `main` before it
  # can be merged. Kept as each repository had it before this configuration.
  repositories = {
    "infra" = {
      checks = [
        "Lint (pre-commit)",
        "Secret scan (full history)",
        "Config scan (trivy)",
        "Test (check-commit-metadata)",
        "Test (body limits)",
      ]
      strict = false
    }
    "EPB_Stock" = {
      # Sums up backend, frontend and image; it fails if any of them did not
      # pass, so splitting or adding jobs there does not touch this list.
      checks = ["ci"]
      strict = false
    }
    "bieldo" = {
      checks = ["backend", "frontend", "landing", "no-data", "demo", "image"]
      strict = false
    }
    "odonapp-mobile" = {
      checks = ["checks"]
      strict = false
    }
    "abrunacci.dev" = {
      checks = [
        "Validate HTML and internal links",
        "Backend tests and lint",
        "Backend image",
      ]
      strict = true
    }
    "cuanto-cuesta" = {
      checks = ["backend", "frontend", "backend-image"]
      strict = true
    }
    "data-pipeline" = {
      checks = ["check", "image"]
      strict = true
    }
    "berry_med" = {
      # `build` runs only on pull requests that change the build (paths:).
      checks = ["tests"]
      strict = false
    }
    # Its only pull request check (`dev`) runs only when databricks_lab/
    # changes (paths:), so none is required.
    "databricks-lab" = {
      checks = []
      strict = true
    }
    # No CI: pull request, no deletion and no force push only.
    "shopify-lab"       = { checks = [], strict = false }
    "financieras"       = { checks = [], strict = false }
    "notas"             = { checks = [], strict = false }
    "servicios-landing" = { checks = [], strict = false }
  }

  # The GitHub Actions app. A required check with it can only be reported by
  # a workflow, not by anything else that can set a commit status.
  github_actions_app_id = 15368
}

resource "github_repository_ruleset" "main" {
  for_each = local.repositories

  repository  = each.key
  name        = "main"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count = 0
      allowed_merge_methods           = ["merge", "squash", "rebase"]
    }

    dynamic "required_status_checks" {
      for_each = length(each.value.checks) > 0 ? [each.value] : []

      content {
        strict_required_status_checks_policy = required_status_checks.value.strict

        dynamic "required_check" {
          for_each = required_status_checks.value.checks

          content {
            context        = required_check.value
            integration_id = local.github_actions_app_id
          }
        }
      }
    }
  }

  lifecycle {
    # Removing a repository from the list above (or renaming its key) deletes
    # its protection. Take this out in a reviewed PR when that is the intent.
    prevent_destroy = true
  }
}

# GitHub

The protection of `main` in every repository of the account with activity in 2026 (forks aside), as one ruleset per repository. A Terraform configuration of its own, next to the main one (`..`), because the token that can change it administers the repositories and must not be the everyday one.

## What it enforces

In every repository below, the ruleset `main` applies to the default branch:

- changes reach it only through a pull request, with no approval required (a single person writes and merges);
- the pull request needs the repository's required checks to pass;
- it cannot be deleted or force-pushed;
- nobody can bypass it, the account's owner included.

| Repository | Required checks | Branch must be up to date |
|---|---|---|
| `infra` | `Lint (pre-commit)`, `Secret scan (full history)`, `Config scan (trivy)`, `Test (check-commit-metadata)`, `Test (body limits)` | no |
| `EPB_Stock` | `ci` (fails unless `backend`, `frontend` and `image` passed) | no |
| `bieldo` | `backend`, `frontend`, `landing`, `no-data`, `demo`, `image` | no |
| `odonapp-mobile` | `checks` | no |
| `abrunacci.dev` | `Validate HTML and internal links`, `Backend tests and lint`, `Backend image` | yes |
| `cuanto-cuesta` | `backend`, `frontend`, `backend-image` | yes |
| `data-pipeline` | `check`, `image` | yes |
| `berry_med` | `tests` | no |
| `databricks-lab` | none | – |
| `shopify-lab`, `financieras`, `notas`, `servicios-landing` | none (no CI) | – |

"Branch must be up to date" is kept as each repository had it before this configuration. The list lives in `main.tf`.

## Which checks can be required

A required check is the name a CI job reports: its `name:`, or its key in `jobs:` when it has none. Only GitHub Actions can report it (`integration_id` 15368), not anything else that can set a commit status.

**Every required check must run on every pull request of its repository.** GitHub waits for a required check that never reports: a pull request whose workflow did not run it stays blocked with "Expected — Waiting for status to be reported". That happens when:

- the workflow has `paths:` or `paths-ignore:` under `pull_request:`, and the pull request does not touch those paths. That is why these are left out: `build` in `berry_med` (only when the build changes) and `dev` in `databricks-lab` (only when `databricks_lab/` changes);
- the job is renamed or removed. Change it here first, apply, then merge the rename.

A job skipped by its own `if:` counts as passed, so it does not block, but it does not protect either.

Before adding a check, confirm it appears, with that exact name, on the last pull requests of the repository (a pull request's "Checks" tab, or `gh pr checks <number> --repo Abrunacci/<repository>`).

## Credentials

| What | Where | Scope | Expires |
|---|---|---|---|
| GitHub rulesets token | Password manager; typed in as `GITHUB_TOKEN` for these runs only | Fine-grained, `Abrunacci`'s repositories in the table above only: `Administration: Read and write` (and `Metadata: Read`, which GitHub adds) | 2027-10-15 |
| State S3 credentials | `../.env`, as for the main configuration | `Object Read & Write` on `infra-tfstate` | see `../README.md` |

The token is also a row of `../README.md`, "Credentials", so the server's expiry check warns 14 days before it expires. The state lives in the same bucket as the main one, under `infra/github.tfstate`.

`Administration: Read and write` lets the token change any setting of those repositories, delete them included. That is why it is kept away: it is not in `../.env`, it lives in the password manager with an expiration date, and it is typed in only for this configuration's runs.

To create it:
1. Go to https://github.com/settings/personal-access-tokens/new (Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token).
2. **Token name:** `terraform github rulesets`.
3. **Resource owner:** `Abrunacci`.
4. **Expiration:** Custom, `2027-10-15` (the date in the table above).
5. **Repository access:** Only select repositories, and pick the 13 repositories of the table above.
6. **Permissions** → Repository permissions → **Administration:** Read and write. GitHub adds **Metadata:** Read-only by itself. Nothing else.
7. **Generate token**.

Copy the value into the password manager; GitHub shows it once. If you create it on another date, write its expiration in both tables (here and in `../README.md`).

## Usage

From the repo's root, with the token in the password manager. The parentheses run it all in a subshell, so neither the token nor anything from `.env` is left in your terminal afterwards, even if a step fails:

```sh
(
  cd terraform/github || exit 1                  # stops here if not run from the repo's root
  set -a; . ../.env; set +a                      # state credentials
  read -rs "GITHUB_TOKEN?GitHub rulesets token: "; echo; export GITHUB_TOKEN
  terraform init -input=false                    # needed once; harmless afterwards
  terraform plan -out=tfplan && terraform apply tfplan
)
```

`read -s` (zsh syntax; in bash: `read -rsp 'GitHub rulesets token: ' GITHUB_TOKEN`) reads the token without showing it or saving it in the history. `terraform apply tfplan` asks for no confirmation: it applies the plan printed just above, so stop with Ctrl-C at the plan if it is not what you expect, or run the plan alone first (without `&& terraform apply tfplan`).

## Adding a repository

1. Add it to the token's repositories: the token's page → Edit → Repository access. Without that, the plan fails with `404 Not Found` on it.
2. Add it to `local.repositories` in `main.tf`, with its checks (see "Which checks can be required").
3. If it already has a ruleset made by hand, add an `import` block for it in `imports.tf` (its id is in the ruleset's URL, Settings → Rules → Rulesets), so the apply adopts it instead of creating a second one.
4. Add it to the tables above, plan and apply.

Removing a repository from the list would delete its protection: every ruleset has `prevent_destroy`, so the plan fails until that is taken out in a reviewed PR.

## Changes made outside Terraform

A ruleset changed in the GitHub settings shows up in the next plan as a change back to what `main.tf` says. Apply it, or bring the change into `main.tf` if it was meant to stay.

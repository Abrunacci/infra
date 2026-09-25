# Backups bucket

The R2 bucket the server writes its encrypted backups to (the backup job lives in Ansible), with the rules that keep them. A Terraform configuration of its own, next to the main one (`..`), because the only token that can change it must not be the everyday one.

| Resource | What it does |
|---|---|
| `cloudflare_r2_bucket.backups` | Bucket `infra-backups`, location hint Western Europe (another continent from the Droplet) |
| `cloudflare_r2_bucket_lock.backups` | Objects under each prefix cannot be deleted or overwritten for a while |
| `cloudflare_r2_bucket_lifecycle.backups` | R2 deletes them once their lock has expired; unfinished uploads after a day |

The job writes `daily/` every day, `weekly/` on Sundays and `monthly/` on the 1st:

| Prefix | Locked for | Deleted after | So there are at least |
|---|---|---|---|
| `daily/` | 7 days | 8 days | 7 daily backups |
| `weekly/` | 28 days | 35 days | 4 weekly backups |
| `monthly/` | 180 days | 186 days | 6 monthly backups |

R2 applies lifecycle rules within a day of their time, so there may be one more of each. A precondition fails the plan if a prefix would be deleted before its lock expires. Every resource has `prevent_destroy`: removing or renaming a block by mistake must not drop the lock.

## What the lock protects, and what it does not

- **It protects the backups from the server.** The server uploads with S3 credentials for this bucket only (`Object Read & Write`; R2 has no write-only permission). Through the S3 API, no object can be deleted or overwritten while locked, so a compromised server cannot erase the backups it already wrote. It could stop writing new ones: the backup job's freshness warning is what catches that.
- **It does not protect them from R2's administrators.** Anything with `Workers R2 Storage: Edit` on the account can change or remove the lock's rules, and then delete. That means this configuration's token, and your login to the Cloudflare dashboard. A token with that permission also works as S3 credentials for every bucket of the account, the Terraform state's included.
- **So that token is kept away:**
  - it is not in `../.env`, and the everyday Terraform token has no R2 permission;
  - it lives in the password manager, with an expiration date;
  - it is typed in only for this configuration's runs.
- **The lock holds for everyone who is not an administrator, you included:** something written there by mistake stays until its lock expires.

## Credentials

| What | Where | Scope | Expires |
|---|---|---|---|
| Backups admin token | Password manager; typed in as `CLOUDFLARE_API_TOKEN` for these runs only | `Account → Workers R2 Storage → Edit`, this account only | set when created |
| State S3 credentials and account ID | `../.env`, as for the main configuration | `Object Read & Write` on `infra-tfstate` | see `../README.md` |

The state lives in the same bucket as the main one, under `infra/backups.tfstate`.

To create the admin token:
1. Go to https://dash.cloudflare.com/profile/api-tokens → **Create Token** → **Create Custom Token**.
2. **Token name:** `terraform backups bucket`.
3. **Permissions:** `Account` · `Workers R2 Storage` · `Edit`.
4. **Account Resources:** Include · your account.
5. **TTL:** an end date, for example a year from now.
6. **Continue to summary** → **Create Token**.

Copy the value into the password manager; Cloudflare shows it once. Write its end date in the table above.

## Usage

From the repo's root, with the admin token in the password manager. The parentheses run it all in a subshell, so neither the admin token nor anything from `.env` is left in your terminal afterwards, even if a step fails:

```sh
(
  cd terraform/backup-bucket
  set -a; . ../.env; set +a                      # state credentials and account ID
  read -rs "CLOUDFLARE_API_TOKEN?Backups admin token: "; echo; export CLOUDFLARE_API_TOKEN
  terraform init -input=false                    # needed once; harmless afterwards
  terraform plan -out=tfplan && terraform apply tfplan
)
```

`read -s` (zsh syntax; in bash: `read -rsp 'Backups admin token: ' CLOUDFLARE_API_TOKEN`) replaces the everyday token that `.env` loaded, without showing it or saving it in the history. `terraform apply tfplan` asks for no confirmation: it applies the plan printed just above, so stop with Ctrl-C at the plan if it is not what you expect, or run the plan alone first (without `&& terraform apply tfplan`).

The state credentials in `../.env` can also write this configuration's state (`infra/backups.tfstate`). That does not let anyone change R2 without the admin token; at most, an altered state would make the next plan propose recreating something, which the review of that plan catches.

The server's S3 credentials (`Object Read & Write` on `infra-backups` only) are created by hand in **R2 → Manage API tokens**, so their secret never reaches the state; the backup job's documentation says how.

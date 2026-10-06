# Terraform

Creates everything the platform needs in DigitalOcean and Cloudflare:

| Resource | File |
|---|---|
| Droplet (`s-1vcpu-2gb`, `nyc3`, Ubuntu 24.04, IPv6, minimal cloud-init) | `main.tf` |
| Admin SSH key, tags and a DigitalOcean project that groups the resources | `main.tf` |
| Cloud firewall: inbound TCP 22, 80 and 443, UDP 443 for HTTP/3, and ICMP/ICMPv6 | `firewall.tf` |
| Resource alerts by email: CPU, memory or disk above 80 % for 5 minutes | `monitoring.tf` |
| A/AAAA records for `server`, `status` and each project in `../projects.yml`: the root domain for a project on `"@"`, plus `www` | `dns.tf` |
| CAA records that allow only Let's Encrypt and ZeroSSL | `dns.tf` |
| Universal SSL turned off, so Cloudflare adds no CAA records of its own | `dns.tf` |
| DNSSEC: the zone signed by Cloudflare, its DS record published in `.dev` by Cloudflare Registrar | `dns.tf` |
| Google Search Console verification TXT record on the root domain | `dns.tf` |
| Email Routing: `hello@`, `postmaster@` and `abuse@` forwarded to one inbox, every other address rejected | `email.tf` |
| DMARC `p=reject`: only Resend sends mail, from `mail.abrunacci.dev` | `email.tf` |
| Resend's sending records (two CNAMEs and the DKIM key) under `mail.abrunacci.dev` | `email.tf` |

## Credentials

Nothing secret is stored in files that are committed. Every credential Terraform uses comes from the environment; `.env.example` lists them. The others are kept in the password manager, and typed in only for their runs or stored on the server.

Two tokens have almost the same name: **`terraform-infra`** (lowercase) is DigitalOcean's, and **`Terraform-infra`** (capital T) is Cloudflare's. The "Variable" column is what each one is called everywhere else in the repo, and in the expiry alerts.

| Variable | What it is | Provider: name in the panel (type) | Where in the panel | Minimum scope | Expires |
|---|---|---|---|---|---|
| `DIGITALOCEAN_TOKEN` | Terraform's DigitalOcean token, for the Droplet, firewall, SSH key, tags, project and resource alerts. In `.env` | DigitalOcean: `terraform-infra` (personal access token) | API → Tokens → Personal access tokens | Custom scopes: droplet, firewall, ssh_key, tag, project and monitoring, each at the levels in [DigitalOcean token scopes](#digitalocean-token-scopes) | 2027-10-01 |
| `CLOUDFLARE_API_TOKEN` | Terraform's Cloudflare token, for DNS, Email Routing and the zone settings. In `.env` | Cloudflare: `Terraform-infra` (user token) | My Profile → API Tokens | On the `abrunacci.dev` zone only: `Zone → DNS → Edit`, `Zone → SSL and Certificates → Edit`, `Zone → Email Routing Rules → Edit` and `Zone → Zone Settings → Edit`. On this account only: `Account → Email Routing Addresses → Edit` | 2026-12-23 |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | R2 S3 credentials for Terraform's state (this configuration's and `backup-bucket/`'s). In `.env` | Cloudflare R2: `infra-tfstate` (account token) | R2 Object Storage → Manage API tokens | `Object Read & Write` on the `infra-tfstate` bucket only | – (does not expire) |
| Backups admin token (not in `.env`) | Cloudflare token for [`backup-bucket/`](backup-bucket/README.md), the backups bucket's own configuration (lock and lifecycle). Kept in the password manager and typed in as `CLOUDFLARE_API_TOKEN` only for its runs | Cloudflare R2: `terraform backups bucket` (user token) | R2 Object Storage → Manage API tokens | `Admin Read & Write` on every bucket of this account | 2027-09-25 |
| Server backups token (not in `.env`) | R2 S3 credentials the server uploads the backups with. Kept in the password manager and on the server, stored with `sudo backup-credentials` (`/etc/infra/secrets/backup/r2.env`); the password manager's copy is what "Restoring without pasting the key on the server" (`ansible/README.md`) downloads with | Cloudflare R2: `server backups` (account token) | R2 Object Storage → Manage API tokens | `Object Read & Write` on the `infra-backups` bucket only | 2027-09-25 |
| GHCR token (not in `.env`) | GitHub personal access token (classic) the server pulls private backend images with. Kept in the password manager and on the server; see `ansible/README.md`, "Pulling private images" | GitHub: `server.abrunacci.dev GHCR pull` (personal access token, classic) | Settings → Developer settings → Personal access tokens → Tokens (classic) | `read:packages` only | 2027-10-05 |
| Resend key (not in `.env`) | Resend API key the landing's contact form sends with (`RESEND_API_KEY` of `abrunacci-dev`). Kept in the password manager and on the server only (`sudo project-secret abrunacci-dev set RESEND_API_KEY`) | Resend: `abrunacci-dev-contact` (API key) | API Keys | Sending access, domain `mail.abrunacci.dev` only | – (Resend keys don't expire; revoke it in Resend if it leaks) |

The other variables in `.env` are not credentials:

| Setting | What it is | Notes |
|---|---|---|
| `TF_VAR_cloudflare_zone_id` | Zone ID, shown on the zone's overview page | A variable, so the token needs no `Zone:Read` |
| `TF_VAR_cloudflare_account_id` | Account ID, shown on the same page | Email Routing destination addresses belong to the account |
| `TF_VAR_email_forward_to` | The inbox that receives the domain's mail | Kept out of the repo, which is public. It is stored in the state |
| `TF_VAR_alert_email` | The address DigitalOcean sends the resource alerts to. It must belong to a verified user of the DigitalOcean team | Same as above |
| `AWS_ENDPOINT_URL_S3` | `https://<account_id>.r2.cloudflarestorage.com` | – |
| `TF_VAR_admin_ssh_public_key` | Your public SSH key | – |

When you create or rotate a token, write its expiration date (not a secret) in "Expires": an expired token fails whatever uses it next (a `terraform apply`, the nightly backup, a pull of a private image), while everything already running keeps running. The playbook reads this table's "Expires" column (the first `YYYY-MM-DD` in it), and the status page's `Server / Credentials` heartbeat fails, and emails you, 14 days before a date. After rotating a token, write its new date here and run `./play site.yml -K --diff --tags gatus`. A row without a date is not watched.

The Cloudflare token needs `SSL and Certificates: Edit` only to keep Universal SSL off, and `Zone Settings: Edit` only to turn Email Routing on. `Zone Settings: Edit` covers every setting of the zone, but nothing is proxied, so almost none of them has any effect. The token still cannot touch any other zone, and on the account it can only manage Email Routing destination addresses. It has no R2 permission on purpose: see [`backup-bucket/`](backup-bucket/README.md). The R2 credentials (the state's and the server's) are separate tokens: a leak of one does not expose the others.

### DigitalOcean token scopes

DigitalOcean does not let you edit a token's scopes: rotating it, or adding a scope, means creating a new token with every scope below and deleting the old one. Each level maps to what Terraform does with that resource:

| Scope | Levels | Why Terraform needs each level |
|---|---|---|
| `droplet` | create, read, update, delete | read: every plan. create: the first apply, or a rebuild. update: resizing (which powers the Droplet off and on), renaming, attaching tags. delete: only a deliberate rebuild, after `prevent_destroy` is removed in a reviewed PR |
| `firewall` | create, read, update, delete | read: every plan. update: changing a rule or the Droplets it applies to. create and delete: a rebuild, or replacing the firewall |
| `ssh_key` | create, read, update, delete | read: every plan. update: renaming the key. create and delete: changing `TF_VAR_admin_ssh_public_key` replaces the key |
| `tag` | create, read, delete | read: every plan. create: creating the `infra` and `portfolio` tags and attaching them to the Droplet (DigitalOcean asks for `tag:create` plus `droplet:update` to tag a Droplet). delete: removing a tag from `local.tags`. Tags have no update level |
| `project` | create, read, update, delete, assign_resource | read: every plan. assign_resource: putting the Droplet in the project (it needs `droplet:read` too). update: changing the project's name, description, purpose or environment. create and delete: a rebuild |
| `monitoring` | create, read, update, delete | The resource alerts (`monitoring.tf`). update: changing a threshold, including the one-run test in [Resource alerts](#resource-alerts). Added on 2026-10-01 |

When you pick those scopes, the control panel also adds read-only dependencies (read on actions, regions, sizes, image, snapshot and vpc; 30 scopes in total with the ones above). Keep them: the provider reads them while creating or resizing the Droplet.

Nothing else is needed: DNS is in Cloudflare, and the backups go to R2, so the token has no `domain`, `spaces` or `volume` scope. If a plan or apply fails with `403` on a DigitalOcean resource, the token is missing a level of that resource's scope.

## State

The state lives in the R2 bucket `infra-tfstate`, key `infra/terraform.tfstate`. `use_lockfile = true` uses S3 conditional writes to lock it, so two concurrent runs cannot corrupt it. The bucket is created by hand once, because Terraform needs it before it can manage anything.

## Usage

```sh
cd terraform
cp .env.example .env        # fill it in; .env is git-ignored
set -a; . ./.env; set +a

terraform init
terraform plan -out=tfplan  # review it
terraform apply tfplan      # only after the plan has been reviewed
```

## Mail

Cloudflare Email Routing forwards `hello@`, `postmaster@` and `abuse@` to `TF_VAR_email_forward_to` (`email.tf`). Every other address is rejected while the message is being delivered, so the sender gets a bounce: the catch-all rule is declared, disabled.

- **MX, SPF and DKIM are Cloudflare's.** `cloudflare_email_routing_dns` turns Email Routing on, and Cloudflare writes those records and locks them. They are not declared in `dns.tf`: their values (the MX priorities, the DKIM key) are assigned by Cloudflare, and a locked record cannot be managed by Terraform anyway. Destroying `cloudflare_email_routing_dns` turns Email Routing off.
- **The destination address must be verified.** Creating it makes Cloudflare send a verification email. Until the link is clicked, the forwarding rules' precondition fails. So the first apply goes in two steps:
  1. `terraform plan -out=tfplan -target=cloudflare_email_routing_address.forward`, review it, `terraform apply tfplan`.
  2. Click the link in the email, then run the full plan and apply as usual.

  Without step 1, the full apply creates the address and then fails at the precondition. Nothing breaks: the next plan and apply, after the click, finish the job.
- **Changing the inbox** (`TF_VAR_email_forward_to`) replaces the address, new one first (`create_before_destroy`). The apply creates it and then stops at the rules' precondition, on purpose: the rules still forward to the old inbox, which keeps working. Click the link sent to the new inbox, then plan and apply again: the rules move to it, and only then is the old address destroyed.
- **DMARC `p=reject`.** Only Resend sends mail for the domain (below), so receivers reject any other message that claims to come from it or a subdomain. Replies go out from the inbox's own address: Gmail's "Send mail as" with an `@abrunacci.dev` address would fail DMARC too.
- **Resend sends the projects' mail from `mail.abrunacci.dev`** (EPB Stock's, for now). Its three records (`send.mail` and `rsend.mail`, CNAMEs to Resend, and the DKIM key in `resend._domainkey.mail`) were created on 2026-09-28 by Resend's Domain Connect flow, then adopted with `import` blocks. They are declared exactly as Resend wrote them (no comment, TTL 1 h, DNS only): a change to any of them breaks sending until Resend verifies the domain again. Mail passes DMARC through the DKIM signature, whose domain `mail.abrunacci.dev` aligns with the root domain's policy.
- **Adopting records created outside Terraform.** The `import` block in `email.tf` runs only when the records' Cloudflare IDs are passed, for that run only: `terraform plan -out=tfplan -var='resend_record_ids={send="<id>",rsend="<id>",dkim="<id>"}'`. The IDs come from the API (the token in `.env` can read them):

  ```sh
  curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$TF_VAR_cloudflare_zone_id/dns_records?name.endswith=mail.abrunacci.dev" \
    | jq -r '.result[] | [.id, .type, .name, .ttl, .proxied, .content] | @tsv'
  ```

  Once they are in the state, the block does nothing and the variable is no longer passed.
- **The inbox address is in the state.** `email_forward_to` is `sensitive`, so plans hide it, but the state in R2 stores it in plain text.

## After the first apply

Check that ICMPv6 passes the cloud firewall. DigitalOcean's docs do not state it explicitly, so it is verified once from a host with IPv6:

```sh
ping -6 -c3 server.abrunacci.dev
tracepath -6 server.abrunacci.dev   # should report the path MTU without stalling
```

## Resource alerts

The Droplet runs every project, PostgreSQL and Caddy, so one of them taking the machine takes them all down. DigitalOcean emails `TF_VAR_alert_email` when, averaged over 5 minutes, CPU, memory or disk usage goes above 80 % (`monitoring.tf`), and again when it is back below. The daily backup and a deploy last seconds to a couple of minutes, so they do not trigger it.

- **Memory and disk come from the monitoring agent** (`do-agent`), which the `monitoring` Ansible role keeps installed and running. If the agent stops, those two alerts go quiet instead of firing; the status page notices instead and emails within about 10 minutes (`ansible/README.md`, "Status page and alerts"). CPU is measured by the hypervisor and does not depend on it.
- **Testing that the email arrives:** lower one threshold for a single run, `terraform plan -out=tfplan -var='alert_thresholds={cpu=80,memory=80,disk=1}'`, apply it, wait for the email, then plan and apply without the flag to put it back. Never put `alert_thresholds` in `.env`: the lowered value would stay without anyone noticing.

## Backups bucket

The R2 bucket for the server's backups, its lock and its lifecycle are a separate configuration, with its own state and its own token, in [`backup-bucket/`](backup-bucket/README.md): the token that can change them is not the one in `.env`.

## Safety rails

- **`prevent_destroy`** on the Droplet: it holds the PostgreSQL data, so Terraform refuses any plan that would destroy it while the resource block is in the code: `terraform destroy`, or a change that forces a replacement. Rebuilding on purpose means removing the flag in a reviewed PR and restoring from backup.
  - **Its limit:** the flag lives inside the resource block. If the whole block is deleted, the protection goes with it, and the next plan destroys the Droplet with no error. Renaming the resource (`digitalocean_droplet.server`) without a `moved` block has the same effect.
  - **So every `-` in a plan is reviewed**, and so is every `-/+` (replace). The summary line (`N to destroy`) must be 0 unless the PR says why.
- **`ignore_changes = [user_data, ssh_keys, image]`**: these only matter at creation, and changing them would force a new Droplet. After the first boot, Ansible owns the server's configuration.
- **Resizing** (`droplet_size`) keeps the Droplet but powers it off: `graceful_shutdown = true` stops PostgreSQL cleanly, and `resize_disk = false` changes only CPU and RAM, so the Droplet can go back to a smaller size.
- **`projects.yml` is validated**, so a mistake fails instead of being read as zero projects, which would plan the deletion of every project's DNS records:
  - A missing file, invalid YAML, or a missing or empty top-level `projects` key fails `terraform validate`. An entry without `subdomain` is an internal project (such as `data-pipeline`): it gets no DNS record.
  - Subdomains that are not strings (unquoted `yes`, `true` or `0123`), invalid, duplicated or reserved (`server`, `status`, `www`) fail the plan. `"@"` is the root domain; with `site: true` it adds `www`, which redirects to it.
  - A registry with no project that has a subdomain fails the plan too, unless it is allowed on purpose, for that run only: `terraform plan -out=tfplan -var=allow_zero_projects=true`. Never put it in `.env`: the guard would stay off without anyone noticing. That also covers a key repeated in the file, such as a second `projects: []` left by a bad merge: YAML keeps the last one.
  - yamllint also rejects repeated keys (`key-duplicates`) in pre-commit and CI. A repeated key that still leaves some projects, or a repeated `subdomain`, is caught only there, so run `pre-commit run --all-files` before a local plan.
- **`proxied = false`** is set explicitly on every record, so the Cloudflare proxy cannot be turned on by accident (see the DNS decision in the main README).
- **No IP addresses are committed.** Ansible and SSH use `server.abrunacci.dev`.

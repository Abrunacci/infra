# Terraform

Creates everything the platform needs in DigitalOcean and Cloudflare:

| Resource | File |
|---|---|
| Droplet (`s-1vcpu-2gb`, `nyc3`, Ubuntu 24.04, IPv6, minimal cloud-init) | `main.tf` |
| Admin SSH key, tags and a DigitalOcean project that groups the resources | `main.tf` |
| Cloud firewall: inbound TCP 22, 80 and 443, UDP 443 for HTTP/3, and ICMP/ICMPv6 | `firewall.tf` |
| Resource alerts by email: CPU, memory or disk above 80 % for 5 minutes, on each Droplet | `monitoring.tf` |
| EPB Stock's production: a VPC of its own (`epb-production`), a Droplet in it (`epb-prod-01`, `s-2vcpu-4gb`, `nyc3`, Ubuntu 24.04, IPv6) whose cloud-init also joins Tailscale, its cloud firewall (TCP 80 and 443, UDP 443 and 41641 for Tailscale, ICMP; no SSH), and a managed PostgreSQL 17 cluster in the VPC (`epb-production-db`, `db-s-1vcpu-1gb`, one node, maintenance on Sundays at 07:00 UTC) reachable from that Droplet only, with a PgBouncer pool per project with a database on the production server (transaction mode, 12 connections). Outputs: `production_droplet`, `production_db_host`, `production_db_port`, `production_db_ca`, `production_database` (what Ansible reads), `production_db_password` (sensitive, for `sudo database-credentials`) and `production_db_pools` | `production.tf` |
| Tailscale: the tailnet's policy (who reaches the production Droplet's SSH: your devices and `tag:ci`) and the one-use key the production Droplet joins with | `tailscale.tf` |
| One Cloudflare zone per domain in `../projects.yml` (`domains`); the first one (`abrunacci.dev`) is the server's own | `dns.tf` |
| A/AAAA records for each server in `../projects.yml` (`servers`, pointing at its Droplet), `status` (on the first domain, at the first server) and each project, at its server (the first one by default), under its domain: the domain itself for a project on `"@"`, plus `www`; and each project's `redirect_from` and `also_serves`, in the zone of its domain | `dns.tf` |
| CAA records on every domain that allow only Let's Encrypt and ZeroSSL | `dns.tf` |
| Universal SSL turned off on every zone, so Cloudflare adds no CAA records of its own | `dns.tf` |
| DNSSEC: every zone signed by Cloudflare except those in `dnssec_off`. For a domain registered with Cloudflare Registrar (`abrunacci.dev`, `epbstock.com`), Cloudflare publishes its DS record (output `dnssec_ds` has each domain's). `epbstock.com.ar` is not signed: NIC Argentina takes no DS records; it can be turned back on if it ever does (see `dnssec_off`) | `dns.tf` |
| Google Search Console verification TXT record on `abrunacci.dev` | `dns.tf` |
| Email Routing, on each domain with `mail_forward` in `../projects.yml` (`hello@`, `postmaster@` and `abuse@abrunacci.dev`): those addresses forwarded to one inbox, every other address rejected | `email.tf` |
| Proton Mail's MX, SPF, verification and DKIM records, on each domain with `proton` in `../projects.yml` (`epbstock.com.ar`) | `email.tf` |
| Null MX and SPF `-all` on each domain with no mail (`epbstock.com`): it receives none and sends none | `email.tf` |
| DMARC `p=reject` on every domain: only Resend (from `mail.abrunacci.dev`) and Proton (from its domains) send mail | `email.tf` |
| Resend's sending records (two CNAMEs and the DKIM key) under `mail.abrunacci.dev` | `email.tf` |
| Turnstile widget for the landing's contact form (`abrunacci.dev`, Managed mode); its keys are the outputs `turnstile_site_key` and `turnstile_secret_key` | `turnstile.tf` |
| Turnstile widget for EPB Stock's landing (`epbstock.com.ar`, Invisible mode); its keys are the outputs `epb_landing_turnstile_site_key` and `epb_landing_turnstile_secret_key` | `turnstile.tf` |
| Cloudflare Web Analytics site for EPB Stock's landing (`epbstock.com.ar`); its site token is the output `epb_landing_web_analytics_token` | `analytics.tf` |

## Credentials

Nothing secret is stored in files that are committed. Every credential Terraform uses comes from the environment; `.env.example` lists them. The others are kept in the password manager, and typed in only for their runs or stored on the server.

Two tokens have almost the same name: **`terraform-infra`** (lowercase) is DigitalOcean's, and **`Terraform-infra`** (capital T) is Cloudflare's. The "Variable" column is what each one is called everywhere else in the repo, and in the expiry alerts.

| Variable | What it is | Provider: name in the panel (type) | Where in the panel | Minimum scope | Expires |
|---|---|---|---|---|---|
| `DIGITALOCEAN_TOKEN` | Terraform's DigitalOcean token, for the Droplets, firewalls, SSH key, tags, project, resource alerts, the production VPC and its database cluster. In `.env` | DigitalOcean: `terraform-infra` (personal access token) | API → Tokens → Personal access tokens | Custom scopes: droplet, firewall, ssh_key, tag, project, monitoring, vpc and database, each at the levels in [DigitalOcean token scopes](#digitalocean-token-scopes) | 2027-10-21 |
| `CLOUDFLARE_API_TOKEN` | Terraform's Cloudflare token, for DNS, Email Routing, the zone settings, the Turnstile widgets and Web Analytics. In `.env` | Cloudflare: `Terraform-infra` (user token) | My Profile → API Tokens | On the zones in `../projects.yml` only (`abrunacci.dev`, `epbstock.com.ar` and `epbstock.com`): `Zone → DNS → Edit`, `Zone → SSL and Certificates → Edit`, `Zone → Email Routing Rules → Edit` and `Zone → Zone Settings → Edit`. On this account only: `Account → Email Routing Addresses → Edit`, `Account → Turnstile → Edit`, `Account → Account Settings → Edit` and `Account → Account Settings → Read` | 2027-10-19 |
| `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET` | Terraform's Tailscale OAuth client, for the tailnet's policy and the production Droplet's join key (`tailscale.tf`). In `.env` | Tailscale: `terraform-infra` (OAuth client) | Settings → OAuth clients | `Policy File: Write` and `Auth Keys: Write`, with the tag `tag:terraform` only. A client with tags can only create keys that carry exactly its tags, or tags its tags own: in `tailscale.tf`, `tag:terraform` owns `tag:prod` and `tag:ci` | – (OAuth clients do not expire; revoke it in Tailscale if it leaks) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | R2 S3 credentials for Terraform's state (this configuration's, `backup-bucket/`'s and `github/`'s). In `.env` | Cloudflare R2: `infra-tfstate` (account token) | R2 Object Storage → Manage API tokens | `Object Read & Write` on the `infra-tfstate` bucket only | – (does not expire) |
| Backups admin token (not in `.env`) | Cloudflare token for [`backup-bucket/`](backup-bucket/README.md), the backups bucket's own configuration (lock and lifecycle). Kept in the password manager and typed in as `CLOUDFLARE_API_TOKEN` only for its runs | Cloudflare R2: `terraform backups bucket` (user token) | R2 Object Storage → Manage API tokens | `Admin Read & Write` on every bucket of this account | 2027-09-25 |
| GitHub rulesets token (not in `.env`) | GitHub token for [`github/`](github/README.md), the protection of `main` in each repository (rulesets). Kept in the password manager and in `github/.env` as `GITHUB_TOKEN`, a file only that configuration loads | GitHub: `terraform github rulesets` (fine-grained personal access token) | Settings → Developer settings → Personal access tokens → Fine-grained tokens | `Administration: Read and write` (plus `Metadata: Read`) on the repositories listed in `github/README.md` only | 2027-10-15 |
| Server backups token (not in `.env`) | R2 S3 credentials the server uploads the backups with. Kept in the password manager and on the server, stored with `sudo backup-credentials` (`/etc/infra/secrets/backup/r2.env`); the password manager's copy is what "Restoring without pasting the key on the server" (`ansible/README.md`) downloads with | Cloudflare R2: `server backups` (account token) | R2 Object Storage → Manage API tokens | `Object Read & Write` on the `infra-backups` bucket only | 2027-09-25 |
| Production server backups token (not in `.env`) | R2 S3 credentials the production server uploads its backups with, as the row above for `server.abrunacci.dev`, stored with `sudo backup-credentials` on `server.epbstock.com.ar`. A token of its own: neither server can read the other's backups | Cloudflare R2: `server.epbstock.com.ar backups` (account token) | R2 Object Storage → Manage API tokens | `Object Read & Write` on the `epb-production-backups` bucket only | 2027-10-31 |
| Production database admin password (not in `.env`) | Password of `doadmin`, the production cluster's admin user, which `project-db` and the backups connect as. Generated by DigitalOcean and kept in the state (`terraform output -raw production_db_password`); on the server, stored with `sudo database-credentials` | DigitalOcean: `epb-production-db`, user `doadmin` | Databases → `epb-production-db` → Users & Databases | The cluster's admin | – (does not expire; reset it in DigitalOcean if it leaks, then run `sudo database-credentials` again) |
| `GATUS_REMOTE_PUSH_SECRET` | The secret each server's status page token is derived from (see `ansible/README.md`, "Status page and alerts"). Generated by you, not by a provider. In `.env`, read by the playbook only | – | – | 64 hex characters | – (does not expire; replace it if it leaks, and run the playbook on every server) |
| GHCR token (not in `.env`) | GitHub personal access token (classic) the server pulls private backend images with. Kept in the password manager and on the server; see `ansible/README.md`, "Pulling private images" | GitHub: `server.abrunacci.dev GHCR pull` (personal access token, classic) | Settings → Developer settings → Personal access tokens → Tokens (classic) | `read:packages` only | 2027-10-05 |
| Production GHCR token (not in `.env`) | The same for the production server (`epb-landing`'s image, and EPB Stock's once it moves there), a token of its own (D18a), so either can be revoked alone. Kept in the password manager and on `server.epbstock.com.ar` only; see `ansible/README.md`, "Pulling private images" | GitHub: `server.epbstock.com.ar GHCR pull` (personal access token, classic) | Settings → Developer settings → Personal access tokens → Tokens (classic) | `read:packages` only | 2027-10-22 |
| Tailscale key of your machine (not in `.env`) | The key your WSL (`alejandro-wsl`) is in the tailnet with, the only way your SSH and the playbook reach the production server (`tailscale.tf`). Kept by Tailscale on your machine. Devices with a tag, such as the production Droplet and the CI machine, never expire | Tailscale: `alejandro-wsl` (machine) | Machines → `alejandro-wsl` | Your user's own access, per the tailnet's policy | 2027-04-20 (every 180 days: renew it by logging in again, `sudo tailscale up --force-reauth` in WSL) |
| EPB Anthropic key (not in `.env`) | Claude API key EPB Stock's import suggestions use (`ANTHROPIC_API_KEY` of `epb-stock`, optional: without it EPB runs without suggestions). Kept in the password manager and on the servers only (`sudo project-secret epb-stock set ANTHROPIC_API_KEY`), production's copy taken from the first server without being shown | Anthropic: `epb-produccion` (API key) | Claude Console → API keys, in EPB's workspace | That workspace only, which has a spending limit | 2027-10-14 |
| Production alerts Resend key (not in `.env`) | Resend API key the production server's log alerts send with, like the first server's alerts key (`ansible/README.md`, "Status page and alerts"). Kept in the password manager and on the server only (`sudo gatus-credentials` on `server.epbstock.com.ar`) | Resend: `server.epbstock.com.ar alerts` (API key) | API Keys | Sending access, domain `mail.abrunacci.dev` only | – (Resend keys don't expire; revoke it in Resend if it leaks) |
| Resend key (not in `.env`) | Resend API key the landing's contact form sends with (`RESEND_API_KEY` of `abrunacci-dev`). Kept in the password manager and on the server only (`sudo project-secret abrunacci-dev set RESEND_API_KEY`) | Resend: `abrunacci-dev-contact` (API key) | API Keys | Sending access, domain `mail.abrunacci.dev` only | – (Resend keys don't expire; revoke it in Resend if it leaks) |
| EPB ARCA test certificate (not in `.env`, homologación) | Certificate and private key EPB Stock's demo signs in to ARCA's test web services with (`ARCA_CERTIFICATE` and `ARCA_PRIVATE_KEY` of `epb-stock`, on `server.abrunacci.dev` only, each one line of base64; optional: without them the demo runs without ARCA). Kept in the password manager and on that server only (`sudo project-secret epb-stock set ARCA_CERTIFICATE`, then the same for `ARCA_PRIVATE_KEY`). Production has none | ARCA: homologación certificate `epbstock` for CUIT 20330367653 (issued by AFIP's `Computadores Test`) | WSASS (Autogestión Certificados Homologación), with Clave Fiscal | Homologación only: it cannot reach ARCA's production services | 2028-10-25 (revoke it in WSASS if the key leaks, then set the new pair with the same two commands) |
| EPB Resend key (not in `.env`) | Resend API key EPB Stock sends its mail with (`RESEND_API_KEY` of `epb-stock`), the same key on both servers: the demo's, copied to `server.epbstock.com.ar` without being shown. Revoking it stops both servers' mail | Resend: EPB Stock's key (API key) | API Keys | Sending access, domain `mail.abrunacci.dev` only | – (Resend keys don't expire; revoke it in Resend if it leaks, then set the new one with `sudo project-secret epb-stock set RESEND_API_KEY` on both servers) |
| EPB landing Resend key (not in `.env`) | Resend API key EPB Stock's landing form sends with (`RESEND_API_KEY` of `epb-landing`). Not in the password manager: on the servers only, copied from the first server to `server.epbstock.com.ar` without being shown (`sudo project-secret epb-landing list` says it is set, never its value), and then removed from the first server | Resend: `epb-landing-contact` (API key) | API Keys | Sending access, domain `mail.abrunacci.dev` only | – (Resend keys don't expire; revoke it in Resend if it leaks, then set a new one with `sudo project-secret epb-landing set RESEND_API_KEY` on `server.epbstock.com.ar`) |

The other variables in `.env` are not credentials:

| Setting | What it is | Notes |
|---|---|---|
| `TF_VAR_cloudflare_zone_ids` | The zone ID of each domain in `../projects.yml` (`domains`), shown on each zone's overview page, as a map: `TF_VAR_cloudflare_zone_ids='{"abrunacci.dev"="<id>"}'` (one `"<domain>"="<id>"` per domain, separated by commas). A missing one fails the plan and names the domain | A variable, so the token needs no `Zone:Read` |
| `TF_VAR_cloudflare_account_id` | Account ID, shown on the same page | Email Routing destination addresses belong to the account |
| `TF_VAR_email_forward_to` | The inbox that receives the domains' mail. It must be outside them | Kept out of the repo, which is public. It is stored in the state |
| `TF_VAR_alert_email` | The address DigitalOcean sends the resource alerts to. It must belong to a verified user of the DigitalOcean team | Same as above |
| `AWS_ENDPOINT_URL_S3` | `https://<account_id>.r2.cloudflarestorage.com` | – |
| `TF_VAR_admin_ssh_public_key` | Your public SSH key | – |

When you create or rotate a token, write its expiration date (not a secret) in "Expires": an expired token fails whatever uses it next (a `terraform apply`, the nightly backup, a pull of a private image), while everything already running keeps running. The playbook reads this table's "Expires" column (the first `YYYY-MM-DD` in it), and the status page's `Server / Credentials` heartbeat fails, and emails you, 14 days before a date. After rotating a token, write its new date here and run `./play site.yml -K --diff --tags gatus`. A row without a date is not watched.

The Cloudflare token needs `SSL and Certificates: Edit` only to keep Universal SSL off, and `Zone Settings: Edit` only to turn Email Routing on. `Zone Settings: Edit` covers every setting of the zone, but nothing is proxied, so almost none of them has any effect. The token still cannot touch any other zone, and on the account it can manage Email Routing destination addresses, Turnstile widgets and the account's settings. Cloudflare's API asks for `Account Settings: Edit` to create a Web Analytics site, and for `Account Settings: Read` to read it back, which every plan does: `Edit` does not include it here, and without `Read` the plan fails with `403 Authentication error` on `cloudflare_web_analytics_site.epb_landing`. No narrower permission does either. Turnstile needs a user token (My Profile → API Tokens): Cloudflare's account-owned tokens do not work with it. It has no R2 permission on purpose: see [`backup-bucket/`](backup-bucket/README.md). The R2 credentials (the state's and the server's) are separate tokens: a leak of one does not expose the others.

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
| `vpc` | create, read, update, delete | The production VPC (`production.tf`). read: every plan. update: its name or description. create and delete: creating it, or a rebuild. Added for EPB Stock's production |
| `database` | create, read, view_credentials, update, delete | The production PostgreSQL cluster and its firewall (`production.tf`). read: every plan, and its CA. view_credentials: reading the cluster's `doadmin` password, which the server's `project-db` uses. update: resizing, the maintenance window, the firewall's rules. create: the first apply. delete: only a deliberate removal, after `prevent_destroy` is removed in a reviewed PR. Added for EPB Stock's production |

When you pick those scopes, the control panel also adds read-only dependencies (read on actions, regions, sizes, image and snapshot; 38 scopes in total with the ones above). Keep them: the provider reads them while creating or resizing the Droplet.

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
- **Proton Mail hosts `epbstock.com.ar`'s mail** (`proton` in `../projects.yml`): it receives and sends `contacto@epbstock.com.ar`, so that domain has Proton's MX, SPF, verification TXT and three DKIM CNAMEs instead of Email Routing. Proton shows the DKIM values (`dkim` in `../projects.yml`) only after it verifies the domain, which needs the TXT published first: a new Proton domain goes in two PRs, the second one adding `dkim`. Each CNAME points at Proton's key, so Proton rotates the keys without any change here.
- **A domain with no mail** (neither `mail_forward` nor `proton`, such as `epbstock.com`) has a null MX (`0 .`) and SPF `v=spf1 -all`: mail sent to it bounces at once, and mail claiming to come from it fails SPF.
- **DMARC `p=reject`.** Only Resend sends mail for `abrunacci.dev` (below), so receivers reject any other message that claims to come from it or a subdomain. Replies go out from the inbox's own address: Gmail's "Send mail as" with an `@abrunacci.dev` address would fail DMARC too.
- **Resend sends the projects' mail from `mail.abrunacci.dev`** (EPB Stock's, for now). Its three records (`send.mail` and `rsend.mail`, CNAMEs to Resend, and the DKIM key in `resend._domainkey.mail`) were created on 2026-09-28 by Resend's Domain Connect flow, then adopted with `import` blocks. They are declared exactly as Resend wrote them (no comment, TTL 1 h, DNS only): a change to any of them breaks sending until Resend verifies the domain again. Mail passes DMARC through the DKIM signature, whose domain `mail.abrunacci.dev` aligns with the root domain's policy.
- **Adopting records created outside Terraform.** The `import` block in `email.tf` runs only when the records' Cloudflare IDs are passed, for that run only: `terraform plan -out=tfplan -var='resend_record_ids={send="<id>",rsend="<id>",dkim="<id>"}'`. The IDs come from the API (the token in `.env` can read them):

  ```sh
  curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/<abrunacci.dev's zone ID>/dns_records?name.endswith=mail.abrunacci.dev" \
    | jq -r '.result[] | [.id, .type, .name, .ttl, .proxied, .content] | @tsv'
  ```

  Once they are in the state, the block does nothing and the variable is no longer passed.
- **The inbox address is in the state.** `email_forward_to` is `sensitive`, so plans hide it, but the state in R2 stores it in plain text.

## Turnstile

The landing's contact form (the `abrunacci-dev` backend in `../projects.yml`) asks Cloudflare Turnstile whether the visitor is a person (`turnstile.tf`). The widget accepts only `abrunacci.dev`, in Managed mode: Cloudflare decides, per visitor, whether a click is needed.

EPB Stock's landing (`epb-landing`) has its own widget, accepting only `epbstock.com.ar`, in Invisible mode: no box is ever shown. Its site key (`terraform output epb_landing_turnstile_site_key`) goes into the landing's build as the repository variable `LANDING_TURNSTILE_SITE_KEY` of EPB_Stock, and its secret key (`terraform output -raw epb_landing_turnstile_secret_key`) is the landing backend's `TURNSTILE_SECRET_KEY`, set with `sudo project-secret epb-landing set TURNSTILE_SECRET_KEY`. The keys below are the first widget's; the state and `prevent_destroy` apply to both.

- **Two keys.** The site key (`terraform output turnstile_site_key`) is public: the page shows the widget with it, and it is `TURNSTILE_SITE_KEY` in `projects.yml`. The secret key (`terraform output -raw turnstile_secret_key`) is how the backend checks each answer; it lives on the server only, set with `sudo project-secret abrunacci-dev set TURNSTILE_SECRET_KEY`. The backend does not start without both.
- **The secret key is in the state.** Terraform stores every attribute of the widget, the secret included, in the state in R2 (`infra-tfstate`). The output is `sensitive`, so plans and `terraform output` hide it, but anyone who can read the state can read the key. That was accepted on 2026-10-06 in exchange for creating the widget as code.
- **Never replaced by mistake.** `prevent_destroy` stops any plan that would destroy the widget. A new widget has new keys, and the form rejects every message until `projects.yml` and the server both have them.
- **The backend calls out.** It checks each answer at `challenges.cloudflare.com:443`. Outbound traffic from the containers is not filtered today; a filter added later must allow it.

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

## GitHub

The protection of `main` in every repository of the account (one ruleset each: pull request only, required CI checks, no deletion or force push) is a separate configuration too, with its own state and its own token, in [`github/`](github/README.md): that token administers the repositories, so it is in `github/.env`, not in this `.env`.

## Safety rails

- **`prevent_destroy`** on the Droplet: it holds the PostgreSQL data, so Terraform refuses any plan that would destroy it while the resource block is in the code: `terraform destroy`, or a change that forces a replacement. Rebuilding on purpose means removing the flag in a reviewed PR and restoring from backup.
  - **Its limit:** the flag lives inside the resource block. If the whole block is deleted, the protection goes with it, and the next plan destroys the Droplet with no error. Renaming the resource (`digitalocean_droplet.server`) without a `moved` block has the same effect.
  - **So every `-` in a plan is reviewed**, and so is every `-/+` (replace). The summary line (`N to destroy`) must be 0 unless the PR says why.
- **`prevent_destroy` in production too:** on the production Droplet (its addresses, its node in the tailnet and the database's firewall point at it) and on the database cluster (destroying it destroys the database and DigitalOcean's backups of it). The same limit applies: deleting or renaming the block drops the flag.
- **The production database is reached from the production Droplet only:** it is in the production VPC, and its firewall (`digitalocean_database_firewall.production`) lists that Droplet and nothing else. The first server is in another VPC and outside that firewall.
- **The production Droplet has no public SSH:** its cloud firewall has no rule for port 22, and it joins Tailscale on its first boot with a one-use key that expires an hour after the apply. The key stays in the state, used and expired, and is never created again. Tailscale's policy (`tailscale.tf`) replaces the tailnet's whole policy file: a change made in the admin panel is undone by the next apply.
- **`ignore_changes = [user_data, ssh_keys, image]`**: these only matter at creation, and changing them would force a new Droplet. After the first boot, Ansible owns the server's configuration.
- **Resizing** (`droplet_size`) keeps the Droplet but powers it off: `graceful_shutdown = true` stops PostgreSQL cleanly, and `resize_disk = false` changes only CPU and RAM, so the Droplet can go back to a smaller size.
- **`projects.yml` is validated**, so a mistake fails instead of being read as zero projects, which would plan the deletion of every project's DNS records:
  - A missing file, invalid YAML, or a missing or empty top-level `domains` or `projects` key fails `terraform validate`. An entry without `subdomain` is an internal project (such as `data-pipeline`): it gets no DNS record.
  - Domains that are invalid, listed twice or under another listed domain, a project whose `domain` is not listed, and a domain without its zone ID in `TF_VAR_cloudflare_zone_ids` fail the plan.
  - Subdomains that are not strings (unquoted `yes`, `true` or `0123`), invalid, duplicated within a domain or reserved (`server`, `status`, `www`) fail the plan. `"@"` is the domain itself; with `site: true` it adds `www`, which redirects to it. A `redirect_from` that is not a domain in `domains` or a name under one fails the plan too.
  - A registry with no project that has a subdomain fails the plan too, unless it is allowed on purpose, for that run only: `terraform plan -out=tfplan -var=allow_zero_projects=true`. Never put it in `.env`: the guard would stay off without anyone noticing. That also covers a key repeated in the file, such as a second `projects: []` left by a bad merge: YAML keeps the last one.
  - yamllint also rejects repeated keys (`key-duplicates`) in pre-commit and CI. A repeated key that still leaves some projects, or a repeated `subdomain`, is caught only there, so run `pre-commit run --all-files` before a local plan.
- **`proxied = false`** is set explicitly on every record, so the Cloudflare proxy cannot be turned on by accident (see the DNS decision in the main README).
- **No IP addresses are committed.** Ansible and SSH use each server's name (`server.abrunacci.dev`, `server.epbstock.com.ar`) from your own inventory; for the production server, with the Droplet's name in Tailscale (`production_droplet`) as `ansible_host`.

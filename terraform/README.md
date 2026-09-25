# Terraform

Creates everything the platform needs in DigitalOcean and Cloudflare:

| Resource | File |
|---|---|
| Droplet (`s-1vcpu-2gb`, `nyc3`, Ubuntu 24.04, IPv6, minimal cloud-init) | `main.tf` |
| Admin SSH key, tags and a DigitalOcean project that groups the resources | `main.tf` |
| Cloud firewall: inbound TCP 22, 80 and 443, UDP 443 for HTTP/3, and ICMP/ICMPv6 | `firewall.tf` |
| A/AAAA records for `server`, `status` and each project in `../projects.yml`: the root domain for a project on `"@"`, plus `www` | `dns.tf` |
| CAA records that allow only Let's Encrypt and ZeroSSL | `dns.tf` |
| Universal SSL turned off, so Cloudflare adds no CAA records of its own | `dns.tf` |
| Email Routing: `hello@`, `postmaster@` and `abuse@` forwarded to one inbox, every other address rejected | `email.tf` |
| DMARC `p=reject`: the domain sends no mail | `email.tf` |

## Credentials

Nothing secret is stored in files that are committed. Every credential comes from the environment; `.env.example` lists them.

| Variable | What it is | Minimum scope |
|---|---|---|
| `DIGITALOCEAN_TOKEN` | DigitalOcean API token | Custom scopes: droplet, firewall, ssh_key, tag, project. The control panel adds read-only dependencies (actions, regions, sizes, image, vpc); keep them, the provider needs them while creating the Droplet |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token | On the `abrunacci.dev` zone only: `Zone → DNS → Edit`, `Zone → SSL and Certificates → Edit`, `Zone → Email Routing Rules → Edit` and `Zone → Zone Settings → Edit`. On this account only: `Account → Email Routing Addresses → Edit` |
| `TF_VAR_cloudflare_zone_id` | Zone ID, shown on the zone's overview page | A variable, so the token needs no `Zone:Read` |
| `TF_VAR_cloudflare_account_id` | Account ID, shown on the same page | Email Routing destination addresses belong to the account |
| `TF_VAR_email_forward_to` | The inbox that receives the domain's mail | Not a credential, but kept out of the repo, which is public. It is stored in the state |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | R2 S3 credentials for the state bucket | `Object Read & Write` on `infra-tfstate` only |
| `AWS_ENDPOINT_URL_S3` | `https://<account_id>.r2.cloudflarestorage.com` | – |
| `TF_VAR_admin_ssh_public_key` | Your public SSH key | – |

The Cloudflare token needs `SSL and Certificates: Edit` only to keep Universal SSL off, and `Zone Settings: Edit` only to turn Email Routing on. `Zone Settings: Edit` covers every setting of the zone, but nothing is proxied, so almost none of them has any effect. The token still cannot touch any other zone, and on the account it can only manage Email Routing destination addresses. The R2 credentials are a separate token: a leak of either one does not expose the other.

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
- **DMARC `p=reject`.** The domain sends no mail, so receivers reject any message that claims to come from it. Replies go out from the inbox's own address: Gmail's "Send mail as" with an `@abrunacci.dev` address would fail DMARC too.
- **The inbox address is in the state.** `email_forward_to` is `sensitive`, so plans hide it, but the state in R2 stores it in plain text.

## After the first apply

Check that ICMPv6 passes the cloud firewall. DigitalOcean's docs do not state it explicitly, so it is verified once from a host with IPv6:

```sh
ping -6 -c3 server.abrunacci.dev
tracepath -6 server.abrunacci.dev   # should report the path MTU without stalling
```

## Safety rails

- **`prevent_destroy`** on the Droplet: it holds the PostgreSQL data, so Terraform refuses any plan that would destroy it while the resource block is in the code: `terraform destroy`, or a change that forces a replacement. Rebuilding on purpose means removing the flag in a reviewed PR and restoring from backup.
  - **Its limit:** the flag lives inside the resource block. If the whole block is deleted, the protection goes with it, and the next plan destroys the Droplet with no error. Renaming the resource (`digitalocean_droplet.server`) without a `moved` block has the same effect.
  - **So every `-` in a plan is reviewed**, and so is every `-/+` (replace). The summary line (`N to destroy`) must be 0 unless the PR says why.
- **`ignore_changes = [user_data, ssh_keys, image]`**: these only matter at creation, and changing them would force a new Droplet. After the first boot, Ansible owns the server's configuration.
- **Resizing** (`droplet_size`) keeps the Droplet but powers it off: `graceful_shutdown = true` stops PostgreSQL cleanly, and `resize_disk = false` changes only CPU and RAM, so the Droplet can go back to a smaller size.
- **`projects.yml` is validated**, so a mistake fails instead of being read as zero projects, which would plan the deletion of every project's DNS records:
  - A missing file, invalid YAML, a missing or empty top-level `projects` key, or an entry without `subdomain` fails `terraform validate`.
  - Subdomains that are not strings (unquoted `yes`, `true` or `0123`), invalid, duplicated or reserved (`server`, `status`, `www`) fail the plan. `"@"` is the root domain; with `site: true` it adds `www`, which redirects to it.
  - A registry with no projects fails the plan too, unless it is allowed on purpose, for that run only: `terraform plan -out=tfplan -var=allow_zero_projects=true`. Never put it in `.env`: the guard would stay off without anyone noticing. That also covers a key repeated in the file, such as a second `projects: []` left by a bad merge: YAML keeps the last one.
  - yamllint also rejects repeated keys (`key-duplicates`) in pre-commit and CI. A repeated key that still leaves some projects, or a repeated `subdomain`, is caught only there, so run `pre-commit run --all-files` before a local plan.
- **`proxied = false`** is set explicitly on every record, so the Cloudflare proxy cannot be turned on by accident (see the DNS decision in the main README).
- **No IP addresses are committed.** Ansible and SSH use `server.abrunacci.dev`.

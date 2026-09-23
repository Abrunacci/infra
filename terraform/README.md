# Terraform

Creates everything the platform needs in DigitalOcean and Cloudflare:

| Resource | File |
|---|---|
| Droplet (`s-1vcpu-2gb`, `nyc3`, Ubuntu 24.04, IPv6, minimal cloud-init) | `main.tf` |
| Admin SSH key, tags and a DigitalOcean project that groups the resources | `main.tf` |
| Cloud firewall: inbound TCP 22, 80 and 443, plus UDP 443 for HTTP/3 | `firewall.tf` |
| A/AAAA records for `server`, `status` and each project in `../projects.yml` | `dns.tf` |
| CAA records that allow only Let's Encrypt and ZeroSSL | `dns.tf` |

## Credentials

Nothing secret is stored in files that are committed. Every credential comes from the environment; `.env.example` lists them.

| Variable | What it is | Minimum scope |
|---|---|---|
| `DIGITALOCEAN_TOKEN` | DigitalOcean API token | Custom scopes: droplet, firewall, ssh_key, tag, project |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token for DNS | `Zone → DNS → Edit`, on the `abrunacci.dev` zone only |
| `TF_VAR_cloudflare_zone_id` | Zone ID, shown on the zone's overview page | A variable, so the token needs no `Zone:Read` |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | R2 S3 credentials for the state bucket | `Object Read & Write` on `infra-tfstate` only |
| `AWS_ENDPOINT_URL_S3` | `https://<account_id>.r2.cloudflarestorage.com` | – |
| `TF_VAR_admin_ssh_public_key` | Your public SSH key | – |

The R2 credentials are a separate token from the DNS one: a leak of either one does not expose the other.

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

## Safety rails

- **`prevent_destroy`** on the Droplet: it holds the PostgreSQL data, so Terraform refuses to destroy it. Rebuilding on purpose means removing the flag in a reviewed PR and restoring from backup.
- **`ignore_changes = [user_data, ssh_keys, image]`**: these only matter at creation, and changing them would force a new Droplet. After the first boot, Ansible owns the server's configuration.
- **`proxied = false`** is set explicitly on every record, so the Cloudflare proxy cannot be turned on by accident (see the DNS decision in the main README).
- **No IP addresses are committed.** Ansible and SSH use `server.abrunacci.dev`.

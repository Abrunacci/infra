# Terraform

Creates everything the platform needs in DigitalOcean and Cloudflare:

| Resource | File |
|---|---|
| Droplet (`s-1vcpu-2gb`, `nyc3`, Ubuntu 24.04, IPv6, minimal cloud-init) | `main.tf` |
| Admin SSH key, tags and a DigitalOcean project that groups the resources | `main.tf` |
| Cloud firewall: inbound TCP 22, 80 and 443, UDP 443 for HTTP/3, and ICMP/ICMPv6 | `firewall.tf` |
| A/AAAA records for `server`, `status` and each project in `../projects.yml` | `dns.tf` |
| CAA records that allow only Let's Encrypt and ZeroSSL | `dns.tf` |
| Universal SSL turned off, so Cloudflare adds no CAA records of its own | `dns.tf` |

## Credentials

Nothing secret is stored in files that are committed. Every credential comes from the environment; `.env.example` lists them.

| Variable | What it is | Minimum scope |
|---|---|---|
| `DIGITALOCEAN_TOKEN` | DigitalOcean API token | Custom scopes: droplet, firewall, ssh_key, tag, project. The control panel adds read-only dependencies (actions, regions, sizes, image, vpc); keep them, the provider needs them while creating the Droplet |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token | `Zone → DNS → Edit` and `Zone → SSL and Certificates → Edit`, both on the `abrunacci.dev` zone only |
| `TF_VAR_cloudflare_zone_id` | Zone ID, shown on the zone's overview page | A variable, so the token needs no `Zone:Read` |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | R2 S3 credentials for the state bucket | `Object Read & Write` on `infra-tfstate` only |
| `AWS_ENDPOINT_URL_S3` | `https://<account_id>.r2.cloudflarestorage.com` | – |
| `TF_VAR_admin_ssh_public_key` | Your public SSH key | – |

The Cloudflare token needs `SSL and Certificates: Edit` only to keep Universal SSL off; it still cannot touch any other zone or account setting. The R2 credentials are a separate token: a leak of either one does not expose the other.

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
- **Resizing** (`droplet_size`) keeps the Droplet but powers it off: `graceful_shutdown = true` stops PostgreSQL cleanly, and `resize_disk = false` changes only CPU and RAM, so the Droplet can go back to a smaller size.
- **`projects.yml` is validated**: invalid, duplicated or reserved (`server`, `status`) subdomains fail the plan.
- **`proxied = false`** is set explicitly on every record, so the Cloudflare proxy cannot be turned on by accident (see the DNS decision in the main README).
- **No IP addresses are committed.** Ansible and SSH use `server.abrunacci.dev`.

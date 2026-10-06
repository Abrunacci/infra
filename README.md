# infra

Infrastructure for my portfolio projects: one DigitalOcean Droplet, Docker Compose, Caddy and a shared PostgreSQL.

| Directory | What it holds |
|---|---|
| [`terraform/`](terraform/README.md) | The Droplet, cloud firewall, DNS records and mail forwarding. The backups bucket is a configuration of its own, in [`terraform/backup-bucket/`](terraform/backup-bucket/README.md) |
| [`ansible/`](ansible/README.md) | Server configuration: hardening, Docker, Caddy, PostgreSQL, backups and the status page |
| [`.github/actions/check-commit-metadata/`](.github/actions/check-commit-metadata/README.md) | The "Check commit metadata" step every repository's CI runs: who may author the commits of a pull request and what their messages may carry |
| `projects.yml` | Registry of deployed projects: what each one has (a static site, a backend, a database). Checked against `projects.schema.json` |

Work in progress.

## Design decisions

### DNS in Cloudflare, "DNS only" (no proxy)

The domain is registered with Cloudflare Registrar, which requires Cloudflare's nameservers, so DNS is managed there with Terraform's Cloudflare provider. Every record is **DNS only** (`proxied = false`, set explicitly in Terraform):

- **Caddy manages TLS end to end.** Traffic goes straight to the Droplet, so Caddy gets and renews certificates from Let's Encrypt (falling back to ZeroSSL) through the HTTP-01 or TLS-ALPN-01 challenge. There is no second TLS layer to configure, and no Cloudflare SSL mode to get wrong.
- **Fewer moving parts.** With the proxy on, the zone's SSL mode must be "Full (strict)" or requests loop, TLS-ALPN-01 stops working, and caching and WAF rules start affecting the apps. None of that applies here.
- **Trade-off: the Droplet's IP is public.** Anyone can resolve it, and there is no Cloudflare DDoS protection or WAF in front. For a handful of small portfolio apps this is acceptable. The exposure is kept small instead: the cloud firewall and the host firewall allow only SSH, HTTP(S) and ICMP (see below), SSH accepts keys only, root cannot log in, and sudo asks for a password. If a project ever needs DDoS protection, proxying its record also requires turning Universal SSL back on (or an advanced certificate), adding Cloudflare's CAs to the CAA records, and setting the zone to Full (strict). Without an edge certificate, proxying breaks HTTPS for that host.
- **CAA records** allow Let's Encrypt and ZeroSSL (`sectigo.com`), the CAs Caddy uses, to issue certificates for the domain, and forbid wildcards. Terraform also turns Cloudflare's Universal SSL off: nothing is proxied, so it is unused, and while it is on, Cloudflare publishes hidden CAA records for its own CAs, wildcards included, which would defeat these.
- **Least-privilege tokens.** The Cloudflare token can edit DNS records, SSL, Email Routing and zone settings, only in this zone, plus Email Routing destination addresses in the account. The SSL permission exists solely to keep Universal SSL off, and the zone settings one to turn Email Routing on. The zone ID is passed as a variable, so the token does not need `Zone:Read`. The R2 credentials for the Terraform state and for the server's backups are separate tokens, each limited to its own bucket. The one token that can administer R2 (the backups bucket's lock and lifecycle, in [`terraform/backup-bucket/`](terraform/backup-bucket/README.md)) is not stored anywhere on disk and is typed in only for that configuration's runs.

### Firewall: SSH, HTTP(S) and ICMP only

Inbound traffic is limited to TCP 22 (SSH), TCP 80 and 443 (HTTP and HTTPS) and UDP 443 (HTTP/3, which Caddy serves by default). The cloud firewall drops everything else before it reaches the Droplet.

ICMP and ICMPv6 are the one deliberate exception:

- **IPv6 depends on ICMPv6.** Path MTU discovery relies on "Packet Too Big" messages. If they are blocked, large responses over IPv6 can hang with no error.
- **Diagnostics.** `ping` and `traceroute` are the first tools to tell whether the network or a service is failing.
- **Low risk.** ICMP opens no port and exposes no service, and the kernel rate-limits its replies.

### No DigitalOcean Droplet backups

DigitalOcean's Droplet backups (whole-disk images, +20% of the Droplet price) are turned off on purpose, because they would back up nothing that is not already covered elsewhere:

- **The server is rebuilt from this repo.** Terraform creates it and Ansible configures it, so a new Droplet is always one `apply` and one playbook run away. Nothing on the disk is configured by hand, except the admin's sudo password, which is typed on the server so it is never in the repo.
- **The data is backed up on its own.** Every day at 03:30 UTC, each project's database, the roles its migrations created and the projects' secrets go to Cloudflare R2, encrypted with [age](https://age-encryption.org) to a public key whose private half is never on the server. Retention is 7 daily, 4 weekly and 6 monthly copies, and a bucket lock keeps the server itself from deleting them. They are stored with a different provider, so they survive the loss of the DigitalOcean account, and a single database can be restored without rolling back the whole disk. See `ansible/README.md`, "Backups", for the restore procedure and the monthly restore drill.

## Development

Every commit runs the same checks as CI: secret scanning (gitleaks), `terraform fmt`/`validate`, tflint, yamllint, a JSON Schema check of `projects.yml`, ansible-lint (production profile), shellcheck, ruff (the Python scripts), actionlint and, in CI only, a Trivy config scan.

Requirements: Python 3, Terraform 1.16, TFLint 0.64 and, to run the playbook, ansible-core 2.21. The other tools are installed by pre-commit itself.

```sh
pip install pre-commit==4.6.2   # same version as CI
pre-commit install
pre-commit run --all-files
```

## Updates

Everything this repository pins (the server's images by tag and digest, Docker Engine's packages, Terraform's providers, Ansible's collections, the actions, pre-commit's hooks and the tools in CI) gets a pull request from [Renovate](https://docs.renovatebot.com/) when a new version is out. Its configuration is `renovate.json`.

- **Once a week,** before 09:00 on Monday (Buenos Aires time), and only for versions at least 3 days old, so a release pulled back right away never reaches a pull request.
- **Grouped by what a merge changes:** `server images` (Caddy, Gatus, PostgreSQL, rclone and socat), `Docker Engine` (its three packages together), `Terraform providers`, `Ansible collections`, and `CI and tools`. A major version gets its own pull request. The issue "Dependency Dashboard" lists what is pending.
- **Not PostgreSQL's major versions:** going from 17 to 18 is a dump and restore, not a bump, so Renovate never proposes it. Minor versions and new digests of 17 still come.
- **gitleaks' binary** gets its own pull request: its checksum (`GITLEAKS_SHA256` in `.github/workflows/ci.yml`) has to be updated by hand, and the secret scan fails until it is.
- **Merging is not applying.** An image or Docker Engine reaches the server on the next playbook run; a provider, on the next `terraform init -upgrade` and `plan`.

## Security scan

[Trivy](https://trivy.dev) looks for known vulnerabilities and risky settings, from its image pinned by digest (`TRIVY_IMAGE`, updated by Renovate).

- **The server's images, once a week:** `.github/workflows/security-scan.yml` scans every `*_image` in the roles' defaults on Monday at 09:00 (Buenos Aires time), after Renovate's pull requests, and on pull requests that change an image. Run it by hand from Actions → Security scan → Run workflow. Only vulnerabilities with a fix count. The job summary lists every HIGH and CRITICAL one; a CRITICAL one fails the run, so GitHub emails you. HIGH ones usually go away with the next `server images` pull request.
- **The configuration, on every pull request:** the CI job "Config scan (trivy)" checks Terraform and the Dockerfiles for MEDIUM and higher. The compose files are Jinja templates, which Trivy cannot read.
- **Accepted findings** go in `.trivyignore.yaml`, each with why and the paths it applies to. A vulnerability is accepted only until its `expired_at`: after that date it fails the scan again, and gets fixed or looked at once more.

When the weekly scan fails: open its summary, update the image (merge its pending pull request, or let Renovate bring a new digest of the same tag), or, if the vulnerability cannot be reached on this server, add it to `.trivyignore.yaml` with a reason and an `expired_at` a month out.

# infra

Infrastructure for my portfolio projects: one DigitalOcean Droplet, Docker Compose, Caddy and a shared PostgreSQL.

Work in progress.

## Design decisions

### DNS in Cloudflare, "DNS only" (no proxy)

The domain is registered with Cloudflare Registrar, which requires Cloudflare's nameservers, so DNS is managed there with Terraform's Cloudflare provider. Every record is **DNS only** (`proxied = false`, set explicitly in Terraform):

- **Caddy manages TLS end to end.** Traffic goes straight to the Droplet, so Caddy gets and renews certificates from Let's Encrypt (falling back to ZeroSSL) through the HTTP-01 or TLS-ALPN-01 challenge. There is no second TLS layer to configure, and no Cloudflare SSL mode to get wrong.
- **Fewer moving parts.** With the proxy on, the zone's SSL mode must be "Full (strict)" or requests loop, TLS-ALPN-01 stops working, and caching and WAF rules start affecting the apps. None of that applies here.
- **Trade-off: the Droplet's IP is public.** Anyone can resolve it, and there is no Cloudflare DDoS protection or WAF in front. For a handful of small portfolio apps this is acceptable. The exposure is kept small instead: the cloud firewall and the host firewall allow only SSH and HTTP(S), SSH accepts keys only, and root cannot log in. If a project ever needs DDoS protection, its record can be proxied, together with Full (strict).
- **CAA records** allow Let's Encrypt and ZeroSSL (`sectigo.com`), the CAs Caddy uses, to issue certificates for the domain, and forbid wildcards. While Cloudflare's Universal SSL is enabled on the zone, Cloudflare also publishes CAA records for its own CAs; turning Universal SSL off (nothing is proxied, so it is unused) makes these records the only ones.
- **Least-privilege tokens.** The DNS token can only edit DNS records in this zone. The zone ID is passed as a variable, so the token does not need `Zone:Read`. The R2 credentials for the Terraform state are a separate token, limited to the state bucket.

## Development

Every commit runs the same checks as CI: secret scanning (gitleaks), `terraform fmt`/`validate`, tflint, yamllint, shellcheck and actionlint.

Requirements: Python 3, Terraform 1.16 and TFLint 0.64. The other tools are installed by pre-commit itself.

```sh
pip install pre-commit==4.6.2   # same version as CI
pre-commit install
pre-commit run --all-files
```

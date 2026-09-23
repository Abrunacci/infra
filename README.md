# infra

Infrastructure for my portfolio projects: one DigitalOcean Droplet, Docker Compose, Caddy and a shared PostgreSQL.

Work in progress.

## Development

Every commit runs the same checks as CI: secret scanning (gitleaks), `terraform fmt`, yamllint, shellcheck and actionlint.

Requirements: Python 3 and Terraform 1.16 (for `terraform fmt`). The other tools are installed by pre-commit itself.

```sh
pip install pre-commit==4.6.2   # same version as CI
pre-commit install
pre-commit run --all-files
```

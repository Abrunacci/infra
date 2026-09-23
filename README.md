# infra

Infrastructure for my portfolio projects: one DigitalOcean Droplet, Docker Compose, Caddy and a shared PostgreSQL.

Work in progress.

## Development

Every commit runs the same checks as CI: secret scanning (gitleaks), `terraform fmt`, yamllint and shellcheck.

```sh
pip install pre-commit   # or pipx install pre-commit
pre-commit install
pre-commit run --all-files
```

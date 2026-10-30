# managed-database

Checks, without touching any server or cluster, that each server's files
follow where its databases are (`database` in `projects.yml`, servers):

- **A server whose database is local** (demo, `server.abrunacci.dev`) never
  names the managed cluster (D21): no file holds its host, its ports (25060,
  25061), its CA, its admin user, `db-egress` or `sslmode=verify-full`, and
  its networks are still `db`.
- **The managed server** (`server.epbstock.com.ar`) names the cluster in
  `database.conf` and nothing of the local PostgreSQL. Its backends join no
  `db-<name>` network, their migrations run on `db-egress` only, with the
  cluster's address and CA.
- **Across servers:** each one sets up exactly the projects whose `server`
  is it (the first one, for a project without `server`), and their backends.
  Each one has its own backups bucket, SSH's ufw rules match its `ssh`
  (`on tailscale0` for `ssh: tailscale`), only the first one serves the
  status page, and Gatus waits for, and Caddy lets through, every other
  server's pushes. Each backend's migrations read only the public env, their
  database connection and, with `migrate_secrets`, `secrets-migrate.env`.

`render.yml` renders those files from the roles' own templates and variables,
with a made-up cluster in place of Terraform's `production_database` output.
`check.py` compares them and lists every
difference.

CI runs it on every pull request ("Test (managed database)"). Locally, from the
repo root:

```sh
python3 -m venv /tmp/managed-database
/tmp/managed-database/bin/pip install -r tests/managed-database/requirements.txt
PATH="/tmp/managed-database/bin:$PATH" PYTHON=/tmp/managed-database/bin/python tests/managed-database/ci.sh
```

It prints `ok: N servers; only the managed one names its cluster`, or each
problem and exits 1.

What it cannot see: anything that needs the real cluster or server (the pool,
the admin's permissions, TLS, the firewall rules being loaded). Those are
checked by hand after the playbook runs (the pull request's guide).

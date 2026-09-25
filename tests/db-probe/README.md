# db-probe

A tiny backend used only to test per-project databases on the server
(ansible/README.md, "Deploying a backend"): a health check, one endpoint
that writes to the database, and numbered SQL migrations. It follows the
same contract as a real project: `DATABASE_URL` to serve, and
`MIGRATION_DATABASE_URL` plus `APP_DB_USER` to migrate.

The workflow `.github/workflows/db-probe.yml` (run by hand) publishes three
tags to `ghcr.io/abrunacci/infra-db-probe`:

| Tag | Migrations | Use |
|---|---|---|
| `v1` | 001: creates `visits` and grants it to the app role | first deploy |
| `v2` | 001, 002: adds a column with a default (compatible with v1) | second deploy, then roll back to v1 |
| `v3` | 001, 002, 003: fails on purpose | a migration that fails: v2 keeps serving |

Endpoints (port 8080):

- `GET /api/health`: `ok` if the database answers `SELECT 1`.
- `GET /api/visits`: records a visit and returns the image version, the
  number of visits and the columns of `visits`, as JSON.

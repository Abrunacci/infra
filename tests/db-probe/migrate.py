"""Applies the pending migrations in migrations/, in order, in one transaction.

Connects as the schema owner (MIGRATION_DATABASE_URL). {app_user} in a
migration is replaced by APP_DB_USER, quoted as an identifier. Applied
migrations are recorded in schema_migrations.
"""

import os
import pathlib
import sys

import psycopg
from psycopg import sql


def main():
    app_user = os.environ["APP_DB_USER"]
    files = sorted(pathlib.Path(__file__).with_name("migrations").glob("*.sql"))
    with psycopg.connect(os.environ["MIGRATION_DATABASE_URL"]) as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, at timestamptz DEFAULT now())"
        )
        done = {row[0] for row in conn.execute("SELECT name FROM schema_migrations")}
        for path in files:
            if path.name in done:
                continue
            print(f"applying {path.name}", flush=True)
            text = path.read_text().replace("{app_user}", sql.Identifier(app_user).as_string(conn))
            conn.execute(text)
            conn.execute("INSERT INTO schema_migrations (name) VALUES (%s)", (path.name,))
    print(f"up to date: {len(files)} migrations", flush=True)


if __name__ == "__main__":
    try:
        main()
    except psycopg.Error as e:
        print(f"migration failed: {e}", file=sys.stderr)
        sys.exit(1)

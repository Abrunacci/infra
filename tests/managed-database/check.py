"""Checks the files render.yml wrote for every server (out_dir/<server>/).

Demo never touches the managed database (D21): no file of a server whose
database is local names the cluster, its ports, its CA, its admin user, its
client network or another server's bucket. The managed server's files do
all of that instead, and nothing of the local PostgreSQL. Each server sets
up only its own projects. Exits 1 on any difference, listing them.

    python3 check.py OUT_DIR PROJECTS_YML
"""

import json
import pathlib
import re
import sys

import yaml

MANAGED_HOST = "private-stand-in-cluster-do-user-0-0.k.db.ondigitalocean.com"
# What only a managed server's files may hold.
MANAGED_MARKERS = [
    MANAGED_HOST,
    "stand-in-cluster",
    ":25060",
    ":25061",
    "25061",
    "DATABASE_MODE=managed",
    "database-ca",
    "db-egress",
    "doadmin",
    "sslmode=verify-full",
]


def files(directory):
    return sorted(p for p in directory.rglob("*") if p.is_file())


def check(out, registry):
    problems = []
    servers = registry["servers"]
    first = servers[0]["name"]
    managed = [s["name"] for s in servers if s.get("database", "local") == "managed"]
    buckets = {}
    for server in servers:
        name = server["name"]
        directory = out / name
        facts = json.loads((directory / "facts.json").read_text())
        is_managed = server.get("database", "local") == "managed"
        if facts["database_managed"] != is_managed:
            problems.append(f"{name}: database_managed is {facts['database_managed']}, expected {is_managed}")
        buckets[name] = facts["backup_bucket"]
        # Each server sets up only its own projects (a project's server
        # defaults to the first one) and their backends. render.yml's stand-in
        # (subdomain stand-in) is not in projects.yml.
        registered = json.loads((directory / "projects.json").read_text())["projects"]
        stand_ins = {p["name"] for p in registered if p["subdomain"] == "stand-in"}
        own = [p for p in registry["projects"] if p.get("server", first) == name]
        expected = sorted(p["name"] for p in own)
        found = sorted(p["name"] for p in registered if p["name"] not in stand_ins)
        if found != expected:
            problems.append(f"{name}: projects.json lists {found}, expected {expected}")
        expected = sorted(p["name"] for p in own if "backend" in p)
        found = sorted(
            c.name.removesuffix(".compose.yml")
            for c in (directory / "projects").glob("*.compose.yml")
            if c.name.removesuffix(".compose.yml") not in stand_ins
        )
        if found != expected:
            problems.append(f"{name}: backends rendered {found}, expected {expected}")
        conf = (directory / "database.conf").read_text()
        composes = list((directory / "projects").glob("*.compose.yml"))
        if not is_managed:
            for path in files(directory):
                text = path.read_text()
                for marker in MANAGED_MARKERS:
                    if marker in text:
                        problems.append(f"{name}: {path.relative_to(out)} names the managed database ({marker})")
            if "DATABASE_MODE=local" not in conf:
                problems.append(f"{name}: database.conf is not local")
            if "db" not in facts["docker_networks"] or "db-egress" in facts["docker_networks"]:
                problems.append(f"{name}: networks {facts['docker_networks']}, expected db and not db-egress")
        else:
            if "DATABASE_MODE=managed" not in conf or MANAGED_HOST not in conf:
                problems.append(f"{name}: database.conf does not name the managed cluster")
            if "POSTGRES_COMPOSE_PROJECT" in conf:
                problems.append(f"{name}: database.conf names the local PostgreSQL")
            if "db-egress" not in facts["docker_networks"] or "db" in facts["docker_networks"]:
                problems.append(f"{name}: networks {facts['docker_networks']}, expected db-egress and not db")
            if facts["database_networks"]:
                problems.append(f"{name}: database networks {facts['database_networks']}, expected none")
            with_database = [c for c in composes if "database-app.env" in c.read_text()]
            if not with_database:
                problems.append(f"{name}: no backend with a database was rendered")
            for path in with_database:
                compose = yaml.safe_load(path.read_text())
                nets = {k: v.get("name") for k, v in (compose.get("networks") or {}).items()}
                if any((v or "").startswith("db-") and v != "db-egress" for v in nets.values()):
                    problems.append(f"{name}: {path.name} joins a local database network: {nets}")
                migrate = compose["services"].get("migrate")
                if migrate and (migrate.get("networks") != ["egress"] or nets.get("egress") != "db-egress"):
                    problems.append(f"{name}: {path.name}'s migrations are not on db-egress only")
                if migrate and not any(h.startswith(MANAGED_HOST + "=") for h in migrate.get("extra_hosts", [])):
                    problems.append(f"{name}: {path.name}'s migrations do not get the cluster's address")
                for service, spec in compose["services"].items():
                    if not any("database-ca.crt" in v for v in spec.get("volumes", [])):
                        problems.append(f"{name}: {path.name}'s {service} does not get the cluster's CA")
        # Every server's security check reads its own expectations.
        posture = json.loads((directory / "gatus" / "server-posture.json").read_text())
        if posture["tailscale"] != (server.get("ssh", "public") == "tailscale"):
            problems.append(f"{name}: server-posture.json's tailscale is {posture['tailscale']}")
        ssh = [r for r in posture["ufw"] if r.startswith("22/")]
        expected_ssh = ["22/tcp on tailscale0"] if server.get("ssh", "public") == "tailscale" else ["22/tcp"]
        if ssh != expected_ssh:
            problems.append(f"{name}: SSH's ufw rules are {ssh}, expected {expected_ssh}")
        caddyfile = (directory / "Caddyfile").read_text()
        has_status = re.search(r"^status\.\S+ \{", caddyfile, re.MULTILINE) is not None
        if has_status != (name == first):
            problems.append(f"{name}: the status page is {'' if has_status else 'not '}served here")
        if name != first and not facts["gatus_push_url"].startswith("https://status."):
            problems.append(f"{name}: pushes to {facts['gatus_push_url']}, expected the status page")
    if len(set(buckets.values())) != len(buckets):
        problems.append(f"two servers share a backups bucket: {buckets}")
    # The first server's Gatus waits for every other server with its token,
    # and its status page lets only their pushes through.
    config = yaml.safe_load((out / first / "gatus" / "config.yaml").read_text())
    for server in servers[1:]:
        var = "${GATUS_PUSH_TOKEN_" + re.sub("[^A-Z0-9]", "_", server["name"].upper()) + "}"
        if not any(e["token"] == var for e in config["external-endpoints"]):
            problems.append(f"{first}: Gatus does not wait for {server['name']}'s heartbeats ({var})")
        slug = re.sub(r"[/_.,# +&]", "-", server["name"])
        if slug not in (out / first / "Caddyfile").read_text():
            problems.append(f"{first}: the status page does not let {server['name']}'s pushes through")
    if len(managed) > 1:
        problems.append(f"more than one managed server: {managed}")
    return problems


def main():
    out, registry = pathlib.Path(sys.argv[1]), yaml.safe_load(pathlib.Path(sys.argv[2]).read_text())
    problems = check(out, registry)
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        sys.exit(1)
    print(f"ok: {len(registry['servers'])} servers; only the managed one names its cluster")


if __name__ == "__main__":
    main()

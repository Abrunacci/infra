#!/usr/bin/env python3
"""Checks the server from outside, the way anyone on the internet sees it.

    outside-check.py expected   print what is expected, read from the repo
    outside-check.py run        check it and report to healthchecks.io

Run weekly by .github/workflows/outside-check.yml. What is expected comes from
the repo, so a new project needs no change here:

- open ports: the tcp and udp inbound rules of terraform/firewall.tf;
- sites: every subdomain in projects.yml, plus status (roles/caddy) and www
  when the root domain has a site;
- private paths: each backend's private_paths in projects.yml;
- CAA records: terraform/dns.tf; the DS record: the DNSSEC_DS variable.

The repo is public, and so are this job's log and summary: they never say
what differs, only that the result went to healthchecks.io. The differences
go in the body of a failure ping (OUTSIDE_CHECK_PING_URL + /fail), which only
shows in healthchecks.io's dashboard and its email. A run that checked
everything exits 0 whatever it found; it exits 1 only when the check itself
could not run.
"""

import http.client
import json
import os
import pathlib
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import traceback
import urllib.request
import xml.etree.ElementTree as ET

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
TIMEOUT = 20
# Caddy answers these for a private path (respond 404), or 405 for a method
# the site does not take: either way the request never reached the backend.
PRIVATE_PATH_OK = {404, 405}
TLS_PROTOCOLS_OK = {"TLSv1.2", "TLSv1.3"}


def terraform_string(name, text):
    match = re.search(r'variable "' + name + r'"\s*\{[^}]*?default\s*=\s*"([^"]+)"', text, re.DOTALL)
    if not match:
        raise ValueError(f"no default for variable {name} in terraform/variables.tf")
    return match.group(1)


def firewall_ports(text):
    """The tcp and udp inbound rules, as {"tcp": {22, ...}, "udp": {...}}."""
    ports = {"tcp": set(), "udp": set()}
    for block in re.findall(r"inbound_rule\s*\{(.*?)\}", text, re.DOTALL):
        protocol = re.search(r'protocol\s*=\s*"(\w+)"', block)
        port = re.search(r'port_range\s*=\s*"(\d+)"', block)
        if protocol and protocol.group(1) in ports:
            if not port:
                raise ValueError("an inbound rule in terraform/firewall.tf has no single port")
            ports[protocol.group(1)].add(int(port.group(1)))
    if not ports["tcp"]:
        raise ValueError("no tcp inbound rules in terraform/firewall.tf")
    return ports


def caa_records(text):
    block = re.search(r"caa_records\s*=\s*\{(.*?)\n\s*\}", text, re.DOTALL)
    if not block:
        raise ValueError("no caa_records in terraform/dns.tf")
    records = {
        f'0 {tag} "{value}"'
        for tag, value in re.findall(r'tag\s*=\s*"([^"]+)",\s*value\s*=\s*"([^"]*)"', block.group(1))
    }
    if not records:
        raise ValueError("caa_records in terraform/dns.tf is empty")
    return records


def caddy_hsts():
    defaults = yaml.safe_load((ROOT / "ansible/roles/caddy/defaults/main.yml").read_text())
    return defaults["caddy_hsts"]


def private_path_variants(pattern):
    """The ways a client could try to sneak past `path PATTERN` in Caddy."""
    base = pattern.removesuffix("/*").rstrip("/") or "/"
    segments = base.strip("/").split("/")
    variants = {base, base + "/"}
    if pattern.endswith("/*"):
        variants.add(base + "/x")
    if segments[0]:
        variants.add("/" + "//".join(segments) if len(segments) > 1 else "/" + base)  # a doubled slash
        variants.add("/" + "/".join([segments[0].upper(), *segments[1:]]))
        last = segments[-1]
        variants.add("/" + "/".join([*segments[:-1], f"%{ord(last[0]):02x}{last[1:]}"]))
    return sorted(variants)


def expected():
    variables = (ROOT / "terraform/variables.tf").read_text()
    domain = terraform_string("domain", variables)
    projects = yaml.safe_load((ROOT / "projects.yml").read_text())["projects"]
    sites, redirects, private = [f"status.{domain}"], [], {}
    for project in projects:
        subdomain = project.get("subdomain")
        if subdomain is None:
            continue
        host = domain if subdomain == "@" else f"{subdomain}.{domain}"
        sites.append(host)
        if subdomain == "@" and project.get("site"):
            redirects.append(f"www.{domain}")
        for pattern in project.get("backend", {}).get("private_paths", []):
            private.setdefault(host, set()).update(private_path_variants(pattern))
    ds = os.environ.get("DNSSEC_DS", "").strip()
    return {
        "domain": domain,
        "server": f"server.{domain}",
        "ports": firewall_ports((ROOT / "terraform/firewall.tf").read_text()),
        "sites": sorted(sites),
        "redirects": redirects,
        "hsts": caddy_hsts(),
        "private_paths": {host: sorted(paths) for host, paths in sorted(private.items())},
        "caa": caa_records((ROOT / "terraform/dns.tf").read_text()),
        "ds": {normalize_ds(line) for line in ds.splitlines() if line.strip()},
    }


def normalize_ds(line):
    """dig splits a long digest in two: compare without spaces or case."""
    key_tag, algorithm, digest_type, *digest = line.split()
    return f"{key_tag} {algorithm} {digest_type} {''.join(digest).upper()}"


def nmap(args, workdir):
    """Runs nmap (as root: raw sockets) and returns its XML. Its output is never printed."""
    output = pathlib.Path(workdir) / "nmap.xml"
    command = ["nmap", "-oX", str(output), *args]
    if os.geteuid() != 0:
        command = ["sudo", "-n", *command]
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1800)
    return ET.parse(output).getroot()


def port_states(root):
    states = {}
    for port in root.iter("port"):
        states[(port.get("protocol"), int(port.get("portid")))] = port.find("state").get("state")
    return states


def check_ports(want, workdir):
    differences = []
    root = nmap(["-Pn", "-4", "-p-", "-T4", want["server"]], workdir)
    if root.find("host") is None:
        return [f"{want['server']}: no answer to the TCP port scan"]
    tcp = {port: state for (protocol, port), state in port_states(root).items() if protocol == "tcp"}
    for port in sorted(want["ports"]["tcp"]):
        if tcp.get(port) != "open":
            differences.append(f"tcp {port}: {tcp.get(port, 'filtered')}, expected open")
    for port, state in sorted(tcp.items()):
        if port not in want["ports"]["tcp"] and state != "filtered":
            differences.append(f"tcp {port}: {state}, expected filtered")
    if want["ports"]["udp"]:
        ports = ",".join(str(port) for port in sorted(want["ports"]["udp"]))
        udp = port_states(nmap(["-Pn", "-4", "-sU", "-p", ports, want["server"]], workdir))
        for port in sorted(want["ports"]["udp"]):
            state = udp.get(("udp", port), "no answer")
            if state not in {"open", "open|filtered"}:
                differences.append(f"udp {port}: {state}, expected open|filtered")
    return differences


def check_tls(host, workdir):
    root = nmap(["-Pn", "-4", "-p", "443", "--script", "ssl-enum-ciphers", host], workdir)
    script = root.find(".//script[@id='ssl-enum-ciphers']")
    if script is None:
        return [f"{host}: no TLS answer on 443"]
    protocols = {table.get("key") for table in script.findall("table")}
    least = script.find("elem[@key='least strength']")
    differences = []
    if not protocols or protocols - TLS_PROTOCOLS_OK:
        differences.append(f"{host}: TLS {', '.join(sorted(protocols)) or 'none'}, expected TLSv1.2 and TLSv1.3 only")
    if least is None or least.text != "A":
        differences.append(f"{host}: TLS least strength {least.text if least is not None else 'unknown'}, expected A")
    return differences


def request(host, method, path):
    """One HTTPS request, the path sent exactly as given. The certificate must be valid."""
    connection = http.client.HTTPSConnection(host, 443, timeout=TIMEOUT, context=ssl.create_default_context())
    try:
        body = b"" if method == "POST" else None
        connection.request(method, path, body=body, headers={"User-Agent": "outside-check"})
        response = connection.getresponse()
        response.read(65536)
        return response
    finally:
        connection.close()


def check_headers(host, hsts):
    try:
        headers = request(host, "GET", "/").headers
    except (OSError, http.client.HTTPException, ssl.SSLError) as error:
        return [f"{host}: HTTPS failed ({type(error).__name__})"]
    differences = []
    if headers.get("Strict-Transport-Security") != hsts:
        differences.append(f"{host}: Strict-Transport-Security {headers.get('Strict-Transport-Security')!r}")
    if headers.get("X-Content-Type-Options") != "nosniff":
        differences.append(f"{host}: X-Content-Type-Options {headers.get('X-Content-Type-Options')!r}")
    if "frame-ancestors" not in (headers.get("Content-Security-Policy") or ""):
        differences.append(f"{host}: Content-Security-Policy without frame-ancestors")
    if "Server" in headers:
        differences.append(f"{host}: sends a Server header")
    return differences


def check_redirect(host, domain, hsts):
    try:
        response = request(host, "GET", "/")
    except (OSError, http.client.HTTPException, ssl.SSLError) as error:
        return [f"{host}: HTTPS failed ({type(error).__name__})"]
    differences = []
    location = response.headers.get("Location") or ""
    if response.status not in {301, 308} or not location.startswith(f"https://{domain}/"):
        differences.append(f"{host}: {response.status} to {location!r}, expected a permanent redirect to {domain}")
    if response.headers.get("Strict-Transport-Security") != hsts:
        differences.append(f"{host}: Strict-Transport-Security {response.headers.get('Strict-Transport-Security')!r}")
    if "Server" in response.headers:
        differences.append(f"{host}: sends a Server header")
    return differences


def check_private_path(host, path):
    try:
        status = request(host, "POST", path).status
    except (OSError, http.client.HTTPException, ssl.SSLError) as error:
        return [f"{host} {path}: HTTPS failed ({type(error).__name__})"]
    if status not in PRIVATE_PATH_OK:
        return [f"{host} {path}: {status}, expected 404 or 405"]
    return []


def dig(record, name, resolver):
    result = subprocess.run(
        ["dig", "+short", "+time=5", "+tries=2", record, name, f"@{resolver}"],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    )
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def check_dns(want, resolver):
    differences = []
    caa = dig("CAA", want["domain"], resolver)
    if caa != want["caa"]:
        differences.append(f"CAA: {sorted(caa)}, expected {sorted(want['caa'])}")
    if want["ds"]:
        ds = {normalize_ds(line) for line in dig("DS", want["domain"], resolver)}
        if ds != want["ds"]:
            differences.append(f"DS: {sorted(ds) or 'none'}, expected {sorted(want['ds'])}")
    return differences


def ping(url, suffix, body):
    request = urllib.request.Request(url.rstrip("/") + suffix, data=body.encode()[:100_000], method="POST")
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        response.read()


def summary(text):
    print(text)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as file:
            file.write(text + "\n")


def run():
    url = os.environ.get("OUTSIDE_CHECK_PING_URL", "").strip()
    if not url:
        print("OUTSIDE_CHECK_PING_URL is not set: nowhere to send the result.")
        return 1
    if not os.environ.get("DNSSEC_DS", "").strip():
        print("DNSSEC_DS is not set.")
        return 1
    resolver = os.environ.get("OUTSIDE_CHECK_RESOLVER", "1.1.1.1")
    try:
        want = expected()
        differences, checks = [], 0
        with tempfile.TemporaryDirectory() as workdir:
            differences += check_ports(want, workdir)
            checks += 1
            for host in want["sites"] + want["redirects"]:
                differences += check_tls(host, workdir)
                checks += 1
        for host in want["sites"]:
            differences += check_headers(host, want["hsts"])
            checks += 1
        for host in want["redirects"]:
            differences += check_redirect(host, want["domain"], want["hsts"])
            checks += 1
        for host, paths in want["private_paths"].items():
            for path in paths:
                differences += check_private_path(host, path)
                checks += 1
        differences += check_dns(want, resolver)
        checks += 1
    except Exception as error:  # noqa: BLE001 - reported privately, then the run fails
        # The traceback can name what was being checked: only healthchecks.io gets it.
        ping(url, "/fail", "The outside check could not run:\n\n" + traceback.format_exc())
        summary(f"The check could not run ({type(error).__name__}). Details sent to healthchecks.io.")
        return 1
    if differences:
        ping(url, "/fail", f"{len(differences)} of {checks} checks differ:\n\n" + "\n".join(differences) + "\n")
    else:
        ping(url, "", f"All {checks} checks as expected.\n")
    summary(f"Ran {checks} checks. Result sent to healthchecks.io.")
    return 0


def main():
    socket.setdefaulttimeout(TIMEOUT)
    if sys.argv[1:] == ["expected"]:
        want = expected()
        print(json.dumps(want, indent=2, default=sorted))
        return 0
    if sys.argv[1:] == ["run"]:
        return run()
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

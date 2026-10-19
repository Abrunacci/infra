#!/usr/bin/env python3
"""Checks that Caddy and EPB Stock's API cut request bodies where they should.

    check.py [--protocols 1.1,2,3] [--connect-to IP] [--cacert FILE] [--url URL]

Sends real bytes (random, so compression changes nothing) to a backend route
over HTTP/1.1, HTTP/2 and HTTP/3, and compares each answer with what is
expected:

- 8 MiB, over the project's max_body: 413 from Caddy, which answers by the
  Content-Length before the API reads a byte. Caddy's 413 has no body.
- 2 MB, under max_body but over the API's own 1 MB: the API's 413, whose JSON
  says request.too_large.
- 900 KB, under both: anything but 413 (today the API answers 500 to a body
  that is not JSON; that is EPB's, not infra's).

The project and its max_body come from projects.yml, so the 8 MiB case fails
here, before sending anything, if max_body ever grows past it. HTTP/1.1 and
HTTP/2 go through curl; HTTP/3 through aioquic (the curl in Ubuntu has no
HTTP/3), over IPv4. Exits 0 when every case passes, 1 otherwise.
"""

import argparse
import asyncio
import os
import pathlib
import socket
import ssl
import subprocess
import sys
import tempfile
import urllib.parse

import yaml
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.connection import QuicConnection
from aioquic.quic.events import ConnectionTerminated, StreamReset

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROJECT = "epb-stock"
PATH = "/api/auth/session"
TIMEOUT = 120
# The API answers 413 before reading the whole body and closes the connection;
# now and then Caddy is still sending to it and answers 502 instead (seen
# before #83 too). Only that case is retried, and only that answer.
RETRIES_ON_502 = 2
MiB = 1024 * 1024


def max_body_bytes(value):
    """projects.yml's max_body (like 7MB or 500KB) in bytes, as site.caddy.j2 counts it."""
    number, unit = int(value[:-2]), value[-2:]
    return number * {"KB": 1000, "MB": 1000000}[unit]


def target():
    """The project's URL and max_body in bytes, from projects.yml."""
    registry = yaml.safe_load((ROOT / "projects.yml").read_text())
    project = next(p for p in registry["projects"] if p["name"] == PROJECT)
    # The first domain is every project's default (group_vars, project_hosts).
    domain = project.get("domain", registry["domains"][0]["name"])
    host = domain if project["subdomain"] == "@" else f"{project['subdomain']}.{domain}"
    # The schema's default, roles/projects (projects_backend_default_max_body).
    return f"https://{host}{PATH}", max_body_bytes(project["backend"].get("max_body", "10MB"))


class Case:
    def __init__(self, name, size, expected, check, retry_502=False):
        self.name, self.size, self.expected, self.check, self.retry_502 = name, size, expected, check, retry_502


CASES = [
    Case("8 MiB", 8 * MiB, "413 from Caddy, empty", lambda s, b: s == 413 and b == b""),
    Case(
        "2 MB",
        2_000_000,
        "413 from the API, request.too_large",
        lambda s, b: s == 413 and b"request.too_large" in b,
        retry_502=True,
    ),
    Case("900 KB", 900_000, "anything but 413", lambda s, b: s is not None and s != 413),
]


def describe(status, body):
    if status is None:
        return "no answer"
    if status == 413 and body == b"":
        return "413, empty (Caddy)"
    if b"request.too_large" in body:
        return f"{status}, request.too_large (API)"
    return f"{status}, {len(body)} bytes"


def send_curl(version, url, body_file, connect_to, cacert):
    """POSTs the file with curl; returns (status or None, body, negotiated version, error)."""
    host = urllib.parse.urlsplit(url).hostname
    with tempfile.NamedTemporaryFile() as answer:
        argv = ["curl", "-sS", f"--http{version}", "--max-time", str(TIMEOUT), "-o", answer.name]
        # No "Expect: 100-continue" (curl adds it to large bodies over HTTP/1.1):
        # browsers never send it, and the answer must not depend on it.
        argv += ["-H", "Expect:", "-w", "%{http_code} %{http_version}", "--data-binary", f"@{body_file}"]
        if connect_to:
            argv += ["--connect-to", f"{host}:443:{connect_to}:443"]
        if cacert:
            argv += ["--cacert", cacert]
        result = subprocess.run([*argv, url], capture_output=True, text=True, check=False)
        code, _, negotiated = result.stdout.partition(" ")
        body = pathlib.Path(answer.name).read_bytes()
    # curl may also report a send error after the answer (Caddy answered
    # without reading the body); the answer is what counts.
    # 000 is no answer; 100 is only the interim one, with the final one lost.
    status = int(code) if code.isdigit() and int(code) >= 200 else None
    return status, body, negotiated, result.stderr.strip()


class H3Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.stream_id = None
        self.status = None
        self.body = bytearray()
        self.done = asyncio.get_running_loop().create_future()

    def finish(self, error=None):
        if not self.done.done():
            self.done.set_result(error)

    def quic_event_received(self, event):
        if isinstance(event, StreamReset) and event.stream_id == self.stream_id:
            # Caddy may reset the stream after its answer: that ends it.
            self.finish(None if self.status else f"stream reset, error code {event.error_code}")
        elif isinstance(event, ConnectionTerminated):
            self.finish(None if self.status else f"connection closed: {event.reason_phrase or event.error_code}")
        for h3_event in self.http.handle_event(event):
            if getattr(h3_event, "stream_id", None) != self.stream_id:
                continue
            if isinstance(h3_event, HeadersReceived):
                self.status = int(dict(h3_event.headers)[b":status"])
            elif isinstance(h3_event, DataReceived):
                self.body += h3_event.data
            if h3_event.stream_ended:
                self.finish()

    def post(self, host, path, body):
        self.stream_id = self._quic.get_next_available_stream_id()
        headers = [(b":method", b"POST"), (b":scheme", b"https"), (b":authority", host.encode())]
        headers += [(b":path", path.encode()), (b"content-length", str(len(body)).encode())]
        headers += [(b"user-agent", b"infra-body-limits-check")]
        self.http.send_headers(self.stream_id, headers)
        self.http.send_data(self.stream_id, body, end_stream=True)
        self.transmit()


async def h3_post(url, body, connect_to, cacert):
    parts = urllib.parse.urlsplit(url)
    configuration = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN, server_name=parts.hostname)
    if cacert:
        configuration.load_verify_locations(cacert)
    loop = asyncio.get_running_loop()
    address = connect_to or (await loop.getaddrinfo(parts.hostname, 443, family=socket.AF_INET))[0][4][0]
    connection = QuicConnection(configuration=configuration)
    # aioquic's own connect() binds an IPv6 socket, which fails where there is no IPv6.
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", 0))
    transport, client = await loop.create_datagram_endpoint(lambda: H3Client(connection), sock=sock)
    try:
        client.connect((address, 443))
        await asyncio.wait_for(client.wait_connected(), TIMEOUT)
        client.post(parts.hostname, parts.path, body)
        error = await asyncio.wait_for(client.done, TIMEOUT)
        return client.status, bytes(client.body), error
    finally:
        client.close()
        transport.close()


def send_h3(url, body_file, connect_to, cacert):
    body = pathlib.Path(body_file).read_bytes()
    try:
        status, answer, error = asyncio.run(h3_post(url, body, connect_to, cacert))
    except (TimeoutError, ssl.SSLError, OSError, ConnectionError) as exc:
        return None, b"", "3", f"{type(exc).__name__}: {str(exc) or 'no connection over HTTP/3'}"
    return status, answer, "3", error or ""


def send(version, url, body_file, connect_to, cacert):
    if version == "3":
        return send_h3(url, body_file, connect_to, cacert)
    return send_curl(version, url, body_file, connect_to, cacert)


def main():
    default_url, max_body = target()
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--url", default=default_url, help=f"where to send the bodies (default {default_url})")
    parser.add_argument("--protocols", default="1.1,2,3", help="comma-separated: 1.1, 2, 3 (default all three)")
    parser.add_argument("--connect-to", metavar="IP", help="connect to this IPv4 address instead of the URL's")
    parser.add_argument("--cacert", metavar="FILE", help="trust this CA (a test server's own)")
    args = parser.parse_args()
    protocols = args.protocols.split(",")
    if any(p not in ("1.1", "2", "3") for p in protocols):
        parser.error("--protocols takes 1.1, 2 and 3")

    if not CASES[1].size <= max_body < CASES[0].size:
        sys.exit(f"{PROJECT}'s max_body is {max_body} bytes: the cases expect it between 2 MB and 8 MiB")

    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        for case in CASES:
            body_file = os.path.join(tmp, f"{case.size}.bin")
            pathlib.Path(body_file).write_bytes(os.urandom(case.size))
            for version in protocols:
                for _attempt in range(1 + (RETRIES_ON_502 if case.retry_502 else 0)):
                    status, body, negotiated, error = send(version, args.url, body_file, args.connect_to, args.cacert)
                    if not (case.retry_502 and status == 502):
                        break
                ok = case.check(status, body) and negotiated == version
                failures += not ok
                got = describe(status, body)
                if status is not None and negotiated != version:
                    got += f" over HTTP/{negotiated}"
                if error and not ok:
                    got += f" ({error})"
                label = "ok  " if ok else "FAIL"
                print(f"{label} {case.name:<7} HTTP/{version:<4} expected {case.expected}; got {got}", flush=True)
    print(f"{failures} of {len(CASES) * len(protocols)} failed" if failures else "All cases as expected")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

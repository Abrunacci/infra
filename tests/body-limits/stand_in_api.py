#!/usr/bin/env python3
"""A stand-in for EPB Stock's API, behind the test Caddy of ci.sh.

Listens on 127.0.0.1:8000 and answers POSTs the way EPB's API does for the
limits check.py tests: it counts the body's bytes as it reads them, and past
1,000,000 answers 413 with request.too_large (then reads the rest, so the
connection closes cleanly); a body within the limit that is not JSON gets 500.
GET answers 200, for Caddy's own requests.
"""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LIMIT = 1_000_000
CHUNK = 65536


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def answer(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if status >= 400:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def skip(self, remaining):
        while remaining > 0:
            data = self.rfile.read(min(CHUNK, remaining))
            if not data:
                return
            remaining -= len(data)

    def do_GET(self):
        self.answer(200, b'{"status":"ok"}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = bytearray()
        while len(body) < length:
            data = self.rfile.read(min(CHUNK, length - len(body)))
            if not data:
                break
            body += data
            if len(body) > LIMIT:
                error = {"error": {"code": "request.too_large", "message": "The request body is too large."}}
                self.answer(413, json.dumps(error).encode())
                self.skip(length - len(body))
                return
        try:
            json.loads(body)
        except ValueError:
            self.answer(500, b"Internal Server Error", "text/plain")
            return
        self.answer(200, b"{}")

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8000), Handler).serve_forever()

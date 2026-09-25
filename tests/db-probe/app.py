"""The probe's HTTP server: /api/health and /api/visits on port 8080."""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

VERSION = os.environ.get("PROBE_VERSION", "unknown")


def query(statement):
    with psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=5) as conn:
        return conn.execute(statement).fetchall()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            if self.path == "/api/health":
                query("SELECT 1")
                self.reply(200, "text/plain", "ok\n")
            elif self.path == "/api/visits":
                count = query("INSERT INTO visits DEFAULT VALUES RETURNING (SELECT count(*) + 1 FROM visits)")[0][0]
                columns = [
                    r[0]
                    for r in query(
                        "SELECT column_name FROM information_schema.columns "
                        "WHERE table_name = 'visits' ORDER BY ordinal_position"
                    )
                ]
                body = json.dumps({"version": VERSION, "visits": count, "columns": columns})
                self.reply(200, "application/json", body + "\n")
            else:
                self.reply(404, "text/plain", "not found\n")
        except psycopg.Error as e:
            self.reply(503, "text/plain", f"database error: {type(e).__name__}\n")

    def reply(self, status, content_type, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    print(f"db-probe {VERSION} listening on 8080", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()

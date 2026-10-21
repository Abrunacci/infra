# body-limits

Checks that a request body is cut where it should be, on EPB Stock's public
API (`https://app.epbstock.com.ar/api/auth/session`), over HTTP/1.1, HTTP/2 and
HTTP/3:

| Body | Expected | Why |
|---|---|---|
| 8 MiB | 413 from Caddy, empty | over `max_body` (projects.yml): Caddy answers by the `Content-Length` |
| 2 MB | 413 from the API, `request.too_large` | under `max_body`, over the API's own 1 MB |
| 900 KB | anything but 413 | under both (today the API answers 500 to a body that is not JSON: EPB's to fix) |

Run it after a change to Caddy or to a backend's `max_body`, from the repo
root, on any machine with Python 3 and curl:

```sh
python3 -m venv /tmp/body-limits
/tmp/body-limits/bin/pip install -r tests/body-limits/requirements.txt
/tmp/body-limits/bin/python tests/body-limits/check.py
```

It prints one line per case and protocol (`ok` or `FAIL`, what was expected
and what came back) and exits 1 if any failed. `--protocols 1.1,2` skips
HTTP/3 (UDP 443 blocked on the way out, for example). `--connect-to` and
`--cacert` point it at a test Caddy instead of the server.

Each run sends about 33 MB and 9 requests: well under fail2ban's limits
(roles/caddy).

## In CI

`ci.sh` runs the same check on every pull request (CI, "Test (body limits)"),
without touching the server: it renders the Caddyfile and the site files from
`projects.yml` with the roles' own templates (`render.yml`), checks them with
`caddy validate` on the pinned image (`caddy_image`), starts that image with
Caddy's own CA in front of `stand_in_api.py` (EPB's limits: 1,000,000 bytes
counted as read, 413 `request.too_large`, 500 for a body that is not JSON),
and runs `check.py` against it. A Caddy upgrade that refuses the configuration,
or that cuts bodies elsewhere, turns the pull request red. To run it locally
(Docker, ports 80 and 443 free):

```sh
python3 -m venv /tmp/body-limits
/tmp/body-limits/bin/pip install -r tests/body-limits/requirements-ci.txt
PATH="/tmp/body-limits/bin:$PATH" PYTHON=/tmp/body-limits/bin/python tests/body-limits/ci.sh
```

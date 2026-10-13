#!/usr/bin/env bash
# Runs check.py against a test Caddy: the pinned image (roles/caddy,
# caddy_image) with the Caddyfile and site files rendered from projects.yml
# (render.yml), in front of stand_in_api.py. Run by CI on every pull request;
# needs Docker, and ansible-playbook and a Python with requirements-ci.txt. Caddy uses
# its own CA instead of Let's Encrypt, and listens on this machine's ports 80
# and 443 (TCP and UDP).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
python="${PYTHON:-python3}"
container=body-limits-caddy
work="$(mktemp -d)"
api_pid=""

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  [[ -n "$api_pid" ]] && kill "$api_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap 'cleanup' EXIT

mkdir -p "$work/conf/sites" "$work/log"
ansible-playbook -i localhost, "$here/render.yml" -e out_dir="$work" -e ansible_python_interpreter="$(command -v "$python")" >/dev/null
# Caddy's own CA instead of Let's Encrypt, and no HTTP to HTTPS redirect.
sed -i '0,/^{$/s//{\n\tlocal_certs\n\tauto_https disable_redirects/' "$work/conf/Caddyfile"

image="$(sed -n 's/^caddy_image: //p' "$root/ansible/roles/caddy/defaults/main.yml")"
[[ -n "$image" ]] || { echo "ci.sh: no caddy_image in roles/caddy" >&2; exit 1; }

# The same check the playbook makes before writing a Caddyfile: a version of
# Caddy that refuses the configuration fails here, with Caddy's own message.
if ! out="$(docker run --rm --tmpfs /var/log/caddy -v "$work/conf:/etc/caddy:ro" "$image" \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"; then
  grep -v '"level":"info"' <<<"$out" >&2
  echo "ci.sh: $image refuses the configuration" >&2
  exit 1
fi

"$python" "$here/stand_in_api.py" &
api_pid=$!

# The backend's alias on the edge network, here the stand-in on this machine.
docker run -d --name "$container" --network host --add-host epb-stock-backend:127.0.0.1 \
  -v "$work/conf:/etc/caddy:ro" -v "$work/log:/var/log/caddy" "$image" >/dev/null

# Caddy is ready when it serves the site with a certificate from its CA.
host="$("$python" -c 'import sys, urllib.parse; sys.path.insert(0, sys.argv[1]); import check
print(urllib.parse.urlsplit(check.target()[0]).hostname)' "$here")"
for _ in $(seq 60); do
  if docker exec "$container" cat /data/caddy/pki/authorities/local/root.crt >"$work/root.crt" 2>/dev/null \
    && curl -sf -o /dev/null --cacert "$work/root.crt" --connect-to "$host:443:127.0.0.1:443" "https://$host/api/health"; then
    break
  fi
  sleep 1
done

if ! "$python" "$here/check.py" --connect-to 127.0.0.1 --cacert "$work/root.crt"; then
  echo "--- Caddy's log"
  docker logs "$container" 2>&1 | tail -n 50
  exit 1
fi

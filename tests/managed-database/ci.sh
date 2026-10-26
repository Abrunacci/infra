#!/usr/bin/env bash
# Renders every server's configuration (render.yml) and checks it (check.py):
# the servers whose database is local never name the managed one. Run by CI
# on every pull request; needs ansible-playbook and a Python with PyYAML (requirements.txt).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
python="${PYTHON:-python3}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Every server in projects.yml is a host, as in the inventory.
hosts="$("$python" -c 'import sys, yaml; print(",".join(s["name"] for s in yaml.safe_load(open(sys.argv[1]))["servers"]) + ",")' \
  "$root/projects.yml")"
mkdir "$work/out"
# The playbook's own filters (memory_limit), which Ansible finds next to
# site.yml but not next to render.yml.
export ANSIBLE_FILTER_PLUGINS="$root/ansible/filter_plugins"
if ! ansible-playbook -i "$hosts" "$here/render.yml" -e out_dir="$work/out" \
  -e ansible_python_interpreter="$(command -v "$python")" >"$work/render.log" 2>&1; then
  cat "$work/render.log"
  echo "ci.sh: render.yml failed" >&2
  exit 1
fi
"$python" "$here/check.py" "$work/out" "$root/projects.yml"

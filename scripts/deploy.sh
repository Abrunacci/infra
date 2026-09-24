#!/usr/bin/env bash
# Deploys one release of a project's static site. Never run by hand: it is the
# forced command of each project's CI key in ~deploy/.ssh/authorized_keys
# (roles/deploy), through the deploy user's only sudo rule:
#
#   restrict,command="sudo -n /usr/local/sbin/deploy.sh PROJECT \"$SSH_CLIENT\" \"$SSH_ORIGINAL_COMMAND\"" KEY
#
# PROJECT comes from the key's line, not from the client. The client only
# chooses what SSH_ORIGINAL_COMMAND says, which must be
#
#   deploy <40-character commit sha> [<GitHub Actions run id>]
#
# and sends a gzipped tar of the site on stdin, for example:
#
#   tar -C dist -cz . | ssh deploy@server.abrunacci.dev deploy "$GITHUB_SHA" "$GITHUB_RUN_ID"
#
# The release is checked and extracted as the sites user into
# /srv/sites/PROJECT/releases/<UTC time>-<short sha>/ (extract-release), and
# only then does current switch to it, atomically. If anything fails, what was
# published stays published. The last 5 releases are kept, plus the one
# current points at. Every attempt is logged to the journal (tag: deploy).
# Installed by Ansible (roles/deploy) as /usr/local/sbin/deploy.sh.
set -euo pipefail
umask 022

readonly REGISTRY=/etc/infra/projects.json
readonly SITES=/srv/sites
readonly EXTRACT=/usr/local/lib/infra/extract-release
readonly SITES_USER=sites
readonly KEEP=5
readonly MAX_COMPRESSED=$((25 * 1024 * 1024))
readonly MAX_EXTRACTED=$((100 * 1024 * 1024))
readonly MAX_FILES=5000
readonly MAX_DEPTH=20
readonly RELEASE_RE='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$'

# What the journal line says; filled in as the deploy goes.
project="-" client="-" sha="-" run_id="-" key="-" release="-" size="files=- bytes=-"
result="failed" reason="unexpected error"

log_result() {
  local extra=""
  [[ -n "$reason" ]] && extra=" reason=\"$reason\""
  logger -t deploy -- "result=$result project=$project release=$release sha=$sha run_id=$run_id key=$key client=$client $size$extra"
}
trap 'log_result' EXIT

fail() {
  reason="$1"
  echo "deploy: $reason" >&2
  exit 1
}

[[ "$EUID" -eq 0 ]] || fail "must run as root (through sudo)"
[[ $# -eq 3 ]] || fail "internal: expected PROJECT SSH_CLIENT ORIGINAL_COMMAND"

# The client's address, for the journal only.
read -r addr _ <<<"$2" || true
[[ "${addr:-}" =~ ^[0-9A-Fa-f:.]{2,45}$ ]] && client="$addr"

# PROJECT: from the key's command, but checked like anything else.
[[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail "invalid project name"
project="$1"

# What the client asked for.
if [[ "$3" =~ ^deploy\ ([0-9a-f]{40})(\ ([0-9]{1,20}))?$ ]]; then
  sha="${BASH_REMATCH[1]}"
  run_id="${BASH_REMATCH[3]:--}"
else
  fail "unsupported command (expected: deploy <40-character commit sha> [<run id>])"
fi

# The project must be in the server's registry, with a site and a deploy key.
info="$(python3 -I - "$REGISTRY" "$project" <<'PY'
import json, sys
registry, name = sys.argv[1], sys.argv[2]
for p in json.load(open(registry))["projects"]:
    if p["name"] == name:
        print("site" if p.get("site") else "nosite")
        print(p.get("deploy_key") or "")
        break
PY
)" || fail "cannot read the project registry"
[[ -n "$info" ]] || fail "unknown project"
[[ "$(sed -n 1p <<<"$info")" == site ]] || fail "the project has no static site"
deploy_key="$(sed -n 2p <<<"$info")"
[[ -n "$deploy_key" ]] || fail "the project has no deploy key"
key="$(ssh-keygen -lf - <<<"$deploy_key" | awk '{print $2}')" || key="-"
[[ -n "$key" ]] || key="-"

site="$SITES/$project"
releases="$site/releases"
[[ -d "$site" && ! -L "$site" && -d "$releases" && ! -L "$releases" ]] \
  || fail "the site's directories are missing (run the playbook)"

# One deploy or rollback per project at a time (site-rollback takes the same lock).
exec 9>"/run/lock/site-$project.lock"
flock -n 9 || fail "another deploy or rollback of $project is running"

release="$(date -u +%Y%m%dT%H%M%SZ)-${sha:0:12}"

# Leftovers of an interrupted deploy, removed as the sites user.
runuser -u "$SITES_USER" -- find "$releases" -mindepth 1 -maxdepth 1 -name '.incoming-*' -exec rm -rf -- {} + </dev/null

# Checked and extracted as the sites user. head stops reading one byte past
# the limit, so an oversized upload is cut off instead of read in full.
if ! out="$(head -c $((MAX_COMPRESSED + 1)) \
  | timeout 120 runuser -u "$SITES_USER" -- python3 -I "$EXTRACT" \
      "$releases" "$release" "$MAX_COMPRESSED" "$MAX_EXTRACTED" "$MAX_FILES" "$MAX_DEPTH" 2>&1)"; then
  fail "$(tail -n 1 <<<"$out" | tr -cd '[:print:]' | cut -c1-200)"
fi
size="$(tr -cd '[:print:]' <<<"$out" | cut -c1-80)"

target="$releases/$release"
[[ -d "$target" && ! -L "$target" && -f "$target/index.html" && ! -L "$target/index.html" ]] \
  || fail "the extracted release is incomplete"

# Publish: a new symlink renamed over current, so there is never a moment
# without one.
ln -s "releases/$release" "$site/.current-$$"
mv -T "$site/.current-$$" "$site/current"
result="ok" reason=""

# Keep the newest releases and whatever current points at; the rest go, as
# the sites user. A failure here does not undo the deploy.
current_target="$(readlink "$site/current")"
mapfile -t all < <(find "$releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' </dev/null | grep -E "$RELEASE_RE" | sort -r)
removed=0
for old in "${all[@]:$KEEP}"; do
  [[ "releases/$old" == "$current_target" ]] && continue
  runuser -u "$SITES_USER" -- rm -rf -- "$releases/$old" </dev/null && removed=$((removed + 1))
done
size="$size removed=$removed"

echo "Deployed $project release $release"

# shellcheck shell=bash disable=SC2034
# (SC2034: the constants and SWITCH_RESULT are used by the scripts that source this file.)
# Shared by deploy-backend, backend-rollback, backend-status, project-secret
# and project-db, which source it. Each of them defines fail() first.
# Installed by Ansible (roles/projects) as /usr/local/lib/infra/backend.sh.
#
# Per project (names as in roles/projects/defaults):
#   /opt/infra/projects/NAME/compose.yml          Compose project backend-NAME
#   /opt/infra/projects/NAME/app.env              env from projects.yml
#   /etc/infra/secrets/projects/NAME/secrets.env  secrets (root only)
#   /var/lib/infra/backends/NAME/release.env      what is deployed:
#                                                 BACKEND_IMAGE, BACKEND_RELEASE
#   /var/lib/infra/backends/NAME/releases         history, oldest first:
#                                                 "<release> <image@digest>"
# With a database (project-db):
#   /etc/infra/secrets/projects/NAME/db-owner.password, db-app.password
#   /etc/infra/secrets/projects/NAME/database-app.env      DATABASE_URL (the app)
#   /etc/infra/secrets/projects/NAME/database-migrate.env  MIGRATION_DATABASE_URL,
#                                                          APP_DB_USER (migrations)
#   /var/lib/infra/backends/NAME/database         when the database was created
#   /var/backups/infra/NAME/                      dumps taken before migrations

readonly REGISTRY=/etc/infra/projects.json
readonly BACKENDS_DIR=/opt/infra/projects
readonly SECRETS_DIR=/etc/infra/secrets/projects
readonly STATE_DIR=/var/lib/infra/backends
# docker login writes its config.json here (ansible/README.md).
readonly REGISTRY_AUTH=/etc/infra/secrets/registry
readonly LOCK_DIR=/run/infra-backend
readonly KEEP=5
readonly HEALTH_SECONDS=60
readonly PULL_SECONDS=300
readonly NAME_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
readonly RELEASE_RE='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$'
readonly DIGEST_RE='^sha256:[0-9a-f]{64}$'
readonly REPO_RE='^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)+$'
readonly KEY_RE='^[A-Z][A-Z0-9_]{0,63}$'
readonly DUMPS_DIR=/var/backups/infra
readonly KEEP_DUMPS=3
readonly MIGRATE_SECONDS=600
# PostgreSQL's fixed address and Compose names (roles/projects writes it).
readonly DATABASE_CONF=/etc/infra/database.conf
# 1: also print a failed container's log. Only backend-rollback (run by the
# admin in a terminal) sets it, after sourcing this file; never taken from the
# environment. A deploy never prints it: its output goes to CI's logs, which
# may be public, and a failing app can print its configuration.
BACKEND_SHOW_LOGS=0

# Reads PROJECT's backend from the server's registry into BACKEND_REPO,
# BACKEND_PORT, BACKEND_HEALTH, BACKEND_DATABASE and BACKEND_MIGRATE (true or
# false), BACKEND_URL_SCHEME and BACKEND_SECRETS (an array of "KEY kind").
# The registry is written by Ansible from a checked projects.yml; every value
# is checked again here, since it ends up in commands and files.
backend_read() {
  local out s
  local -a lines
  out="$(python3 -I - "$REGISTRY" "$1" <<'PY'
import json, sys
registry, name = sys.argv[1], sys.argv[2]
for p in json.load(open(registry))["projects"]:
    if p["name"] == name:
        b = p.get("backend")
        if not b:
            print("nobackend")
            break
        print("backend")
        print(b["image"])
        print(b["port"])
        print(b["health"])
        print("true" if p.get("database") else "false")
        print("true" if b.get("migrate") else "false")
        print(b.get("database_url_scheme") or "postgresql")
        for key, kind in sorted((b.get("secrets") or {}).items()):
            print(f"{key} {kind}")
        break
PY
)" || fail "cannot read the project registry"
  [[ -n "$out" ]] || fail "unknown project: $1"
  mapfile -t lines <<<"$out"
  [[ "${lines[0]}" == backend ]] || fail "$1 has no backend"
  BACKEND_REPO="${lines[1]}" BACKEND_PORT="${lines[2]}" BACKEND_HEALTH="${lines[3]}"
  BACKEND_DATABASE="${lines[4]}" BACKEND_MIGRATE="${lines[5]}" BACKEND_URL_SCHEME="${lines[6]}"
  BACKEND_SECRETS=("${lines[@]:7}")
  [[ "$BACKEND_REPO" =~ $REPO_RE ]] || fail "invalid image in the registry"
  [[ "$BACKEND_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || fail "invalid port in the registry"
  [[ "$BACKEND_HEALTH" =~ ^/[A-Za-z0-9._~/-]*$ ]] || fail "invalid health path in the registry"
  [[ "$BACKEND_DATABASE" =~ ^(true|false)$ && "$BACKEND_MIGRATE" =~ ^(true|false)$ ]] \
    || fail "invalid database settings in the registry"
  [[ "$BACKEND_URL_SCHEME" =~ ^[a-z][a-z0-9+.-]{0,31}$ ]] || fail "invalid database URL scheme in the registry"
  for s in "${BACKEND_SECRETS[@]}"; do
    [[ "$s" =~ ^[A-Z][A-Z0-9_]{0,63}\ (generated|manual)$ ]] || fail "invalid secret in the registry"
  done
}

# backend_read, and the backend's files must be there (the playbook ran).
backend_load() {
  backend_read "$1"
  [[ -f "$BACKENDS_DIR/$1/compose.yml" && -d "$STATE_DIR/$1" ]] \
    || fail "the backend's files are missing (run the playbook)"
}

# One deploy, rollback or secret change per project at a time. The lock
# lives in a directory only root can enter; children do not inherit it.
# With SECONDS, waits that long for it instead of failing at once.
backend_lock() {
  install -d -m 0700 -o root -g root "$LOCK_DIR"
  exec 9>"$LOCK_DIR/$1.lock"
  flock -w "${2:-0}" 9 || fail "another deploy, rollback or secret change of $1 is running"
}

# Prints the value of KEY in release.env (BACKEND_IMAGE or BACKEND_RELEASE),
# or nothing when no release was deployed.
backend_current() {
  local file="$STATE_DIR/$1/release.env" line
  [[ -f "$file" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == "$2="* ]] && { printf '%s\n' "${line#*=}"; return 0; }
  done <"$file"
}

# The image of RELEASE in the history, or nothing.
backend_release_image() {
  local file="$STATE_DIR/$1/releases" r i
  [[ -f "$file" ]] || return 0
  while read -r r i; do
    [[ "$r" == "$2" ]] && { printf '%s\n' "$i"; return 0; }
  done <"$file"
}

# Compose for PROJECT's backend. The deployed release's image comes from
# release.env; before the first deploy there is none, and a caller that
# needs an image sets BACKEND_IMAGE itself (it wins over the file).
backend_compose() {
  local project="$1" env_file=()
  shift
  [[ -f "$STATE_DIR/$project/release.env" ]] && env_file=(--env-file "$STATE_DIR/$project/release.env")
  docker compose --project-directory "$BACKENDS_DIR/$project" "${env_file[@]}" "$@" </dev/null 9>&-
}

# Checks the health path from Caddy's container, the way requests get there
# (the container's alias on the edge network), for up to SECONDS. Any 2xx
# answer is healthy.
#
# A container that already stopped or restarted will not get better by
# waiting: that fails at once, so a broken image costs seconds of errors
# instead of the whole wait.
backend_healthy() {
  local project="$1" seconds="$2" caddy container deadline restarts status
  caddy="$(docker ps -q --filter label=com.docker.compose.project=caddy \
    --filter label=com.docker.compose.service=caddy --filter label=com.docker.compose.oneoff=False)"
  if [[ -z "$caddy" || "$caddy" == *$'\n'* ]]; then
    echo "the Caddy container is not running" >&2
    return 1
  fi
  container="$(backend_compose "$project" ps -a -q backend 2>/dev/null)" || container=""
  deadline=$((SECONDS + seconds))
  while :; do
    docker exec "$caddy" wget -q -T 5 -O /dev/null \
      "http://$project-backend:$BACKEND_PORT$BACKEND_HEALTH" >/dev/null 2>&1 </dev/null 9>&- && return 0
    if [[ -n "$container" && "$container" != *$'\n'* ]] \
      && read -r restarts status < <(docker inspect -f '{{.RestartCount}} {{.State.Status}}' "$container" 2>/dev/null) \
      && [[ "$restarts" != 0 || "$status" == exited || "$status" == dead ]]; then
      echo "the container is not staying up (status $status, $restarts restarts)" >&2
      return 1
    fi
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
}

# Writes release.env for RELEASE and IMAGE, starts that container and checks
# it. Returns 1 if it never becomes healthy.
backend_activate() {
  local project="$1" release="$2" image="$3" tmp
  tmp="$STATE_DIR/$project/.release.env.$$"
  printf 'BACKEND_IMAGE=%s\nBACKEND_RELEASE=%s\n' "$image" "$release" >"$tmp"
  mv -f "$tmp" "$STATE_DIR/$project/release.env"
  backend_compose "$project" up -d --pull never --remove-orphans --quiet-pull >&2 || return 1
  backend_healthy "$project" "$HEALTH_SECONDS"
}

# Moves PROJECT to RELEASE/IMAGE. If it is not healthy in time, puts back
# what was running before and checks it, and returns 1. SWITCH_RESULT says
# what happened, for the caller's message and journal line.
backend_switch() {
  local project="$1" release="$2" image="$3" prev_release prev_image
  prev_release="$(backend_current "$project" BACKEND_RELEASE)"
  prev_image="$(backend_current "$project" BACKEND_IMAGE)"
  if backend_activate "$project" "$release" "$image"; then
    SWITCH_RESULT="healthy"
    return 0
  fi
  # Always to the journal (root only), and to the terminal only if asked.
  backend_compose "$project" logs --no-color --tail 30 2>&1 \
    | logger -t backend-log -- 2>/dev/null || true
  if [[ "$BACKEND_SHOW_LOGS" == 1 ]]; then
    echo "--- last lines of the backend's log ---" >&2
    backend_compose "$project" logs --no-color --tail 30 >&2 2>&1 || true
    echo "---" >&2
  fi
  if [[ -z "$prev_release" ]]; then
    backend_compose "$project" down >&2 || true
    rm -f "$STATE_DIR/$project/release.env"
    SWITCH_RESULT="not healthy (no answer on its health path within ${HEALTH_SECONDS}s, or it stopped); there is no earlier release, so the backend was stopped"
    return 1
  fi
  if backend_activate "$project" "$prev_release" "$prev_image"; then
    SWITCH_RESULT="not healthy (no answer on its health path within ${HEALTH_SECONDS}s, or it stopped); back to release $prev_release, which is healthy"
  else
    SWITCH_RESULT="not healthy (no answer on its health path within ${HEALTH_SECONDS}s, or it stopped); back to release $prev_release, which is NOT healthy either"
  fi
  return 1
}

# Adds RELEASE to the history, keeps the newest KEEP releases plus PREVIOUS
# (the one that was running before, the last known healthy one, even if it
# is older), and removes the images nothing kept refers to.
backend_record() {
  local project="$1" release="$2" image="$3" previous="$4" file r i tmp idx
  local -a all keep=() drop=()
  file="$STATE_DIR/$project/releases"
  printf '%s %s\n' "$release" "$image" >>"$file"
  mapfile -t all <"$file"
  local n=${#all[@]}
  for idx in "${!all[@]}"; do
    read -r r i <<<"${all[$idx]}"
    if ((idx >= n - KEEP)) || [[ -n "$previous" && "$r" == "$previous" ]]; then keep+=("${all[$idx]}"); else drop+=("$i"); fi
  done
  tmp="$file.$$"
  printf '%s\n' "${keep[@]}" >"$tmp"
  mv -f "$tmp" "$file"
  local kept_images=" ${keep[*]} "
  for i in "${drop[@]}"; do
    [[ "$kept_images" == *" $i "* ]] && continue
    docker image rm "$i" >/dev/null 2>&1 </dev/null 9>&- || true
  done
}

# Pulls IMAGE by digest unless it is already here, with the registry
# credentials when there are any.
backend_pull() {
  local out
  docker image inspect "$1" >/dev/null 2>&1 && return 0
  out="$(DOCKER_CONFIG="$REGISTRY_AUTH" timeout "$PULL_SECONDS" docker pull -q "$1" 2>&1 </dev/null 9>&-)" \
    || fail "cannot pull $1: $(tail -n 1 <<<"$out" | tr -cd '[:print:]' | cut -c1-200)"
}

# Declared secrets that have no value, and values that are not declared.
# Prints one line per problem; returns 1 if there is any.
backend_secret_problems() {
  local project="$1" file="$SECRETS_DIR/$1/secrets.env" line key kind bad=0
  declare -A have=() declared=()
  [[ -f "$file" ]] || fail "$file is missing (run the playbook)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    have["${line%%=*}"]=1
  done <"$file"
  for line in "${BACKEND_SECRETS[@]}"; do
    read -r key kind <<<"$line"
    declared["$key"]=1
    if [[ -z "${have[$key]:-}" ]]; then
      bad=1
      if [[ "$kind" == manual ]]; then
        echo "$key has no value: sudo project-secret $project set $key"
      else
        echo "$key has no value yet: run the playbook, which generates it"
      fi
    fi
  done
  for key in "${!have[@]}"; do
    if [[ -z "${declared[$key]:-}" ]]; then
      bad=1
      echo "$key is set but not declared in projects.yml: sudo project-secret $project unset $key"
    fi
  done
  return "$bad"
}

# ---------------------------------------------------------------------------
# Databases

# Names of PROJECT's database and roles: the database and its owner share the
# name (the project's, with - turned into _), and the app logs in as <db>_app.
db_names() {
  DB_NAME="${1//-/_}"
  DB_OWNER="$DB_NAME"
  DB_APP="${DB_NAME}_app"
}

# Loads PostgreSQL's address and finds its container into PG_CONTAINER.
db_container() {
  [[ -r "$DATABASE_CONF" ]] || fail "missing $DATABASE_CONF (run the playbook)"
  # shellcheck source=/dev/null
  . "$DATABASE_CONF"
  : "${POSTGRES_ADDRESS:?}" "${POSTGRES_PORT:?}" "${POSTGRES_COMPOSE_PROJECT:?}" "${POSTGRES_COMPOSE_SERVICE:?}"
  PG_CONTAINER="$(docker ps -q --filter "label=com.docker.compose.project=$POSTGRES_COMPOSE_PROJECT" \
    --filter "label=com.docker.compose.service=$POSTGRES_COMPOSE_SERVICE" \
    --filter label=com.docker.compose.oneoff=False 9>&-)"
  [[ -n "$PG_CONTAINER" && "$PG_CONTAINER" != *$'\n'* ]] || fail "the PostgreSQL container is not running"
}

# Runs psql as the superuser, over the container's local socket, reading SQL
# from stdin (so passwords never appear in any command line). Prints the
# unaligned output.
db_psql() {
  docker exec -i "$PG_CONTAINER" psql -U postgres -d "${1:-postgres}" -AtqX -v ON_ERROR_STOP=1 9>&-
}

db_exists() {
  [[ "$(db_psql <<<"SELECT count(*) FROM pg_database WHERE datname = '$1'")" == 1 ]]
}

# Dumps DATABASE (custom format) to DIR/LABEL.dump, root only, and keeps the
# newest KEEP dumps whose name starts like LABEL's prefix (before the first -).
# Prints the dump's path.
db_dump() {
  local database="$1" dir="$2" label="$3" keep_dumps="${4:-0}" file tmp prefix
  install -d -m 0700 -o root -g root "$DUMPS_DIR" "$dir"
  file="$dir/$label.dump"
  tmp="$dir/.$label.dump.$$"
  if ! (umask 077 && docker exec "$PG_CONTAINER" pg_dump -U postgres -Fc -d "$database" >"$tmp" 9>&-); then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file"
  if ((keep_dumps > 0)); then
    prefix="${label%%-*}-"
    find "$dir" -maxdepth 1 -type f -name "$prefix*.dump" -printf '%f\n' | sort -r | tail -n +$((keep_dumps + 1)) \
      | while read -r old; do rm -f -- "${dir:?}/$old"; done
  fi
  printf '%s\n' "$file"
}

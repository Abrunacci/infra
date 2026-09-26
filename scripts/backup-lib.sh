# shellcheck shell=bash disable=SC2034
# (SC2034: the constants are used by the scripts that source this file.)
# Shared by backup-run, backup-restore and backup-credentials, which source
# it after defining fail(). It sources the backend library for PostgreSQL
# (db_container, db_psql, db_names, db_exists) and the project registry.
# Installed by Ansible (roles/backup) as /usr/local/lib/infra/backup.sh.
#
# A backup is one directory in the bucket, named after the run's UTC time:
#   daily/<UTC time>/MANIFEST                  plain text: every file, its size and SHA-256
#   daily/<UTC time>/<project>.dump.age        pg_dump -Fc of the project's database
#   daily/<UTC time>/<project>.roles.tsv.age   the roles its migrations created, as data
#   daily/<UTC time>/secrets.tar.age           /etc/infra/secrets/projects
# weekly/ (Sundays) and monthly/ (the 1st) get a copy made inside R2. Every
# .age file is encrypted to the public keys in /etc/infra/backup-recipients.txt;
# the matching private key never touches the server except, pasted and in
# memory only, during a restore.

# shellcheck source=scripts/backend-lib.sh
. /usr/local/lib/infra/backend.sh

readonly BACKUP_CONF=/etc/infra/backup.conf
readonly BACKUP_RECIPIENTS=/etc/infra/backup-recipients.txt
readonly BACKUP_CREDENTIALS=/etc/infra/secrets/backup/r2.env
# Public status for the login warning (no secrets in it).
readonly BACKUP_STATE=/var/lib/infra/backup
readonly BACKUP_LOCK=/run/infra-backup.lock
readonly SNAPSHOT_RE='^(daily|weekly|monthly)/[0-9]{8}T[0-9]{6}Z$'
readonly AGE_HEADER='age-encryption.org/v1'

backup_load() {
  [[ -r "$BACKUP_CONF" ]] || fail "missing $BACKUP_CONF (run the playbook)"
  # shellcheck source=/dev/null
  . "$BACKUP_CONF"
  : "${BACKUP_BUCKET:?}" "${BACKUP_ENDPOINT:?}" "${BACKUP_RCLONE_IMAGE:?}" "${BACKUP_PROVIDER:?}" "${BACKUP_MAX_AGE_HOURS:?}"
  [[ -s "$BACKUP_RECIPIENTS" ]] || fail "missing $BACKUP_RECIPIENTS (run the playbook)"
}

# rclone in its pinned container, with the R2 credentials from a root-only
# env file (never on a command line) and the endpoint from backup.conf.
# DIR, when given first (--dir DIR, or --dir-ro DIR read-only), is mounted at
# /work.
r2() {
  local mount=()
  # --mount, not -v: a missing source is an error instead of an empty
  # directory created on the fly, which would upload nothing.
  if [[ "${1:-}" == --dir ]]; then
    mount=(--mount "type=bind,source=$2,target=/work")
    shift 2
  elif [[ "${1:-}" == --dir-ro ]]; then
    mount=(--mount "type=bind,source=$2,target=/work,readonly")
    shift 2
  fi
  [[ -r "$BACKUP_CREDENTIALS" ]] || fail "no R2 credentials yet: sudo backup-credentials"
  docker run --rm -i --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    --pull never "${mount[@]}" \
    --env-file "$BACKUP_CREDENTIALS" \
    -e RCLONE_CONFIG=/tmp/rclone.conf \
    -e RCLONE_CONFIG_R2_TYPE=s3 -e RCLONE_CONFIG_R2_PROVIDER="$BACKUP_PROVIDER" \
    -e RCLONE_CONFIG_R2_ENDPOINT="$BACKUP_ENDPOINT" -e RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
    "$BACKUP_RCLONE_IMAGE" --log-level ERROR "$@" 9>&-
}

# Projects the registry declares with a database, one per line.
backup_projects_with_database() {
  python3 -I - "$REGISTRY" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1]))["projects"]:
    if p.get("database"):
        print(p["name"])
PY
}

# The roles PROJECT's migrations created (the ones its owner administers,
# other than the app's login, which project-db recreates), as data, not SQL:
#   role<TAB>name<TAB>login(t/f)<TAB>inherit(t/f)
#   member<TAB>role<TAB>member<TAB>inherit(t/f)<TAB>set(t/f)
# A restore validates every field and writes the SQL itself: nothing read from
# a backup is ever executed as it is.
db_roles_tsv() {
  db_names "$1"
  db_psql <<SQL
\\set owner '$DB_OWNER'
\\set app '$DB_APP'
WITH owned AS (
  SELECT r.* FROM pg_auth_members m
  JOIN pg_roles r ON r.oid = m.roleid
  JOIN pg_roles o ON o.oid = m.member
  WHERE o.rolname = :'owner' AND m.admin_option AND r.rolname <> :'app'
)
SELECT concat_ws(E'\\t', 'role', rolname, rolcanlogin, rolinherit) FROM owned
UNION ALL
SELECT concat_ws(E'\\t', 'member', g.rolname, mem.rolname, m.inherit_option, m.set_option)
FROM pg_auth_members m
JOIN pg_roles g ON g.oid = m.roleid
JOIN pg_roles mem ON mem.oid = m.member
WHERE g.oid IN (SELECT oid FROM owned)
  AND (mem.oid IN (SELECT oid FROM owned) OR mem.rolname = :'app');
SQL
}

# Runs COMMAND in the PostgreSQL container connected as PROJECT's database
# owner (over TCP, with its password), never as the superuser: what a backup
# holds is restored with the owner's rights only. The password reaches the
# container through an env file in the root-only directory DIR, never argv,
# and the file is removed whatever COMMAND does. stdin is passed through.
# (The official image trusts TCP connections from inside the container itself,
# so today the role, not the password, is what matters; the password is passed
# anyway, so this keeps working if that setting changes.)
# Usage: db_as_owner PROJECT DIR COMMAND...
db_as_owner() {
  local project="$1" dir="$2" envf rc=0
  shift 2
  envf="$dir/.owner.env"
  printf 'PGPASSWORD=%s\n' "$(<"$SECRETS_DIR/$project/db-owner.password")" >"$envf"
  chmod 0600 "$envf"
  docker exec -i --env-file "$envf" "$PG_CONTAINER" "$@" 9>&- || rc=$?
  rm -f "$envf"
  return "$rc"
}

# Recreates, as the owner, the roles listed in the TSV file (see
# db_roles_tsv) and their memberships. Every name must look like a role name
# a migration would create; an existing role must already be administered by
# the owner. Anything else stops the restore before any change.
# Usage: db_restore_roles PROJECT DIR FILE (after db_names PROJECT).
db_restore_roles() {
  local project="$1" dir="$2" file="$3" kind a b c d sql="" role_re='^[a-z_][a-z0-9_]{0,62}$'
  declare -A roles=()
  while IFS=$'\t' read -r kind a b c d; do
    [[ -z "$kind" ]] && continue
    if [[ "$kind" == role ]]; then
      [[ "$a" =~ $role_re && "$b" =~ ^[tf]$ && "$c" =~ ^[tf]$ && -z "$d" ]] || fail "invalid role line in the backup: $kind $a"
      [[ "$a" != "$DB_OWNER" && "$a" != "$DB_APP" && "$a" != postgres && "$a" != pg_* ]] \
        || fail "the backup lists a role it cannot own: $a"
      roles["$a"]=1
      local exists admin
      exists="$(db_psql <<<"SELECT count(*) FROM pg_roles WHERE rolname = '$a'")"
      if [[ "$exists" == 0 ]]; then
        sql+="CREATE ROLE \"$a\" $([[ $b == t ]] && echo LOGIN || echo NOLOGIN) $([[ $c == t ]] && echo INHERIT || echo NOINHERIT);"$'\n'
      else
        admin="$(db_psql <<<"SELECT count(*) FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid
                             JOIN pg_roles o ON o.oid = m.member
                             WHERE r.rolname = '$a' AND o.rolname = '$DB_OWNER' AND m.admin_option")"
        [[ "$admin" == 1 ]] || fail "role $a exists but does not belong to this project; nothing was changed"
      fi
    fi
  done <"$file"
  while IFS=$'\t' read -r kind a b c d; do
    [[ "$kind" == member ]] || continue
    [[ -n "${roles[$a]:-}" && (-n "${roles[$b]:-}" || "$b" == "$DB_APP") && "$c" =~ ^[tf]$ && "$d" =~ ^[tf]$ ]] \
      || fail "invalid membership line in the backup: $a $b"
    sql+="GRANT \"$a\" TO \"$b\" WITH INHERIT $([[ $c == t ]] && echo TRUE || echo FALSE), SET $([[ $d == t ]] && echo TRUE || echo FALSE);"$'\n'
  done <"$file"
  [[ -n "$sql" ]] || return 0
  printf 'SET client_min_messages = warning;\n%s' "$sql" \
    | db_as_owner "$project" "$dir" psql -h 127.0.0.1 -U "$DB_OWNER" -d "$DB_NAME" -AtqX -v ON_ERROR_STOP=1 >/dev/null
}

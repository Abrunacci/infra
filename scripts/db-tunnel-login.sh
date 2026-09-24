# shellcheck shell=sh
# Installed by Ansible (roles/db_tunnel) as /etc/profile.d/db-tunnel.sh.
# Warns on every login while the PostgreSQL bridge is open, so it is never
# left running unnoticed. Needs no root: systemctl is-active is public.
if systemctl is-active --quiet db-tunnel.service 2>/dev/null; then
  printf '\n*** PostgreSQL bridge %s ***\n*** Close it when you are done: sudo db-tunnel close ***\n\n' \
    "$(/usr/local/sbin/db-tunnel status 2>/dev/null || echo 'status unknown')"
fi

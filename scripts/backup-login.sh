# shellcheck shell=sh
# Installed by Ansible (roles/backup) as /etc/profile.d/backup-status.sh.
# Warns on every login when the backups need attention: none has succeeded
# yet, the last one is too old, or the last run failed. Reads only the public
# status backup-run writes; needs no root.
backup_status_dir=/var/lib/infra/backup
backup_status_max_hours=$(sed -n 's/^BACKUP_MAX_AGE_HOURS=//p' /etc/infra/backup.conf 2>/dev/null)
backup_status_max_hours=${backup_status_max_hours:-26}
backup_status_msg=""
if [ ! -r "$backup_status_dir/last-success" ]; then
  backup_status_msg="No backup has succeeded yet."
else
  backup_status_age=$(( ($(date +%s) - $(cat "$backup_status_dir/last-success")) / 3600 ))
  if [ "$backup_status_age" -ge "$backup_status_max_hours" ]; then
    backup_status_msg="The last successful backup is ${backup_status_age} hours old."
  fi
fi
if [ -r "$backup_status_dir/last-run" ] && grep -q '^result=failed' "$backup_status_dir/last-run"; then
  backup_status_msg="${backup_status_msg:+$backup_status_msg }The last backup run failed: $(sed -n 's/^detail=//p' "$backup_status_dir/last-run" | cut -c1-160)"
fi
if [ -n "$backup_status_msg" ]; then
  printf '\n*** BACKUPS: %s ***\n*** Details: sudo journalctl -t backup -n 20 ***\n\n' "$backup_status_msg"
fi
unset backup_status_dir backup_status_max_hours backup_status_msg backup_status_age

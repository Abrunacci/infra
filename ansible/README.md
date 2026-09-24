# Ansible

Configures the Droplet after Terraform creates it. cloud-init only creates the admin user and locks down SSH on the first boot; everything else is here, and running the playbook again changes nothing unless the repo changed.

| Role | What it does |
|---|---|
| `base` | Requires a password for the admin user's sudo (see below), manages the admin user's SSH keys (exclusive list) and empties root's, daily security updates with automatic reboots at 07:30 UTC, 2 GB of swap, `/etc/infra/secrets` (root only) and `/opt/infra` |
| `hardening` | sshd drop-ins (keys only, no root, only `admin_user`, no forwarding except the admin user's local forwards to the database bridge), ufw with the same rules as the cloud firewall, fail2ban for SSH |
| `docker` | Docker Engine and the Compose plugin from Docker's apt repository, at pinned and held versions; log rotation and `no-new-privileges` for every container; the shared `edge` and `db` networks |
| `caddy` | Caddy in a container: the only one with published ports (80, 443 and 443/udp). Non-root, read-only filesystem, a single capability |
| `postgres` | PostgreSQL 16 in a container on the internal `db` network, with no published port. Non-root, read-only filesystem, no capabilities. The superuser password is generated on the server |
| `db_tunnel` | The `db-tunnel` command, which opens a temporary, self-expiring bridge to PostgreSQL on the server's loopback, and a warning on every login while it is open |
| `projects` | Checks `projects.yml` before any other change, and writes the server's registry of projects (`/etc/infra/projects.json`). Refuses what is not built yet (backends) and never turns a database off. Sites, then backends and databases, are added in later PRs |

The roles run in that order: each one depends on the previous ones, and `projects.yml` is checked before the first one, whatever `--tags` are given (only `--skip-tags always` skips it, on purpose). `--tags projects` on its own needs a server that `base` has already set up.

## Design notes

- **sudo asks for a password.** SSH stays key-only; the admin user's password is only for sudo. It is set by hand on the server, so it is never in the repo, not even as a hash, and Ansible only receives it from the `-K` prompt.
  - **cloud-init keeps NOPASSWD.** A new Droplet has no password and root cannot log in over SSH, so without it nobody could become root to set one.
  - **The playbook removes NOPASSWD only once it is safe,** in `roles/base/tasks/sudo.yml`, before any other change, stopping at the first failure:
    1. The password is set and the account is not locked.
    2. The `-K` password is that password. A sudo rule that grants nothing new (`ops ALL=(nobody) PASSWD: ALL`) makes sudo check it while NOPASSWD still applies.
    3. cloud-init's `/etc/sudoers.d/90-cloud-init-users` is replaced by a rule that requires the password, validated with `visudo`.
    4. The playbook checks that no NOPASSWD rule is left, and that sudo works with the password on a fresh connection.
  - **Rebuilding:** `terraform apply` creates the Droplet with NOPASSWD, the admin sets the password on it, and the playbook, run with `-K`, removes NOPASSWD. The operating procedure (the backup root session and recovery) is kept in private operations documentation.
- **Pinned versions.** Container images are pinned by digest and the Docker packages by exact version (and held with `dpkg`, so neither `apt upgrade` nor unattended-upgrades changes them). Upgrading is a PR that bumps the value in the role's `defaults/main.yml`.
- **Docker bypasses ufw.** Ports published by a container skip ufw's rules. Only Caddy publishes ports, and only the ones both firewalls already allow. No other container may publish one; PostgreSQL is reached over the `db` network instead.
- **`db` is an internal network with a fixed subnet.** Containers on it have no route to the internet through it, and PostgreSQL always has the same address on it (`postgres_ipv4_address` in `group_vars`). Projects join `edge` (to be reached by Caddy) and `db` (to reach PostgreSQL).
- **Secrets are generated on the server.** The PostgreSQL superuser password is created once with `openssl rand` in `/etc/infra/secrets/postgres.password` (mode 0400, owned by the container's `postgres` user). It is never sent to the machine running Ansible, and running the playbook again does not replace it.
- **ICMP stays allowed.** ufw's default `before.rules` and `before6.rules` accept ICMP and the ICMPv6 messages IPv6 needs, and the `hardening` role leaves them untouched.
- **Database access for debugging** is only through a temporary SSH tunnel; the procedure is in private operations documentation.
- **Client IPs over IPv6.** The `edge` network is IPv4 only, so IPv6 connections reach Caddy through Docker's userland proxy and Caddy logs the bridge gateway instead of the client's address. IPv4 keeps the real address. It matters only once something acts on client IPs (rate limits, a fail2ban jail for Caddy); the fix then is IPv6 on `edge`.
- **Automatic reboots.** When a security update needs a reboot (kernel, libc), unattended-upgrades reboots at 07:30 UTC. Docker stops PostgreSQL cleanly first (60 s grace period) and every container comes back through its restart policy. Set `base_auto_reboot: false` to turn it off.

## Requirements

- Ansible (`ansible-core` 2.21) on the machine that runs the playbook.
- The collections in `requirements.yml`.
- An SSH key that can log in as `ops` (the key Terraform installed).

## Usage

Run everything from this directory, so `ansible.cfg` applies.

```sh
cd ansible
ansible-galaxy collection install -r requirements.yml
cp inventory.example.yml inventory.yml       # git-ignored

# The admin key list defaults to the key Terraform installed: load the same file.
set -a; . ../terraform/.env; set +a

ansible all -b -K -m ansible.builtin.ping    # connection and sudo work
ansible-playbook site.yml -K --diff
ansible-playbook site.yml -K --diff          # second run: expect changed=0
```

Every run asks for the admin user's sudo password (`-K`; `ansible.cfg` also sets `become_ask_pass`, so it is asked even without the flag). The first run on a new Droplet needs that password to be set on the server first; the playbook stops before changing anything if it is not.

`--check` only works fully once Docker is installed: on the first run, the Docker, Caddy and PostgreSQL tasks depend on packages that check mode does not install. `ansible-playbook site.yml -K --check --diff --tags base,hardening` previews the sudo, SSH and firewall changes, which are the ones that could lock you out. On a server that still has NOPASSWD, check mode cannot test the sudo password yet, and says so by skipping that check. Check mode also cannot show that a container will be recreated because a template it depends on changes: the template is not written, so Compose sees no difference.

### The server's host key

`host_key_checking` stays on: Ansible refuses a host that is not in `~/.ssh/known_hosts`. Add it with a first manual login, and compare the fingerprint SSH shows with the one the server reports from the DigitalOcean Droplet Console (log in as `ops`):

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub   # in the Droplet Console
ssh ops@server.abrunacci.dev                        # from your machine; accept only if they match
```

If the host key changes later without a rebuild, stop and find out why before removing the old entry.

The Droplet Console logs in over SSH by adding a temporary key to `ops`'s `authorized_keys`, so only `ops` can use it (root is refused like any SSH login). The playbook removes keys that are not listed, so a run made right after using the console reports that change; the next one is back to `changed=0`.

### fail2ban and your SSH agent

sshd allows 3 authentication attempts per connection, and fail2ban bans an IP for an hour after 5 failures in 10 minutes. An agent that offers several keys before the right one can trip both. Offer only the admin key for this host, in `~/.ssh/config`:

```
Host server.abrunacci.dev
    User ops
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

## Rotating the admin SSH key

`admin_ssh_public_keys` is exclusive: keys that are not listed are removed. The playbook refuses to run if none of the listed keys is authorized on the server today, so a wrong key cannot lock you out. Rotate in two runs, so there is always a working key:

1. In `inventory.yml`, list both keys under the host and run the playbook:

   ```yaml
   admin_ssh_public_keys:
     - ssh-ed25519 AAAA...old
     - ssh-ed25519 AAAA...new
   ```

2. Log in with the new key (`ssh -i ~/.ssh/new_key ops@server.abrunacci.dev`).
3. Remove the old key from the list and run the playbook again.

Terraform ignores the key after the Droplet is created (`ignore_changes`), so updating `TF_VAR_admin_ssh_public_key` does not touch the server. Update it anyway, so a rebuilt Droplet gets the new key.

## Checking the result

```sh
ssh -t ops@server.abrunacci.dev 'sudo ufw status verbose; sudo fail2ban-client status sshd; swapon --show'
ssh -t ops@server.abrunacci.dev 'sudo docker ps --format "{{.Names}}\t{{.Status}}"'   # both "healthy"
curl -sI https://server.abrunacci.dev | head -1   # "HTTP/2 404" with a valid certificate
ssh root@server.abrunacci.dev                      # must be refused
```

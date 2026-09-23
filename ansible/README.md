# Ansible

Configures the Droplet after Terraform creates it. cloud-init only creates the admin user and locks down SSH on the first boot; everything else is here, and running the playbook again changes nothing unless the repo changed.

| Role | What it does |
|---|---|
| `base` | Manages the admin user's SSH keys (exclusive list) and empties root's, daily security updates with automatic reboots at 07:30 UTC, 2 GB of swap, `/etc/infra/secrets` (root only) and `/opt/infra` |
| `hardening` | sshd drop-in (keys only, no root, only `admin_user`, no forwarding), ufw with the same rules as the cloud firewall, fail2ban for SSH |
| `docker` | Docker Engine and the Compose plugin from Docker's apt repository, at pinned and held versions; log rotation and `no-new-privileges` for every container; the shared `edge` and `db` networks |
| `caddy` | Caddy in a container: the only one with published ports (80, 443 and 443/udp). Non-root, read-only filesystem, a single capability |
| `postgres` | PostgreSQL 16 in a container on the internal `db` network, with no published port. Non-root, read-only filesystem, no capabilities. The superuser password is generated on the server |

The roles run in that order: each one depends on the previous ones. Projects (databases, Caddy routes, stacks) are added in a later PR.

## Design notes

- **Pinned versions.** Container images are pinned by digest and the Docker packages by exact version (and held with `dpkg`, so neither `apt upgrade` nor unattended-upgrades changes them). Upgrading is a PR that bumps the value in the role's `defaults/main.yml`.
- **Docker bypasses ufw.** Ports published by a container skip ufw's rules. Only Caddy publishes ports, and only the ones both firewalls already allow. No other container may publish one; PostgreSQL is reached over the `db` network instead.
- **`db` is an internal network.** Containers on it have no route to the internet through it. Projects join `edge` (to be reached by Caddy) and `db` (to reach PostgreSQL).
- **Secrets are generated on the server.** The PostgreSQL superuser password is created once with `openssl rand` in `/etc/infra/secrets/postgres.password` (mode 0400, owned by the container's `postgres` user). It is never sent to the machine running Ansible, and running the playbook again does not replace it.
- **ICMP stays allowed.** ufw's default `before.rules` and `before6.rules` accept ICMP and the ICMPv6 messages IPv6 needs, and the `hardening` role leaves them untouched.
- **No SSH forwarding.** `AllowTcpForwarding no` rules out `ssh -L` to PostgreSQL. Administration goes through `docker exec` on the server (`sudo docker exec -it postgres-postgres-1 psql -U postgres`), and so will the restore procedure.
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

ansible all -b -m ansible.builtin.ping       # connection and sudo work
ansible-playbook site.yml --diff
ansible-playbook site.yml --diff             # second run: expect changed=0
```

`--check` only works fully once Docker is installed: on the first run, the Docker, Caddy and PostgreSQL tasks depend on packages that check mode does not install. `ansible-playbook site.yml --check --diff --tags base,hardening` previews the SSH and firewall changes, which are the ones that could lock you out.

### The server's host key

`host_key_checking` stays on: Ansible refuses a host that is not in `~/.ssh/known_hosts`. Add it with a first manual login, and compare the fingerprint SSH shows with the one the server reports from the DigitalOcean Droplet Console (log in as `ops`):

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub   # in the Droplet Console
ssh ops@server.abrunacci.dev                        # from your machine; accept only if they match
```

If the host key changes later without a rebuild, stop and find out why before removing the old entry.

The Droplet Console logs in by adding a temporary key to `ops`'s `authorized_keys`. The playbook removes keys that are not listed, so a run made right after using the console reports that change; the next one is back to `changed=0`.

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
ssh ops@server.abrunacci.dev 'sudo ufw status verbose; sudo fail2ban-client status sshd; swapon --show'
ssh ops@server.abrunacci.dev 'sudo docker ps --format "{{.Names}}\t{{.Status}}"'   # both "healthy"
curl -sI https://server.abrunacci.dev | head -1   # "HTTP/2 404" with a valid certificate
ssh root@server.abrunacci.dev                      # must be refused
```

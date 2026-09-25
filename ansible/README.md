# Ansible

Configures the Droplet after Terraform creates it. cloud-init only creates the admin user and locks down SSH on the first boot; everything else is here, and running the playbook again changes nothing unless the repo changed.

| Role | What it does |
|---|---|
| `base` | Requires a password for the admin user's sudo (see below), manages the admin user's SSH keys (exclusive list) and empties root's, daily security updates with automatic reboots at 07:30 UTC, 2 GB of swap, `/etc/infra/secrets` (root only) and `/opt/infra` |
| `hardening` | sshd drop-ins (keys only, no root, only `admin_user`, no forwarding except the admin user's local forwards to the database bridge), ufw with the same rules as the cloud firewall, fail2ban for SSH |
| `docker` | Docker Engine and the Compose plugin from Docker's apt repository, at pinned and held versions; log rotation and `no-new-privileges` for every container; the shared `edge` and `db` networks |
| `caddy` | Caddy in a container: the only one with published ports (80, 443 and 443/udp). Non-root, read-only filesystem, a single capability |
| `postgres` | PostgreSQL 17 in a container on the internal `db` network, with no published port. Non-root, read-only filesystem, no capabilities. The superuser password is generated on the server. Refuses an image whose major version is not the data's |
| `db_tunnel` | The `db-tunnel` command, which opens a temporary, self-expiring bridge to PostgreSQL on the server's loopback, and a warning on every login while it is open |
| `projects` | Checks `projects.yml` before any other change, writes the server's registry of projects (`/etc/infra/projects.json`), prepares each static site and backend, and gives each project its Caddy site (see below). Installs the backend commands (`deploy-backend`, `backend-rollback`, `backend-status`, `project-secret`). Refuses what is not built yet (databases), and refuses to run while a database on the server has no project declaring it (see "Retiring a project with a database") |
| `deploy` | The `deploy` user for CI, one SSH key per project (each fixed to deploying that project), `deploy.sh` (which hands backend deploys to `deploy-backend`) and `site-rollback`. See "Deploying a project" and "Deploying a backend" |

The roles run in that order: each one depends on the previous ones, and `projects.yml` is checked before the first one, whatever `--tags` are given (only `--skip-tags always` skips it, on purpose; `--skip-tags projects_databases` skips only its database part, to repair Docker or PostgreSQL: see "When the databases cannot be listed"). `--tags projects` on its own needs a server that `base` has already set up.

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
- **Static sites.** A project with `site: true` is served by Caddy from `/srv/sites/<name>/current`, a symlink to one version in `releases/`. Until the first deploy it points at `placeholder/`, a page with the project's `title` and a link to its `repo` (both escaped). The placeholder lives outside `releases/`: root never writes inside the directory deploys own. Only a missing `current` is created: once a deploy has moved it, the playbook leaves it alone. Each site's Caddy file is validated with the rest of the config before it is written. A project that stops having a site stops being served, but its files stay until removed by hand. Paths that are not files get `index.html` (single-page apps), `/assets/*` is cached for a year (Vite names those files by content hash), and everything else is revalidated on each visit; no other site may frame these pages. A project on the root domain (`subdomain: "@"`) is served on `abrunacci.dev`, and its Caddy file also redirects `www` there permanently (301), keeping the path and query string. Terraform creates the `www` records only for such a project with `site: true`, and must be applied before the playbook, so Caddy finds the records when it requests the certificates.
- **Deploys.** CI deploys a static site by piping a gzipped tar of it to `ssh deploy@server.abrunacci.dev deploy <sha> <run id>`.
  - **The key fixes the project.** Each project's key (its `deploy_key` in `projects.yml`) is written to `~deploy/.ssh/authorized_keys` with `restrict` and a forced command that runs `deploy.sh` for that project only. The client never chooses the project.
  - **Access is narrow.** The deploy user has no interactive session and no forwarding, and its one sudo rule is `deploy.sh`. It cannot change its own keys: root owns its home.
  - **Checks before publishing.** `deploy.sh` checks the project against `/etc/infra/projects.json` and accepts only `deploy <40-character sha> [<run id>]`. The archive is limited to 25 MB compressed, and 100 MB, 5,000 entries and 20 levels once extracted; the upload to 2 minutes, and the extractor to 512 MB of memory and 60 s of CPU, so neither a stalled client nor a gzip bomb can hold the lock or strain the server. It may hold only regular files and directories, with no hidden ones except `.well-known/` at the root, and `index.html` at the root.
  - **Unprivileged extraction.** The release is extracted as the `sites` user into `releases/<UTC time>-<short sha>/` (files 0644, directories 0755). Only then does `current` switch to it, atomically. If anything fails, what was published stays published.
  - **Retention.** The last 5 releases are kept, plus the published one.
  - **Journal.** Every attempt is logged (`journalctl -t deploy`): project, release, sha, run id, key fingerprint, client address, size and result.
  - **Rollbacks** are run on the server by the admin (`sudo site-rollback`), never by CI keys; the procedure is in private operations documentation.
- **Backends.** A project with a `backend` runs one container from a private or public image, deployed by CI with `ssh deploy@server.abrunacci.dev deploy-backend <sha> <digest> <run id>` (see "Deploying a backend").
  - **The image comes from `projects.yml`.** CI only sends the digest; `deploy-backend` pulls `<image>@<digest>`, so a key can only ever run its own project's image.
  - **Locked down like the other containers.** The container runs as the `backends` user (uid 10005) whatever its image declares, with a read-only filesystem, a `/tmp` tmpfs, no capabilities, no published port, and a memory limit (`memory`, 256 MB by default, no swap). It is on the `edge` network only, as `<name>-backend`, which is how Caddy reaches it. Every backend shares `edge` with Caddy and the other backends, so one could reach another's port directly, bypassing Caddy's `paths`: acceptable for a few projects of the same owner; a network per project, joined by Caddy, is the fix if that changes.
  - **Routing.** With `site: true`, Caddy sends the backend's `paths` (for example `/api/*`) to it and serves everything else from the static site. Without a site, every path goes to the backend. Request bodies are limited to 10 MB. While the container is recreated, Caddy holds requests for up to 15 s instead of failing them; before the first deploy, the backend's paths answer 502 after those 15 s. Caddy forces `Strict-Transport-Security` and `X-Content-Type-Options` and removes `Server` on every answer; `Referrer-Policy` and `Content-Security-Policy` are defaults the backend can replace with its own.
  - **Health and automatic way back.** After a deploy, the backend's `health` path must answer with a 2xx from Caddy's container within 60 s. If it does not, or the container stops or restarts, the previous release is put back and checked, and the deploy fails. A first deploy that fails leaves the backend stopped. The container's log is never sent to CI, whose logs may be public: it goes to the journal (`sudo journalctl -t backend-log`). There is no Docker healthcheck (an image may have no HTTP client), so a process that hangs without exiting is not restarted by itself: `sudo backend-status` is the check.
  - **Configuration.** `env` in `projects.yml` is public (`/opt/infra/projects/<name>/app.env`); `secrets` only names variables, whose values live in `/etc/infra/secrets/projects/<name>/secrets.env` (root only). `generated` values are created on the server by the playbook; `manual` ones are set by the admin with `sudo project-secret`. Neither ever passes through Ansible or the repo. Compose reads both files literally (`format: raw`). A deploy refuses to start while a declared secret has no value, or a value is set that `projects.yml` does not declare.
  - **Changes.** When `env`, `memory` or a secret changes, the next playbook run applies it (`backend-rollback <name> --apply`, under the deploy lock): the container is recreated and its health checked, with no automatic way back, since the image did not change. After `project-secret set`, `sudo backend-rollback <name> --restart` applies it at once. A new `image` takes effect at the next deploy; the history keeps the previous repository's releases, and rolling back to one of them runs that image.
  - **Retention and rollbacks.** The last 5 releases are kept, with their images, plus the one that was running before the latest deploy; the image of a failed deploy is removed. `sudo backend-rollback` moves back to any of them, with the same health check and way back, and shows a failed container's log in the terminal. Without a release name it goes to the one deployed before the current one in the history (`--list` shows the order). Database migrations are never undone.
  - **Journal.** Every deploy and rollback is logged (`journalctl -t deploy-backend`, `-t backend-rollback`), the log of a container that failed its health check (`-t backend-log`), and every secret change (`-t project-secret`, never the value).
- **Databases are never dropped by the playbook.** Before any change, it compares `projects.yml` with two sources: the server's registry (`/etc/infra/projects.json`, projects that had `database: true`) and PostgreSQL itself (every database except `postgres` and the templates, including one made by hand). A database whose project is gone from `projects.yml`, or now says `database: false`, stops the play until it is retired by hand. If PostgreSQL's data volume exists but PostgreSQL cannot be asked, the play stops too, instead of trusting the registry alone. A new server, without Docker or the volume, has no databases.
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
./play site.yml -K --diff
./play site.yml -K --diff                    # second run: expect only the recap, changed=0
```

`./play` is `ansible-playbook` with the run logged to a file of its own (see "Output and logs").

Every run asks for the admin user's sudo password (`-K`; `ansible.cfg` also sets `become_ask_pass`, so it is asked even without the flag). The first run on a new Droplet needs that password to be set on the server first; the playbook stops before changing anything if it is not.

`--check` only works fully once Docker is installed: on the first run, the Docker, Caddy and PostgreSQL tasks depend on packages that check mode does not install. `ansible-playbook site.yml -K --check --diff --tags base,hardening` previews the sudo, SSH and firewall changes, which are the ones that could lock you out. On a server that still has NOPASSWD, check mode cannot test the sudo password yet, and says so by skipping that check. Skipped tasks are hidden (see "Output and logs"), so run that preview with `ANSIBLE_DISPLAY_SKIPPED_HOSTS=true ./play site.yml -K --check --diff --tags base,hardening` to see it. Check mode also cannot show that a container will be recreated because a template it depends on changes: the template is not written, so Compose sees no difference.

### Output and logs

`ansible.cfg` keeps the output short: tasks that were `ok` or `skipped` are not shown. A run shows only what changed (with its diff under `--diff`), what failed, and the recap. An idempotence run prints nothing but the recap. Results are printed as YAML.

Every run is also logged outside the repo, in `~/notas/infra/corridas/`:
- `./play` writes each run to its own file (mode 0600), named after its UTC start time (`20260924T201500Z-ansible-playbook.log`). It creates the directory (mode 0700) if needed. It runs from `ansible/`, so relative paths in its arguments are relative to `ansible/`.
- `ansible-playbook` run directly appends to `ansible.log` in the same directory. If the directory does not exist, Ansible only warns and logs nothing.
- The log holds what the screen shows. Tasks with `no_log` are left out; the only one is the task that generates the PostgreSQL superuser password, whose value never appears in any argument or output anyway. The sudo password (`-K`) is never logged.
- `--diff` output is logged too. No template holds a secret today; a task that renders one must use `no_log: true` and `diff: false`, so it never reaches the screen or the log.
- `*.log` and `corridas/` are git-ignored, in case a log is ever pointed at the repo.

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

## Deploying a project

A project can be deployed once it has `site: true` and a `deploy_key` in `projects.yml`, and the playbook has run. Its repository needs an environment, two secrets and a workflow step. The steps below use cuanto-cuesta.

### 1. The deploy key

Generate it on your machine, one per project. It never goes anywhere except the project's GitHub environment:

```sh
ssh-keygen -t ed25519 -N "" -C "cuanto-cuesta-deploy" -f ~/cuanto-cuesta-deploy
cat ~/cuanto-cuesta-deploy.pub
```

The key has no passphrase because CI uses it unattended. It is restricted instead: it can only run `deploy.sh` for its project. Put the public key (the whole `.pub` line) in the project's `deploy_key` in `projects.yml`. Merge that, then apply it: `./play site.yml -K --diff --tags projects,deploy`. The first time after this deploy setup reaches the server, run the whole playbook instead (or add `hardening`), so the deploy user is also allowed to log in over SSH.

### 2. The server's host key, for known_hosts

```sh
ssh-keyscan -t ed25519 server.abrunacci.dev 2>/dev/null > ~/cuanto-cuesta-known_hosts
ssh-keygen -lf ~/cuanto-cuesta-known_hosts
```

Compare the fingerprint with the one the server reports, from the DigitalOcean Droplet Console (log in as `ops`):

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Use the file only if they match. With it, the workflow checks the server's identity (`StrictHostKeyChecking=yes`) instead of trusting whatever answers.

### 3. The GitHub environment

In the project's repository, go to **Settings → Environments → New environment**, and name it `production`. Then:

- **Deployment protection rules:** tick **Required reviewers** and add yourself. Leave **Prevent self-review** unticked, or you could never approve your own deploys. Every deploy then waits for your approval.
- **Deployment branches and tags:** choose **Selected branches and tags**, then **Add deployment branch or tag rule**, and enter `main`. No other branch can use the environment or its secrets.
- **Environment secrets:**
  - `DEPLOY_SSH_KEY`: the whole private key file (`~/cuanto-cuesta-deploy`), including its `BEGIN` and `END` lines.
  - `DEPLOY_KNOWN_HOSTS`: the line in `~/cuanto-cuesta-known_hosts`.

  They are environment secrets, not repository secrets, so only jobs that run in `production` see them.

The same secrets can be set from the command line:

```sh
gh secret set DEPLOY_SSH_KEY --env production --repo Abrunacci/cuanto-cuesta < ~/cuanto-cuesta-deploy
gh secret set DEPLOY_KNOWN_HOSTS --env production --repo Abrunacci/cuanto-cuesta < ~/cuanto-cuesta-known_hosts
```

Then delete the private key from your machine; GitHub holds the only copy, and a lost key is replaced with a new one:

```sh
shred -u ~/cuanto-cuesta-deploy
```

Plans: on public repositories all of this is available on any plan. On private repositories, deployment branch rules and rulesets need GitHub Pro or Team, and required reviewers need GitHub Enterprise.

### 4. Protecting main

Go to **Settings → Rules → Rulesets → New ruleset → New branch ruleset**:

- **Name:** `main`. **Enforcement status:** Active. **Bypass list:** empty, so the rules apply to you too.
- **Target branches:** **Add target → Include default branch**.
- **Rules:**
  - Tick **Restrict deletions** and **Block force pushes**.
  - Tick **Require a pull request before merging**, with **Required approvals** at 0 (with 1, you could not merge your own pull requests).
  - Tick **Require status checks to pass**, and add the CI jobs that must pass (their names from the Actions tab). Also tick **Require branches to be up to date before merging**.

With this, nothing reaches `main` without a pull request and green CI, and only `main` can deploy.

### 5. The workflow step

The workflow lives in the project's repository, with `permissions: {}` at the top so each job asks only for what it needs. Its deploy job runs only for pushes to `main`, in the `production` environment, after the checks and the build:

```yaml
  deploy:
    needs: [build]                 # the job that builds and checks the site
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    environment: production
    permissions:
      contents: read
    concurrency:
      group: deploy-production
      cancel-in-progress: false
    steps:
      # ... checkout and build, or download the build's artifact, into
      # frontend/dist, with actions pinned by commit SHA
      - name: Deploy
        shell: bash                # -eo pipefail: a failed tar fails the step
        env:
          DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
          DEPLOY_KNOWN_HOSTS: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
        run: |
          umask 077
          mkdir -p ~/.ssh
          printf '%s\n' "$DEPLOY_SSH_KEY" > ~/.ssh/deploy
          printf '%s\n' "$DEPLOY_KNOWN_HOSTS" > ~/.ssh/known_hosts
          tar -C frontend/dist -cz . \
            | ssh -i ~/.ssh/deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
                -o BatchMode=yes -o ConnectTimeout=15 \
                deploy@server.abrunacci.dev deploy "$GITHUB_SHA" "$GITHUB_RUN_ID"
```

The command is always `deploy <commit sha> <run id>`, and the archive's root is the site's root. The run id is optional for `deploy.sh`, so a manual test can leave it out; the workflow always sends it. The deploy prints `Deployed <project> release <id>`, or the reason it was rejected, and fails the job if it was.

## Deploying a backend

A backend is deployed with the same key, environment and secrets as the site (steps 1 to 4 above), once the project has a `backend` and a `deploy_key` in `projects.yml` and the playbook has run. CI builds and pushes the image, then sends its digest:

```sh
ssh -i ~/.ssh/deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15 \
  deploy@server.abrunacci.dev deploy-backend "$GITHUB_SHA" "sha256:<64 hex characters>" "$GITHUB_RUN_ID" </dev/null
```

It prints `Deployed backend <project> release <id> (<digest>)`, or the reason it failed, and fails the job if it did. When the new container was not healthy, its log is on the server only (`sudo journalctl -t backend-log`), never in CI's output. Deploy the backend before the site when both change, and keep database migrations compatible with the previous release: a rollback puts back the image, not the schema.

Before the first deploy, set the backend's manual secrets (below). The full guide for a project's repository (building and publishing the image to GHCR, cleaning old versions) comes with the first project that uses it.

### Pulling private images

A public image needs nothing. For private images in GHCR, the server logs in once with a GitHub personal access token (classic) whose only scope is `read:packages`, with an expiration date. Fine-grained tokens do not work with GHCR. Create it in **GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)**, write its expiration date in `terraform/README.md` ("Credentials"), and on the server:

```sh
sudo docker --config /etc/infra/secrets/registry login ghcr.io -u Abrunacci --password-stdin
# paste the token, press Enter, then Ctrl-D
```

It prints `Login Succeeded`. The credentials stay in `/etc/infra/secrets/registry/config.json` (root only), used only by `deploy-backend` and `backend-rollback`; they never leave the server. Before the token expires, create a new one and run the same command. A token that expired makes new deploys fail with `cannot pull ...: unauthorized`; what is running keeps running.

### Backend secrets

```sh
sudo project-secret <project> list          # declared names and whether each has a value
sudo project-secret <project> set KEY       # asks for the value without showing it
sudo project-secret <project> unset KEY
sudo project-secret <project> check
```

Only names declared in `projects.yml` as `manual` can be set. A value is one line, taken exactly as typed. It reaches the container at the next deploy, or at once with `sudo backend-rollback <project> --restart`.

### Backend status and rollbacks

```sh
sudo backend-status <project>               # release, container and health
sudo backend-rollback <project> --list      # releases, newest first; * is the deployed one
sudo backend-rollback <project>             # back to the release before the deployed one
sudo backend-rollback <project> RELEASE     # to that release
sudo backend-rollback <project> --restart   # recreate the deployed release
sudo backend-rollback <project> --apply     # apply configuration changes, if any (the playbook runs it)
```

### Removing a project's backend

When a project loses its `backend` (or leaves `projects.yml`), the next playbook run stops its container, and removes its compose files and its Caddy routes. Its secrets, its release history and its images stay, so a mistake is undone by putting the entry back and running the playbook again (it starts the last deployed release). Once sure, remove them by hand:

```sh
sudo rm -r /etc/infra/secrets/projects/<project> /var/lib/infra/backends/<project>
sudo docker image ls --digests <image>      # then: sudo docker image rm <image>@<digest> for each
```

A project with a database cannot be removed this way: see "Retiring a project with a database".

## Retiring a project with a database

Taking a project out of `projects.yml`, or setting its `database` to `false`, makes every playbook run fail with this message, before anything changes:

```
projects.yml no longer declares database: true for a project whose database is still on the server (...). The playbook never drops a database, and it does not run until each one is retired by hand ...
```

This is on purpose: removing a line from a file must never be enough to lose data. The failure lists the projects found in the server's registry and the databases found in PostgreSQL. Its database name is the project's name with `-` turned into `_`.

The database is retired by hand, on the server, and only then does the playbook run again. The full procedure, with a `project-db retire` command that takes a final dump, stops the backend and drops the database, its roles, its secrets and its entry in `/etc/infra/projects.json`, arrives with per-project databases: the playbook does not create any yet. Until then, a database on the server can only have been created by hand, and is retired by hand:

```sh
# On the server. Dump it first if it holds anything worth keeping, and copy the dump off the server.
(umask 077; sudo docker compose --project-directory /opt/infra/postgres exec -T postgres \
  pg_dump -U postgres -Fc NAME > NAME.dump)
sudo docker compose --project-directory /opt/infra/postgres exec -T postgres \
  psql -U postgres -c 'DROP DATABASE "NAME"'
```

A project listed under the registry but whose database is missing from PostgreSQL is a different case: its data was lost (for example, the volume was recreated). The remedy is restoring the backup, not retiring it.

`--skip-tags always` or `--skip-tags projects_databases` would skip this check: never use them to get past this failure.

### When the databases cannot be listed

Once PostgreSQL's data volume exists, the check needs PostgreSQL to answer. If it cannot ask (Docker stopped, the container stopped or failing), the play stops with `Cannot tell which databases exist on the server`, followed by the cause and what to run: start Docker, start the container, or read its log.

If the fix is in the playbook itself (the `docker` role must reinstall Docker, or a change to the `postgres` role is what makes PostgreSQL fail), run only those roles, skipping the database check alone: they create and start things, but never touch projects or databases. `projects.yml` is still checked, and facts are still gathered (`--skip-tags always` would skip those too, and the `docker` role needs them).

```sh
./play site.yml -K --diff --tags docker,postgres --skip-tags projects_databases
```

The `projects` role refuses to run when the database check was skipped, so this bypass cannot reach the projects or rewrite the server's registry. Then run the whole playbook as usual; the check runs again.

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

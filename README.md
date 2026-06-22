# server_mgmt

Ansible playbook for managing self-hosted servers running:

- **Static landing page** at `/`
- **Nextcloud** at `/cloud`
- **Forgejo** at `/git` (HTTP) and `:2222` (SSH)
- **Collabora Online** (document server, secondary)
- **EuroOffice Document Server** (document server, primary)

Everything runs as rootless Podman containers under a dedicated `containers`
system user. Traefik handles TLS (Let's Encrypt HTTP-01) and reverse-proxies
all services from a single domain.

---

## Prerequisites

Each target host needs:

- A `containers` system user with lingering enabled and a working rootless
  Podman setup — follow **PODMAN-README.md** once per host before running the
  playbook.
- A public DNS A record pointing your domain at the server's IP (needed for
  Let's Encrypt to issue a certificate).
- Ports 80, 443, and 2222 reachable from the internet.

---

## What to change before first run

### 1. Add a host directory

Create `ansible/host_vars/<your-hostname>/` (a directory, not a single file)
containing two files: `vars.yml` for plain config and `vault.yml` for secrets.
Copy from the examples:

```sh
mkdir ansible/host_vars/myserver
cp ansible/host_vars/example-server.yml ansible/host_vars/myserver/vars.yml
cp ansible/host_vars/spqr-project/vault.yml.example ansible/host_vars/myserver/vault.yml
$EDITOR ansible/host_vars/myserver/vars.yml
$EDITOR ansible/host_vars/myserver/vault.yml   # fill in every value, then encrypt
ansible-vault encrypt ansible/host_vars/myserver/vault.yml
```

Fields to fill in `vars.yml`:

| Field | What to put |
|---|---|
| `ansible_host` | Server IP or resolvable hostname |
| `ansible_user` | Your SSH login user |
| `ansible_ssh_private_key_file` | Path to your SSH key (e.g. `~/.ssh/id_ed25519`) |
| `domain` | Your public domain, e.g. `example.com`. All services share this domain. |

The host `vault.yml` holds all per-instance secrets: database passwords,
admin credentials, and (when Authelia is enabled) OIDC secrets and the user
list. Each host has its own vault — instances never share secrets or user lists.
The `vault.yml.example` file lists every variable with a generator command.

One `host_vars/<host>/` directory per server. If a server runs only some
services, edit `ansible/site.yml` to limit which roles apply (use `hosts:` with
a specific hostname or a group).

### 2. Create and encrypt the vaults

There are two vault files:

**Global vault** — shared across all hosts (only truly shared secrets, e.g.
the ACME email for Let's Encrypt):

```sh
cd ansible
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml
ansible-vault encrypt group_vars/all/vault.yml
```

**Per-host vault** — instance-specific secrets and Authelia users (done in the
step above as part of creating the host directory).

Both vaults are gitignored and must never be committed unencrypted.

Optionally, save the vault password in `.vault_pass` (already in `.gitignore`)
so you don't have to type it every run:

```sh
echo "your-vault-password" > .vault_pass
chmod 600 .vault_pass
```

### 3. Check image versions

`ansible/group_vars/all/vars.yml` pins every image to a `major.minor` tag.
Before deploying, verify the pinned tags are still current — especially Forgejo,
which has a short support window (~3 months per non-LTS release):

- Forgejo releases: <https://forgejo.org/releases/>
- Nextcloud: <https://hub.docker.com/_/nextcloud>
- Traefik: <https://hub.docker.com/_/traefik>

---

## Running the playbook

Ansible SSHes in as your personal user and uses `sudo` for privileged tasks.
You need to supply both your vault password and your sudo password:

```sh
cd ansible

# Standard run - prompts for vault password then sudo password:
ansible-playbook site.yml --ask-vault-pass --ask-become-pass

# With a vault password file (only sudo prompt remains):
ansible-playbook site.yml --vault-password-file ../.vault_pass --ask-become-pass

# Limit to a single host:
ansible-playbook site.yml --vault-password-file ../.vault_pass --ask-become-pass --limit spqr-project

# Limit to a single role (e.g. after updating Forgejo config):
ansible-playbook site.yml --vault-password-file ../.vault_pass --ask-become-pass --tags forgejo
```

If you want to avoid typing the sudo password every run, add it to the vault:

```sh
# In vault.yml, add:
vault_become_pass: "your_sudo_password"

# In group_vars/all/vars.yml, add:
ansible_become_pass: "{{ vault_become_pass }}"
```

Then you only need `--vault-password-file` and no `--ask-become-pass`.

---

## What each role does

### `traefik`

The only container with host ports (80, 443, 2222). Discovers all other
containers via the rootless Podman API socket and routes traffic based on
`traefik.*` labels. Issues and renews TLS certificates automatically via
Let's Encrypt HTTP-01. Also TCP-forwards Forgejo's git-over-SSH on port 2222.

### `static_site`

Nginx serving a read-only bind-mount from `roles/static_site/files/site/`.
Acts as the catch-all router (matches everything that `/cloud` and `/git`
don't claim). Replace `index.html` with your actual landing page content.

### `nextcloud`

Three containers: the Nextcloud app (Apache variant), MariaDB, and Valkey
(a Redis-compatible cache with a permissive open-source licence).

Mounted at `/cloud` via Traefik's StripPrefix middleware — Nextcloud receives
requests at `/` and rebuilds `/cloud` URLs itself via the `OVERWRITEWEBROOT`
env var.

> **Note:** Nextcloud does not officially support subpath installs. This setup
> works in practice but may break on major upgrades. If you hit issues, the
> fallback is a dedicated subdomain (`cloud.example.com`).

### `forgejo`

Two containers: Forgejo app and its own MariaDB instance. Mounted at `/git`
via Traefik's StripPrefix middleware — Forgejo receives requests at `/` and
reconstructs `/git` URLs itself via `ROOT_URL` in `app.ini`.

SSH git access is on port 2222 (TCP-forwarded through Traefik):

```sh
# Clone explicitly with port:
git clone ssh://git@example.com:2222/owner/repo.git

# Or add to ~/.ssh/config to use plain git@ remotes:
Host example.com
    Port 2222
```

### `authelia`

Single sign-on identity provider (OIDC). On by default (`enable_authelia: true`).
Serves at `https://<domain>/auth`. Users log in here once and the token is
accepted by both Nextcloud and Forgejo. See the
[Authelia SSO](#authelia-sso-oidc-single-sign-on) section below and
**EXPERIMENTAL-SSO-SMTP.md** for setup, user management, and the password-change
workflow.

### `collabora`

Collabora Online document server (secondary). Connected to Nextcloud via the
`richdocuments` app. Runs on the internal `edge` network; not exposed directly.

### `eurooffice`

EuroOffice Document Server (primary, ONLYOFFICE-compatible). Connected to
Nextcloud via the `eurooffice` app. Like Collabora it runs on the internal
network only. Both document servers are deployed; Nextcloud uses EuroOffice
by default — Collabora is available as a fallback.

---

## Authelia SSO (OIDC single sign-on)

> **Status: on by default** (`enable_authelia: true` in
> `group_vars/all/vars.yml`). Authelia is the **preferred login method** for
> all regular users. The local admin accounts (set in the vault) bypass
> Authelia and are used only for initial setup or emergency access. See
> **EXPERIMENTAL-SSO-SMTP.md** for the full setup and password-change guide.

Authelia provides a **single login shared across Nextcloud and Forgejo**: users
authenticate once at `https://<domain>/auth` and the OIDC token is accepted by
both apps. It also provides a reusable forward-auth middleware for protecting
any other route that has no login of its own.

### Architecture

```
Browser → Traefik → https://<domain>/auth  →  Authelia portal + OIDC provider
                  → https://<domain>/cloud  →  Nextcloud  ─┐
                  → https://<domain>/git    →  Forgejo    ─┴─ delegate login to Authelia via OIDC
```

Authelia is deployed as a single container on the `edge` network, served under
`/auth` on the main domain (no extra subdomain needed). It acts as an OpenID
Connect provider; Nextcloud and Forgejo are pre-registered as OIDC clients.

### The Authelia portal (`/auth`)

`https://<domain>/auth` is the Authelia user-facing portal. From here users can:

- Log in (the SSO entry point — clicking "Sign in with authelia" in Forgejo or
  "Log in with Authelia" in Nextcloud both redirect here first).
- Manage TOTP second factor (if configured).
- **Reset their password** — generates a reset token and either emails it (when
  `enable_smtp: true`) or writes it to `/config/notification.txt` inside the
  Authelia container. Without SMTP the admin must retrieve the token and pass it
  to the user out-of-band:
  ```bash
  sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
    podman exec authelia cat /config/notification.txt
  ```
  The printed URL contains the reset token; send it to the user manually.

### User management (approval workflow)

There is **no self-service registration**: a person can log in only if you have
explicitly added them to the `authelia_users` list in your **per-host**
encrypted vault. Adding someone to that list *is* the approval step. Because the
list is per host, each instance (`spqr-project`, …) has its own users — they are
not shared.

```yaml
# In host_vars/<host>/vault.yml (encrypted):
authelia_users:
  - username: "alice"
    displayname: "Alice Rossi"
    email: "alice@polimi.it"
    password_hash: "$argon2id$v=19$..."   # generated with authelia crypto hash
    groups: [users]
```

The `password_hash` is required and is the source of truth — a username with no
hash makes Authelia refuse to start (the role asserts this up front). Generate
it with:

```bash
podman run --rm docker.io/authelia/authelia:4.39 \
  authelia crypto hash generate argon2 --password 'TheirPassword'
```

Re-run the playbook after any change. To revoke access: set `disabled: true` or
remove the entry entirely. See **EXPERIMENTAL-SSO-SMTP.md** for the full
password-change workflow (the vault hash must be updated, or a redeploy reverts
any change made only inside the container).

### Linking existing accounts

If a user already has a local Nextcloud/Forgejo account, OIDC login maps onto it
rather than creating a duplicate, **provided the email/username match** the
`authelia_users` entry:

- **Forgejo** prompts for the existing password once on first OIDC login to link
  the accounts (visible afterwards under Settings → Security).
- **Nextcloud** keys on the `preferred_username` claim (`--mapping-uid`), so the
  same username lands in the same account. Nextcloud has no per-user "linked
  accounts" UI — confirm with `occ user:list` (no duplicate) and `occ user:info`.

### Enabling it

1. Generate secrets (see EXPERIMENTAL-SSO-SMTP.md §2.1) and fill them into the
   per-host vault, along with at least one `authelia_users` entry.
2. `enable_authelia: true` is already the default in `group_vars/all/vars.yml`.
   If you turned it off, flip it back there or override it in
   `host_vars/<host>/vars.yml`.
3. Run the playbook.

### SMTP relay (per-host, optional)

SMTP enables password-reset emails from Authelia (and mailer support in
Nextcloud and Forgejo). It is off by default (`enable_smtp: false` in
`group_vars/all/vars.yml`) and configured **per host** — each instance can use
a different relay. To enable it for one host, add to
`host_vars/<host>/vars.yml`:

```yaml
enable_smtp: true
smtp_host: "smtp.polimi.it"   # your relay
smtp_port: 587
smtp_security: "starttls"     # starttls (587) | tls (465) | none (25)
smtp_from: "noreply@example.com"
```

And in `host_vars/<host>/vault.yml` (encrypted):

```yaml
vault_smtp_user:     ""   # leave blank for unauthenticated on-campus relays
vault_smtp_password: ""
```

Without SMTP, Authelia writes password-reset tokens to
`/config/notification.txt` inside its container. Retrieve the link and
forward it to the user manually:

```bash
sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
  podman exec authelia cat /config/notification.txt
```

### Implementation notes (same-host OIDC quirks)

Because Authelia, Nextcloud and Forgejo all run on one host behind one domain,
the roles handle two non-obvious issues automatically:

- **`/etc/hosts` hairpin.** Podman copies the host's `/etc/hosts`, which maps the
  FQDN to `127.0.1.1`. Server-side OIDC calls (discovery fetch, token exchange)
  would dial loopback and fail. The Forgejo and Nextcloud containers get an
  `etc_hosts` override mapping the domain to the real host IP, so those calls
  reach Traefik's published `:443` with a valid certificate.
- **Nextcloud SSRF block.** Nextcloud's HTTP client refuses to contact
  local/same-host addresses by default, raising `LocalServerException`
  ("Could not reach the OpenID Connect provider"). The role sets
  `allow_local_remote_servers=true` when Authelia is enabled.
- **Traefik backend refresh.** Authelia gets a fresh container IP on each
  deploy, so the role restarts Traefik right after (re)creating Authelia to
  avoid a stale-backend `502` during the Forgejo/Nextcloud OIDC registration.
  Likewise, manually restarting any app container needs a Traefik restart after.

### Forward-auth for bare routes

Any route with no login of its own can be protected by attaching the
`authelia@docker` middleware on that container's Traefik labels:

```yaml
traefik.http.routers.<name>.middlewares: "authelia@docker"
```

Unauthenticated requests are redirected to the Authelia portal first.

---

## After deployment

### Let's Encrypt certificates

Traefik requests certificates from **Let's Encrypt production** immediately on
first deploy. Certificates are stored in `/etc/traefik/letsencrypt/acme.json`
on the host (bind-mounted into the Traefik container) and renewed automatically.

If you want to test the stack before going live (e.g. to avoid hitting
Let's Encrypt's rate limits during iteration), add the staging CA flag to the
`Run traefik` task in `roles/traefik/tasks/main.yml`:

```yaml
- "--certificatesresolvers.letsencrypt.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory"
```

Staging issues untrusted certs but has no rate limits. When you're ready for
production, remove that line, re-run the traefik role, and delete `acme.json`
so a fresh certificate is requested:

```sh
# On the server, as the containers user:
rm /etc/traefik/letsencrypt/acme.json
systemctl --user restart container-traefik.service
```

### Automatic image updates

The traefik role enables `podman-auto-update.timer`, which checks daily for
new patch releases published under the same `major.minor` tag and restarts
affected containers. To bump a major or minor version, update the tag in
`group_vars/all/vars.yml` and re-run the relevant playbook.

### Nextcloud major version upgrades

Nextcloud refuses to skip a major version. Upgrade one major version at a
time: update the image tag, run the playbook, wait for the upgrade to
complete, then repeat for the next major version.

---

## Nextcloud subpath install notes

Nextcloud does not officially support running under a subpath (`/cloud` instead
of the domain root). The setup works in practice but requires several hacks that
are all baked into the role — documented here so you know what to touch if
something breaks after a Nextcloud upgrade.

### 1. Traefik StripPrefix + OVERWRITE* env vars (the core trick)

Traefik routes `https://<domain>/cloud/…` to the Nextcloud container but
**strips the `/cloud` prefix** before forwarding, so Nextcloud receives every
request at `/` (which is what it expects). Nextcloud then rebuilds all URLs it
generates using three env vars:

| Env var | Value | Purpose |
|---|---|---|
| `OVERWRITEWEBROOT` | `/cloud` | Prepends `/cloud` to every internal URL Nextcloud generates |
| `OVERWRITEHOST` | `<domain>` | Overrides the `Host` Nextcloud sees (needed behind a proxy) |
| `OVERWRITEPROTOCOL` | `https` | Forces HTTPS in generated URLs regardless of what reaches the container |

Without `OVERWRITEWEBROOT`, Nextcloud would generate links pointing at the
domain root and all redirects and asset URLs would break.

### 2. CLI URL (overwrite.cli.url)

The `overwrite.cli.url` system config is set to `https://<domain>/cloud/` via
`occ config:system:set`. This is used by background jobs and CLI commands that
need to generate absolute URLs outside of an HTTP request context. Without it,
cron jobs and some admin self-checks emit bare-domain URLs.

> **Known cosmetic issue:** the container cannot reach the public URL from inside
> itself (hairpin NAT). Some admin panel self-tests will show "could not check"
> or "not reachable" — the actual features work fine; only internal reachability
> tests are affected.

### 3. Federation discovery routes at the domain root

Two Nextcloud endpoints (`/ocm-provider` and `/ocs-provider`) must be served at
the **domain root**, not under `/cloud`, for federation with other Nextcloud
instances. They each get their own Traefik router with no StripPrefix, so
requests go straight to Nextcloud unmodified. Attempting to combine these into
one router with an `||` rule in the Traefik label causes Traefik v3 to silently
reject the entire container's label set, so they are intentionally two separate
routers.

### 4. notify_push (Client Push) path

The high-performance push daemon runs inside the Nextcloud container on port
7867. Its public path is `https://<domain>/cloud/push`, stripped to `/` before
reaching the daemon. This requires a dedicated Traefik router+service with its
own StripPrefix (`/cloud/push`). With two services on one container (port 80 and
port 7867), Traefik v3 requires **explicit `traefik.http.routers.*.service`
labels** on all routers — without them Traefik refuses to auto-link any router
and silently drops them all.

### What to check after a Nextcloud major upgrade

If things break after bumping the image tag, go through this list:

1. Check `OVERWRITEWEBROOT` is still respected (some major versions change how
   the env var is read — verify links in the UI include `/cloud`).
2. Check `/ocm-provider` and `/ocs-provider` still resolve at the domain root.
3. Check `/cloud/push` returns HTTP 200 (`curl -I https://<domain>/cloud/push`).
4. If the admin panel shows new warnings, run:
   ```sh
   podman exec --user www-data nextcloud php /var/www/html/occ maintenance:repair --include-expensive
   ```

---

## Repository structure

```
deploy.sh                  # Convenience wrapper around ansible-playbook
ansible/
  ansible.cfg              # Ansible configuration (sets inventory = inventory.yml)
  inventory.yml            # Host list — add your servers here
  site.yml                 # Master playbook (runs all roles in order)
  group_vars/all/
    vars.yml               # Image tags and shared non-secret config
    vault.yml.example      # Template for secrets (copy → vault.yml, encrypt)
    vault.yml              # ENCRYPTED secrets - never commit unencrypted
  host_vars/
    example-server.yml     # Template for per-server config (copy and rename)
    <your-server>.yml      # One file per managed server
  roles/
    traefik/tasks/main.yml            # Reverse proxy + TLS
    static_site/tasks/main.yml        # Landing page (nginx)
    static_site/files/site/index.html # Landing page HTML - edit freely
    nextcloud/tasks/main.yml          # Nextcloud + MariaDB + Valkey
    forgejo/tasks/main.yml            # Forgejo + MariaDB
    collabora/tasks/main.yml          # Collabora Online document server
    eurooffice/tasks/main.yml         # EuroOffice document server (primary)
    authelia/tasks/main.yml           # SSO/OIDC provider (experimental, off by default)
README.md                  # This file
EXPERIMENTAL-SSO-SMTP.md   # Full setup guide for Authelia + SMTP (experimental)
PODMAN-README.md           # One-time host setup (rootless Podman + containers user)
```

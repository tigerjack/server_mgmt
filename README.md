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

**Global vault** — contains only `acme_email` (the Let's Encrypt registration
address, same for all hosts). Everything else is per-host:

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

Use the wrapper script from the repo root:

```sh
./deploy.sh                        # full run
./deploy.sh --limit spqr-project   # single host
./deploy.sh --tags forgejo         # single role
```

The script auto-detects credentials:

- **Vault password** — if `.vault_pass` exists next to `deploy.sh`, it is used
  automatically (no interactive prompt). Otherwise you are asked for it.
  Save the vault password there once:
  ```sh
  echo "your-vault-password" > .vault_pass
  chmod 600 .vault_pass   # already in .gitignore
  ```
- **Sudo password** — if `ansible_become_pass` is wired up in `group_vars`
  (via `vault_become_pass` in the vault), sudo is handled automatically.
  Otherwise you are prompted. To stop being asked, add to the vault and wire it:
  ```sh
  # host_vars/<host>/vault.yml:
  vault_become_pass: "your_sudo_password"

  # group_vars/all/vars.yml:
  ansible_become_pass: "{{ vault_become_pass }}"
  ```

Any extra flags are forwarded to `ansible-playbook`, so `--limit`, `--tags`,
`--check`, etc. all work as usual.

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
# Clone explicitly with the port:
git clone ssh://git@example.com:2222/owner/repo.git
```

Add a `~/.ssh/config` entry on your local machine to avoid specifying the port
every time and to select the right key:

```
Host example.com
    User git
    Port 2222
    IdentityFile ~/.ssh/id_ed25519   # the key registered in your Forgejo profile
```

With that block in place you can use the short form everywhere — clone, push,
pull, and `git remote add` — without the explicit `ssh://git@…:2222` prefix:

```sh
git clone example.com:owner/repo.git
git remote add origin example.com:owner/repo.git
```

### `authelia`

Single sign-on identity provider (OIDC). On by default (`enable_authelia: true`).
Serves at `https://<domain>/auth`. Users log in here once and the token is
accepted by both Nextcloud and Forgejo. See the
[Authelia SSO](#authelia-sso-oidc-single-sign-on) section below for setup,
user management, and the password-change workflow.

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
> Authelia and are used only for initial setup or emergency access.

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
remove the entry entirely.

#### Adding a user without running the playbook

If you need to give someone access immediately, edit the live file on the server
directly. The file backend runs with `watch: true`, so Authelia hot-reloads the
file on change — no restart needed:

1. Generate the hash (on the server or your local machine):
   ```bash
   podman run --rm docker.io/authelia/authelia:4.39 \
     authelia crypto hash generate argon2 --password 'TheirPassword'
   ```
2. Edit the file **as the `containers` user** so ownership is preserved:
   ```bash
   sudo -u containers nano /etc/authelia/users_database.yml
   ```
   > **Critical:** do NOT edit with plain `sudo nano`. That saves the file owned
   > by `root`, after which Authelia (running as `containers`) can no longer read
   > it — the watcher's reload fails with `permission denied` and Authelia keeps
   > the *old* data in memory (e.g. a stale email, so reset mail keeps going to
   > the old address). If you already did this, fix ownership:
   > ```bash
   > sudo chown containers:containers /etc/authelia/users_database.yml
   > sudo chmod 600 /etc/authelia/users_database.yml
   > ```

   Add the new entry under `users:` (note: the key in this file is `password`,
   not `password_hash`):
   ```yaml
     newuser:
       displayname: "New User"
       password: "$argon2id$v=19$..."
       email: "newuser@example.com"
       groups:
         - users
   ```
3. Save. Authelia reloads within a second or two. **Confirm the reload was
   clean** — a YAML error *or a permission-denied* keeps the old data in memory:
   ```bash
   sudo journalctl _SYSTEMD_USER_UNIT=container-authelia.service -n 10
   ```
   You want a successful reload line and no `Error occurred during reload`. If
   the change still isn't applied, restart Authelia **and Traefik** — restarting
   Authelia alone gives it a new container IP and leaves Traefik serving a 502
   until it re-discovers (see RUNBOOK.md for the `scont` helper used here):
   ```bash
   scont systemctl --user restart container-authelia.service
   scont systemctl --user restart container-traefik.service
   ```

> **Make it permanent:** the next playbook run overwrites this file from the
> vault. Before then, add the entry to `host_vars/<host>/vault.yml`
> (`ansible-vault edit`) using `password_hash` instead of `password`:
> ```yaml
> - username: "newuser"
>   displayname: "New User"
>   email: "newuser@example.com"
>   password_hash: "$argon2id$v=19$..."
>   groups: [users]
> ```

### Changing a password — and why the vault is the source of truth

The `password_hash` in the vault is the **authoritative** copy. The playbook
renders `users_database.yml` from `authelia_users` on every run and overwrites
the file inside the container. This has one important consequence:

> **Anything that changes a password *only* inside the container is temporary.**
> The next `ansible-playbook` run re-renders `users_database.yml` from the vault
> and reverts to the hash stored there — the user is then locked out with their
> old password.

So a password change is **not** complete until the new hash is back in the vault.

**A. Admin changes it (recommended, works without SMTP):**

1. Generate a new hash:
   ```bash
   podman run --rm docker.io/authelia/authelia:4.39 \
     authelia crypto hash generate argon2 --password 'TheNewPassword'
   ```
2. Replace that user's `password_hash` in the vault:
   ```bash
   ansible-vault edit host_vars/<host>/vault.yml
   ```
3. Re-run the playbook. Done — vault and container now agree.

**B. User self-resets via the portal (requires SMTP configured):**

If `enable_smtp` is on, the portal's *Forgot password?* link emails a reset
token; completing it rewrites `users_database.yml` **inside the container only**.
That works immediately, but to survive the next deploy you must pull the new
hash back into the vault:

1. Read the hash Authelia just wrote. The user file is bind-mounted from the
   host, so read it directly (note: the key in this file is `password`):
   ```bash
   sudo grep -A5 'USERNAME' /etc/authelia/users_database.yml
   ```
2. Copy that user's new `password` field into `password_hash` in
   `host_vars/<host>/vault.yml` (`ansible-vault edit`).
3. Re-run the playbook so vault and container stay in sync.

Until you do steps 2–3, treat the reset as provisional: a redeploy will undo it.

> **During a testing phase, prefer method B.** Don't ask users to send you a
> password or a hash — they have no easy way to generate an argon2 hash, and you
> don't want plaintext passwords landing in your inbox. Instead let each user
> self-reset through the portal (they pick a password you never see), then you
> **harvest the resulting hash** from `users_database.yml` (step 1 above) and
> fold it into the vault. The hash is safe to handle and store in the vault; the
> plaintext stays with the user. Do the harvest once per user before the next
> deploy, or batch it just before you redeploy — any un-harvested reset is
> reverted by the playbook.

> **Future upgrade path:** this file-backend friction scales fine to a few dozen
> users. When self-service password management becomes a real need, switch
> Authelia's `authentication_backend` from `file` to **LDAP** (e.g.
> lldap/OpenLDAP): users then own their passwords in the directory, the vault no
> longer holds hashes, and the whole revert problem disappears — without touching
> anything in Nextcloud or Forgejo.

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

1. Open `host_vars/<host>/vault.yml.example` — every variable has an inline
   comment explaining what it is, who uses it, and how to generate it. The
   non-obvious ones are summarised below.

   **Four independent random secrets** (each a different internal purpose):
   ```bash
   openssl rand -hex 32   # run four times, one result per secret
   ```
   | Variable | Purpose |
   |---|---|
   | `vault_authelia_session_secret` | Signs the browser session cookie |
   | `vault_authelia_storage_encryption_key` | Encrypts Authelia's SQLite database (TOTP keys, remember-me tokens) |
   | `vault_authelia_jwt_secret` | Signs password-reset tokens |
   | `vault_authelia_oidc_hmac_secret` | Used in OIDC token derivation |

   **OIDC issuer signing key** (`vault_authelia_oidc_jwks_key`):
   ```bash
   openssl genrsa 4096
   ```
   This is an RSA private key. Authelia uses it to **sign the JWT tokens** it
   issues to Nextcloud and Forgejo after a successful login; each app verifies
   the signature against the matching public key, which Authelia publishes
   automatically at `https://<domain>/auth/.well-known/jwks.json`. Paste the
   entire PEM output (including `BEGIN`/`END` lines) into the vault, indented
   by two spaces under the block scalar `|`. **Do not share this key across
   instances** — generate a fresh one per server.

   **OIDC client secrets** — one matched (plaintext + hash) pair per app:
   ```bash
   # Run once for Forgejo, once for Nextcloud:
   podman run --rm docker.io/authelia/authelia:4.39 \
     authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 48
   # -> "Random Password" = *_client_secret     (plaintext, sent to the app)
   # -> "Digest"          = *_client_secret_hash (hash, stored in Authelia)
   ```
   Authelia stores only the hash; the plaintext goes into the app's OIDC
   configuration (Forgejo admin panel, Nextcloud user_oidc app).

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
smtp_host: "smtp-relay.brevo.com"   # your relay — see below
smtp_port: 587
smtp_security: "starttls"           # starttls (587) | tls (465) | none (25)
smtp_from: "noreply@yourdomain.com" # must be on an authenticated domain
```

And in `host_vars/<host>/vault.yml` (encrypted):

```yaml
vault_smtp_user:     "your-relay-login"
vault_smtp_password: "your-relay-password-or-api-key"
```

#### Choosing a relay — Brevo (recommended, free)

Direct SMTP from the server IP is rejected by most mail providers. A free
relay is the practical solution. **[Brevo](https://www.brevo.com)** offers
300 emails/day (9,000/month) permanently on the free tier, with full SMTP
relay support — more than enough for password-reset and notification emails
on a small team server.

**Important:** since February 2024, all major mail providers (Gmail, Outlook,
university mail servers) require **SPF, DKIM and DMARC** records on the
sender domain. Mail from an unauthenticated domain is silently dropped or
rejected. This means:

- You cannot send `From: noreply@<your-polimi-subdomain>` unless Polimi IT
  adds the DNS records (they are unlikely to do this).
- **Use a domain you control** for `smtp_from` (e.g. a personal or project
  domain registered with any registrar). Add the three DNS records Brevo
  provides in your registrar's DNS panel — this takes minutes and no IT
  department involvement.

**Setup steps:**

1. Create a free account at [brevo.com](https://www.brevo.com).
2. Settings → Senders & IP → Domains → **Add a domain** (use a domain you
   control, not the Polimi subdomain).
3. Brevo shows three DNS records (SPF, DKIM, DMARC). Add them in your
   registrar's DNS panel. Notes:
   - **SPF:** merge with any existing SPF record — never have two SPF TXT
     records on the same name. Combine as:
     `v=spf1 include:_spf.aruba.it include:spf.brevo.com ~all`
   - **DMARC:** if one already exists, merge the two into one record.
4. Click **Verify** in Brevo (propagation is usually 15–30 min, up to 48h).
5. Settings → SMTP & API → SMTP → **Generate a new SMTP key**. Copy it
   (shown only once).
6. Security → Authorized IPs → add your server's public IP
   (`curl -sS https://api.ipify.org`), then enable IP blocking.
7. Fill in `host_vars/<host>/vars.yml` and vault as above, with
   `smtp_host: "smtp-relay.brevo.com"` and `smtp_from` on your verified
   domain.

**Test before redeploying** (replace values with your own):

```bash
swaks \
  --to 'you@example.com' \
  --from 'noreply@yourdomain.com' \
  --server smtp-relay.brevo.com \
  --port 587 --tls \
  --auth LOGIN \
  --auth-user 'your-brevo-email' \
  --auth-password 'your-smtp-key' \
  --header 'Subject: Brevo SMTP test' \
  --body 'Relay is working.'
```

#### Without SMTP

Authelia writes password-reset tokens to `/config/notification.txt` inside
its container. Retrieve the link and forward it to the user manually:

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

### Caveats and operational notes

- **Authelia schema version.** The config targets Authelia **4.39**. If you pin
  a different tag, verify compatibility — the usual breaking points between
  releases are the `server.address` path syntax, the `jwks` key structure under
  `identity_providers.oidc`, and the notifier address scheme (e.g.
  `submission://` vs `smtp+starttls://`). Check container logs after a version
  bump:
  ```bash
  sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
    podman logs authelia
  ```
- **Subpath OIDC issuer.** Because Authelia is under `/auth`, the issuer is
  `https://<domain>/auth` and discovery is at
  `https://<domain>/auth/.well-known/openid-configuration`. If an app complains
  about an issuer mismatch, check this prefix first.
- **Forgejo auth source idempotency.** The role adds the `authelia` OIDC source
  only if it does not already appear in `forgejo admin auth list`. If you change
  the client secret later, remove and re-add the source:
  `forgejo admin auth delete-oauth --id <id>`, then re-run the playbook.
- **Nextcloud groups.** `user_oidc` maps `preferred_username`, `email`, and
  `name` from the OIDC token. Group sync from Authelia is not wired — Authelia
  groups flow in the token but Nextcloud ignores them. Manage group membership
  manually in Nextcloud if needed.
- **Bind-mount permissions.** Authelia writes `db.sqlite3` and (without SMTP)
  `notification.txt` into `/etc/authelia`. If it logs permission errors under
  rootless Podman, check ownership of `/etc/authelia` (`containers` user).

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
    authelia/tasks/main.yml           # SSO/OIDC provider (on by default)
README.md                  # This file
RUNBOOK.md                 # Operational runbook: logs, diagnostics, common fixes
PODMAN-README.md           # One-time host setup (rootless Podman + containers user)
```

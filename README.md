# server_mgmt

Ansible playbook for managing self-hosted servers running:

- **Static landing page** at `/`
- **Nextcloud** at `/cloud`
- **Forgejo** at `/git` (HTTP) and `:2222` (SSH)
- **Collabora Online** + **EuroOffice Document Server** (document editing in Nextcloud)
- **Authelia** single sign-on at `/auth` (OIDC, on by default)

Everything runs as rootless Podman containers under a dedicated `containers`
system user. Traefik handles TLS (Let's Encrypt HTTP-01) and reverse-proxies
all services from a single domain.

---

## Table of contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Deployment guide](#deployment-guide) — start here for a new host
  - [1. Prepare the host](#1-prepare-the-host)
  - [2. Register the host in the inventory](#2-register-the-host-in-the-inventory)
  - [3. Create the host config and secrets](#3-create-the-host-config-and-secrets)
  - [4. Create the global vault](#4-create-the-global-vault)
  - [5. Generate Authelia / OIDC secrets](#5-generate-authelia--oidc-secrets)
  - [6. Verify image versions](#6-verify-image-versions)
  - [7. Run the playbook](#7-run-the-playbook)
  - [8. Verify the deployment](#8-verify-the-deployment)
- [Services reference](#services-reference) — what each role does
- [Authelia SSO](#authelia-sso-oidc-single-sign-on) — users, passwords, linking
- [SMTP relay (optional)](#smtp-relay-optional)
- [Day-2 operations](#day-2-operations) — certificates, upgrades
- [Nextcloud subpath install notes](#nextcloud-subpath-install-notes)
- [Repository structure](#repository-structure)
- **[RUNBOOK.md](RUNBOOK.md)** — logs, diagnostics, common fixes
- **[FORGEJO-UPGRADE.md](FORGEJO-UPGRADE.md)** — Forgejo major-version upgrades, group→team mapping explained

---

## Architecture

```
Browser → Traefik (:80/:443) → https://<domain>/        →  static landing page
                              → https://<domain>/cloud   →  Nextcloud  ─┐
                              → https://<domain>/git      →  Forgejo    ─┼─ login via Authelia (OIDC)
                              → https://<domain>/auth     →  Authelia portal + OIDC provider
              (:2222) ────────→ Forgejo git-over-SSH
```

Traefik is the only container with host ports. It discovers every other
container through the rootless Podman API socket and routes by `traefik.*`
labels. All services share one domain; there are no per-service subdomains.

---

## Prerequisites

Each target host needs:

- A `containers` system user with lingering enabled and a working rootless
  Podman setup — follow **[PODMAN-README.md](PODMAN-README.md)** once per host.
- A public DNS A record pointing your domain at the server's IP (required for
  Let's Encrypt to issue a certificate).
- Ports 80, 443, and 2222 reachable from the internet.

On your **local** machine you need `ansible` and `ansible-vault` installed.

---

## Deployment guide

Follow these steps in order for each new host. The running example host is
`myserver` with domain `example.com` — substitute your own.

### 1. Prepare the host

Complete the one-time rootless-Podman setup from
**[PODMAN-README.md](PODMAN-README.md)** on the target server. Confirm the
`containers` user exists and lingering is enabled before continuing.

### 2. Register the host in the inventory

Add the hostname to `ansible/inventory.yml`. The name must match the
`host_vars/<hostname>/` directory you create in the next step.

```yaml
all:
  hosts:
    spqr-project:
    myserver:          # ← add your host here
```

> If you skip this step, Ansible fails with *"Could not match supplied host
> pattern"* — the host directory alone is not enough; the host must be listed
> here too.

### 3. Create the host config and secrets

Each host gets a `host_vars/<hostname>/` **directory** with two files:
`vars.yml` (plain config) and `vault.yml` (encrypted secrets).

```sh
cd ansible
mkdir host_vars/myserver
cp host_vars/example-server.yml          host_vars/myserver/vars.yml
cp host_vars/spqr-project/vault.yml.example host_vars/myserver/vault.yml
$EDITOR host_vars/myserver/vars.yml
```

Fields in `vars.yml`:

| Field | What to put |
|---|---|
| `ansible_host` | Server IP or resolvable hostname |
| `ansible_user` | Your SSH login user |
| `ansible_ssh_private_key_file` | Path to your SSH key (e.g. `~/.ssh/id_ed25519`) |
| `domain` | Your public domain, e.g. `example.com`. All services share it. |

Now fill in the secrets. Every variable in `vault.yml` has an inline comment
explaining what it is and how to generate it — database passwords and admin
credentials are free choices (`openssl rand -hex 32` is a good default); the
Authelia/OIDC values need specific generators, covered in
[step 5](#5-generate-authelia--oidc-secrets).

```sh
$EDITOR host_vars/myserver/vault.yml      # fill in every value
ansible-vault encrypt host_vars/myserver/vault.yml
```

> **Per-host isolation.** Every secret lives in the host vault — instances never
> share database passwords, OIDC keys, or user lists. Only `acme_email` is
> global (next step).

### 4. Create the global vault

The global vault holds the single value shared by every host: the Let's Encrypt
registration email.

```sh
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml          # set acme_email
ansible-vault encrypt group_vars/all/vault.yml
```

> Both vaults are gitignored and must never be committed unencrypted. To avoid
> typing the vault password every run, save it once in `.vault_pass` (also
> gitignored) — `deploy.sh` picks it up automatically:
> ```sh
> echo "your-vault-password" > .vault_pass && chmod 600 .vault_pass
> ```

### 5. Generate Authelia / OIDC secrets

Authelia is on by default, so the host vault needs its secrets filled in before
the first run. (To skip SSO entirely, set `enable_authelia: false` in
`host_vars/myserver/vars.yml` and ignore this step.)

**Four independent random secrets** — `openssl rand -hex 32`, once each:

| Variable | Purpose |
|---|---|
| `vault_authelia_session_secret` | Signs the browser session cookie |
| `vault_authelia_storage_encryption_key` | Encrypts Authelia's SQLite DB (TOTP keys, remember-me tokens) |
| `vault_authelia_jwt_secret` | Signs password-reset tokens |
| `vault_authelia_oidc_hmac_secret` | Used in OIDC token derivation |

**OIDC issuer signing key** (`vault_authelia_oidc_jwks_key`) — RSA private key:

```bash
openssl genrsa 4096
```

Authelia uses it to sign the JWT tokens it issues to Nextcloud and Forgejo;
each app verifies the signature against the public key Authelia publishes at
`https://<domain>/auth/.well-known/jwks.json`. Paste the entire PEM (including
`BEGIN`/`END` lines) into the vault, indented two spaces under the `|`.
**Generate a fresh key per host — never share it across instances.**

**OIDC client secrets** — one matched (plaintext + hash) pair per app:

```bash
# Run once for Forgejo, once for Nextcloud:
podman run --rm docker.io/authelia/authelia:4.39 \
  authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 48
# -> "Random Password" = *_client_secret      (plaintext, used by the app)
# -> "Digest"          = *_client_secret_hash  (hash, stored by Authelia)
```

**At least one Authelia user** — see
[User management](#user-management-approval-workflow) for the `authelia_users`
format and how to generate `password_hash`.

### 6. Verify image versions

`group_vars/all/vars.yml` pins every image to a `major.minor` tag. Before
deploying, confirm the pins are still current — especially Forgejo, which has a
short support window (~3 months per non-LTS release):

- Forgejo releases: <https://forgejo.org/releases/>
- Nextcloud: <https://hub.docker.com/_/nextcloud>
- Traefik: <https://hub.docker.com/_/traefik>

### 7. Run the playbook

Use the wrapper from the repo root:

```sh
./deploy.sh                      # all hosts, full run
./deploy.sh --limit myserver     # one host
./deploy.sh --tags forgejo       # one role
```

`deploy.sh` auto-detects credentials and forwards any extra flags
(`--limit`, `--tags`, `--check`, …) to `ansible-playbook`:

- **Vault password** — uses `.vault_pass` if present, otherwise prompts.
- **Sudo password** — handled automatically if `vault_become_pass` is set and
  wired up; otherwise prompts. To stop being prompted:
  ```yaml
  # host_vars/<host>/vault.yml:
  vault_become_pass: "your_sudo_password"
  # group_vars/all/vars.yml:
  ansible_become_pass: "{{ vault_become_pass }}"
  ```

### 8. Verify the deployment

After the run completes:

```sh
curl -sS -o /dev/null -w "site:  %{http_code}\n" https://example.com/
curl -sS -o /dev/null -w "cloud: %{http_code}\n" https://example.com/cloud/
curl -sS -o /dev/null -w "git:   %{http_code}\n" https://example.com/git/
curl -sS -o /dev/null -w "auth:  %{http_code}\n" https://example.com/auth/
```

`200`/`302` means the service is up. If you get `502`, Traefik is still holding
a stale backend — see [RUNBOOK.md](RUNBOOK.md) for diagnostics. First-deploy
certificate issuance can take a minute; see
[Let's Encrypt certificates](#lets-encrypt-certificates) if it stalls.

---

## Services reference

What each role deploys. To run only some services on a host, edit
`ansible/site.yml`.

### `traefik`

The only container with host ports (80, 443, 2222). Discovers all other
containers via the rootless Podman API socket and routes by `traefik.*` labels.
Issues and renews TLS certificates via Let's Encrypt HTTP-01. Also TCP-forwards
Forgejo's git-over-SSH on port 2222.

### `static_site`

Nginx serving a read-only bind-mount from `roles/static_site/files/site/`.
Catch-all router (matches everything `/cloud` and `/git` don't claim). Replace
`index.html` with your landing page.

### `nextcloud`

Three containers: the Nextcloud app (Apache), MariaDB, and Valkey (a
Redis-compatible cache). Mounted at `/cloud` via Traefik's StripPrefix — see
[Nextcloud subpath install notes](#nextcloud-subpath-install-notes) for the
mechanics and what to check after upgrades.

### `forgejo`

Two containers: Forgejo app and its own MariaDB. Mounted at `/git` via
StripPrefix; Forgejo reconstructs `/git` URLs via `ROOT_URL`.

SSH git access is on port 2222. Add a `~/.ssh/config` entry on your local
machine so you can use short remotes without specifying the port each time:

```
Host example.com
    User git
    Port 2222
    IdentityFile ~/.ssh/id_ed25519   # the key registered in your Forgejo profile
```

With that in place:

```sh
git clone example.com:owner/repo.git
git remote add origin example.com:owner/repo.git
```

(Without the config block, clone explicitly:
`git clone ssh://git@example.com:2222/owner/repo.git`.)

### `forgejo_runner`

Forgejo Actions runner (`act_runner`) — same-host CI. Forgejo queues Actions
jobs but does not run them; this daemon registers with the instance and
executes each job as a sibling container via the rootless Podman socket. A
workflow's `runs-on: docker` matches the runner's `docker` label. Registration
is one-time (persisted in the `forgejo-runner-data` volume); a registration
token is generated automatically from Forgejo at deploy. Resource caps
(concurrency, per-job memory/CPU) are in `group_vars/all/vars.yml`
(`forgejo_runner_*`) and applied to each job container — kept conservative
because CI shares the host with every service. No web ingress (no Traefik
labels). Deploy with `--tags forgejo_runner`.

### `authelia`

Single sign-on identity provider (OIDC), on by default. Serves at `/auth`;
Nextcloud and Forgejo accept its tokens. Full detail in
[Authelia SSO](#authelia-sso-oidc-single-sign-on).

### `collabora` / `eurooffice`

Two document server roles exist, but **EuroOffice is the editor**: the
nextcloud role routes all Office formats to it (`defFormats`) and disables
the `richdocuments` (Collabora) connector app, which would otherwise
intercept double-clicks. Both servers run on the internal `edge` network
only. The collabora role can still be deployed (the container is simply
unused by Nextcloud) or dropped from `site.yml` to save RAM; to switch back,
re-enable `richdocuments` and remove the disable task from the nextcloud
role.

---

## Authelia SSO (OIDC single sign-on)

> **On by default** (`enable_authelia: true`). Authelia is the preferred login
> method for all regular users. The local admin accounts (set in the vault)
> bypass Authelia and are for initial setup or emergency access only.

Authelia provides a **single login shared across Nextcloud and Forgejo**: users
authenticate once at `https://<domain>/auth` and the OIDC token is accepted by
both apps. It also provides a reusable forward-auth middleware for protecting
any route that has no login of its own.

Deployment is covered in [step 5](#5-generate-authelia--oidc-secrets) of the
guide. This section covers running it: users, passwords, and account linking.

### The Authelia portal (`/auth`)

`https://<domain>/auth` is the user-facing portal. From here users can log in
(the SSO entry point), manage a TOTP second factor, and reset their password.
Password reset emails the reset token when SMTP is on; without SMTP, retrieve
the token manually — see [Without SMTP](#without-smtp).

### User management (approval workflow)

There is **no self-service registration**: a person can log in only if you have
added them to the `authelia_users` list in the **per-host** vault. Adding the
entry *is* the approval step. Each instance has its own users.

```yaml
# host_vars/<host>/vault.yml (encrypted):
authelia_users:
  - username: "alice"
    displayname: "Alice Rossi"
    email: "alice@polimi.it"
    password_hash: "$argon2id$v=19$..."
    groups: [users]            # see "Groups and roles" below
```

`password_hash` is required and is the source of truth — a user with no hash
makes Authelia refuse to start (the role asserts this). Generate it with:

```bash
podman run --rm docker.io/authelia/authelia:4.39 \
  authelia crypto hash generate argon2 --password 'TheirPassword'
```

Re-run the playbook after any change. To revoke access, set `disabled: true` or
remove the entry.

### Groups and roles

The `groups` list on each user is sent to Forgejo and Nextcloud as an OIDC
`groups` claim, and the apps turn it into permissions:

| Authelia group | Effect | Where it's configured |
| --- | --- | --- |
| `admins` | Grants the **Forgejo admin** role on next OIDC login | `forgejo_oidc_admin_group` in `group_vars/all/vars.yml` |
| *any group* | Synced into Nextcloud as a like-named group (quotas, group folders, share policies) | `nextcloud_oidc_group_provisioning` in `group_vars/all/vars.yml` |

Notes:

- **Group names are free-form.** Add your own (e.g. `developers`, `staff`) to a
  user's `groups` list and reference them in Forgejo team maps or Nextcloud
  group settings. A user with no groups defaults to `users`.
- **Nextcloud admin is intentionally NOT group-driven.** Admin rights come from
  the built-in local `admin` account (set in the vault), not from any Authelia
  group — keeping a break-glass admin that works even if SSO is down.
- **To change which group grants Forgejo admin**, edit `forgejo_oidc_admin_group`
  and re-run the Forgejo role (`./deploy.sh --limit <host> --tags forgejo`). The
  role re-applies the mapping to the existing OIDC source; you don't need to
  recreate it.
- Changes take effect on the user's **next login** (the role is read from the
  token at login time), not retroactively for an active session.

#### Forgejo group → org/team mapping

For finer access control you can map Authelia groups to Forgejo org teams.
Set `forgejo_oidc_group_team_map` in `group_vars/all/vars.yml` (or override it
per host in `host_vars/<host>/vars.yml`):

```yaml
forgejo_oidc_group_team_map:
  polimi:
    polimi: [Members]
  developers:
    polimi: [Developers]
```

With this example a user whose Authelia groups include `polimi` is added to the
`Members` team of the `polimi` org; a user with `developers` is added to the
`Developers` team. A user with both groups is added to both teams.

**Removal on leave is on by default** (`forgejo_oidc_group_team_map_removal:
true`): if the group is removed from the user's vault entry and the playbook is
re-run, the user is dropped from the corresponding team on their next login.

**Orgs and teams must be created in the Forgejo UI first.** The deploy only
manages membership — it does not create orgs or teams. Go to
`https://<domain>/git/org/create` to create an org, then add teams from its
Settings page before adding the mapping here.

#### Adding a user without running the playbook

To grant access immediately, edit the live file on the server. The file backend
runs with `watch: true`, so Authelia hot-reloads on change — no restart needed.

1. Generate the hash (command above).
2. Edit the file **as the `containers` user** so ownership is preserved:
   ```bash
   sudo -u containers nano /etc/authelia/users_database.yml
   ```
   > **Critical:** do NOT edit with plain `sudo nano`. That saves the file owned
   > by `root`; Authelia (running as `containers`) can then no longer read it —
   > the reload fails with `permission denied` and Authelia keeps the *old* data
   > in memory (e.g. a stale email, so reset mail keeps going to the old
   > address). If you already did this, fix ownership:
   > ```bash
   > sudo chown containers:containers /etc/authelia/users_database.yml
   > sudo chmod 600 /etc/authelia/users_database.yml
   > ```
   Add the entry under `users:` (note: the key here is `password`, **not**
   `password_hash`):
   ```yaml
     newuser:
       displayname: "New User"
       password: "$argon2id$v=19$..."
       email: "newuser@example.com"
       groups:
         - users
   ```
3. Save, then **confirm the reload was clean** — a YAML error or permission
   problem makes Authelia silently keep the old data:
   ```bash
   sudo journalctl _SYSTEMD_USER_UNIT=container-authelia.service -n 10
   ```
   Look for a successful reload and no `Error occurred during reload`. If the
   change still isn't applied, restart Authelia **and Traefik** (Authelia alone
   gets a new IP, leaving Traefik on a 502 until it re-discovers):
   ```bash
   scont systemctl --user restart container-authelia.service
   scont systemctl --user restart container-traefik.service
   ```

> **Make it permanent:** the next playbook run overwrites this file from the
> vault. Add the same user to `host_vars/<host>/vault.yml` (`ansible-vault
> edit`) using `password_hash` instead of `password`. (`scont` is the server
> helper alias documented in [RUNBOOK.md](RUNBOOK.md).)

### Changing a password — and why the vault is the source of truth

The `password_hash` in the vault is the **authoritative** copy. The playbook
re-renders `users_database.yml` from `authelia_users` on every run, so:

> **Anything that changes a password only inside the container is temporary.**
> The next playbook run reverts it to the vault's hash, locking the user out
> with their old password.

A password change is not complete until the new hash is in the vault.

**A. Admin changes it (works without SMTP):**

1. Generate a new hash (the `argon2` command above).
2. `ansible-vault edit host_vars/<host>/vault.yml` → replace that user's
   `password_hash`.
3. Re-run the playbook. Vault and container now agree.

**B. User self-resets via the portal (requires SMTP):**

The portal's *Forgot password?* link rewrites `users_database.yml` **inside the
container only**. To make it survive the next deploy, harvest the new hash:

1. Read the hash Authelia wrote (the file is bind-mounted on the host):
   ```bash
   sudo grep -A5 'USERNAME' /etc/authelia/users_database.yml
   ```
2. Copy that user's `password` field into `password_hash` in
   `host_vars/<host>/vault.yml` (`ansible-vault edit`).
3. Re-run the playbook.

> **During a testing phase, prefer method B.** Don't ask users to send you a
> password or a hash — they have no easy way to generate an argon2 hash, and you
> don't want plaintext passwords in your inbox. Let each user self-reset (they
> pick a password you never see), then harvest the hash into the vault before
> the next deploy. The hash is safe to store; the plaintext stays with the user.

> **Future upgrade path:** the file backend scales fine to a few dozen users.
> When self-service password management becomes a real need, switch Authelia's
> `authentication_backend` from `file` to **LDAP** (e.g. lldap/OpenLDAP): users
> then own their passwords in the directory, the vault no longer holds hashes,
> and the revert problem disappears — without touching Nextcloud or Forgejo.

### Linking existing accounts

If a user already has a local Nextcloud/Forgejo account, OIDC login maps onto it
rather than creating a duplicate, **provided the email/username match** the
`authelia_users` entry:

- **Forgejo** prompts for the existing password once on first OIDC login to link
  the accounts (afterwards visible under Settings → Security).
- **Nextcloud** keys on the `preferred_username` claim, so the same username
  lands in the same account. Confirm with `occ user:list` (no duplicate).

### Implementation notes (same-host OIDC quirks)

Because Authelia, Nextcloud and Forgejo run on one host behind one domain, the
roles handle three non-obvious issues automatically:

- **`/etc/hosts` hairpin.** Podman copies the host's `/etc/hosts`, mapping the
  FQDN to `127.0.1.1`. Server-side OIDC calls would dial loopback and fail, so
  the Forgejo/Nextcloud containers get an `etc_hosts` override mapping the
  domain to the real host IP.
- **Nextcloud SSRF block.** Nextcloud's HTTP client refuses same-host addresses
  by default (`LocalServerException`). The role sets
  `allow_local_remote_servers=true` when Authelia is enabled.
- **Traefik backend refresh.** Authelia gets a fresh IP on each deploy, so the
  role restarts Traefik right after (re)creating it. Manually restarting any app
  container likewise needs a Traefik restart after. The same applies to overnight
  `podman-auto-update` runs — handled automatically by the drop-in described
  under [Automatic image updates](#automatic-image-updates).

### Forward-auth for bare routes

Any route with no login of its own can be protected by attaching the
`authelia@docker` middleware on that container's Traefik labels:

```yaml
traefik.http.routers.<name>.middlewares: "authelia@docker"
```

Unauthenticated requests are redirected to the Authelia portal first.

### Caveats

- **Schema version.** The config targets Authelia **4.39**. If you pin a
  different tag, the usual breaking points are `server.address` path syntax, the
  `jwks` structure under `identity_providers.oidc`, and the notifier address
  scheme. Check `podman logs authelia` after a bump.
- **Subpath issuer.** Because Authelia is under `/auth`, the issuer is
  `https://<domain>/auth` and discovery is at
  `https://<domain>/auth/.well-known/openid-configuration`. Issuer-mismatch
  errors usually trace to this prefix.
- **Forgejo auth-source idempotency.** The role adds the `authelia` OIDC source
  only if absent. If you change the client secret later, remove and re-add:
  `forgejo admin auth delete-oauth --id <id>`, then re-run the playbook.
- **Nextcloud groups.** When `nextcloud_oidc_group_provisioning` is true (the
  default), `user_oidc` syncs the Authelia `groups` claim into Nextcloud groups
  on each login — see [Groups and roles](#groups-and-roles). Provisioned groups
  appear with hashed internal IDs in `occ group:list` but show their real names
  in the UI. This does **not** grant Nextcloud admin: admin stays with the local
  `admin` account on purpose. Set `nextcloud_oidc_group_provisioning: false` to
  manage Nextcloud group membership manually instead.

---

## SMTP relay (optional)

SMTP enables password-reset emails from Authelia (and mailer support in
Nextcloud and Forgejo). It is **off by default** and configured per host. To
enable it, add to `host_vars/<host>/vars.yml`:

```yaml
enable_smtp: true
smtp_host: "smtp-relay.brevo.com"   # your relay — see below
smtp_port: 587
smtp_security: "starttls"           # starttls (587) | tls (465) | none (25)
smtp_from: "noreply@yourdomain.com" # must be on an authenticated domain
```

and the credentials to `host_vars/<host>/vault.yml`:

```yaml
vault_smtp_user:     "your-relay-login"
vault_smtp_password: "your-relay-password-or-api-key"
```

### Choosing a relay — Brevo (recommended, free)

Direct SMTP from the server IP is rejected by most providers; a free relay is
the practical solution. **[Brevo](https://www.brevo.com)** offers 300 emails/day
permanently on the free tier with full SMTP relay support — plenty for
password-reset and notification mail on a small team server.

**Important:** since February 2024 all major providers require **SPF, DKIM and
DMARC** on the sender domain, or mail is silently dropped. So:

- You cannot send from `noreply@<your-polimi-subdomain>` unless Polimi IT adds
  the DNS records (unlikely).
- **Use a domain you control** for `smtp_from` and add Brevo's DNS records in
  your registrar's panel — minutes, no IT department.

**Setup steps:**

1. Create a free account at [brevo.com](https://www.brevo.com).
2. Settings → Senders & IP → Domains → **Add a domain** (one you control).
3. Add the three DNS records Brevo shows (SPF, DKIM, DMARC) in your registrar.
   - **SPF:** merge with any existing SPF record — never two SPF TXT records on
     one name, e.g. `v=spf1 include:_spf.aruba.it include:spf.brevo.com ~all`.
   - **DMARC:** if one exists, merge into a single record.
4. Click **Verify** in Brevo (15–30 min typical, up to 48h).
5. Settings → SMTP & API → SMTP → **Generate a new SMTP key** (shown once).
6. Security → Authorized IPs → add the server's public IP
   (`curl -sS https://api.ipify.org`), then enable IP blocking.
7. Fill in `vars.yml` + vault as above.

**Test before redeploying:**

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

### Without SMTP

Authelia writes password-reset tokens to `/config/notification.txt` inside its
container. Retrieve the link and forward it to the user manually:

```bash
sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
  podman exec authelia cat /config/notification.txt
```

---

## Day-2 operations

For logs, diagnostics, and common failure fixes, see
**[RUNBOOK.md](RUNBOOK.md)**. The lifecycle topics below live here.

### Let's Encrypt certificates

Traefik requests certificates from **Let's Encrypt production** on first deploy.
They are stored in `/etc/traefik/letsencrypt/acme.json` (bind-mounted into the
container) and renewed automatically.

To test the stack without hitting rate limits, add the staging CA flag to the
`Run traefik` task in `roles/traefik/tasks/main.yml`:

```yaml
- "--certificatesresolvers.letsencrypt.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory"
```

Staging issues untrusted certs but has no rate limits. For production, remove
that line, re-run the traefik role, and delete `acme.json` to force a fresh
cert:

```sh
# On the server, as the containers user:
rm /etc/traefik/letsencrypt/acme.json
systemctl --user restart container-traefik.service
```

### Automatic image updates

The traefik role enables `podman-auto-update.timer`, which checks daily for new
patch releases under the same `major.minor` tag and restarts affected
containers. To bump a major or minor version, change the tag in
`group_vars/all/vars.yml` and re-run the relevant role.

An auto-update **recreates** each updated container, which comes up with a new
IP on the `edge` network. Traefik would keep routing to the old IP and return
`502` until re-discovering it, so the role installs a systemd drop-in
(`podman-auto-update.service.d/restart-traefik.conf`) whose `ExecStartPost`
restarts Traefik after every auto-update run. Without this, an overnight
auto-update could leave an app 502ing until the next manual Traefik restart.

### Nextcloud major version upgrades

Nextcloud refuses to skip a major version. Upgrade one major at a time: update
the tag, run the playbook, wait for the upgrade to finish, then repeat.

---

## Nextcloud subpath install notes

Nextcloud does not officially support running under a subpath (`/cloud` instead
of the domain root). It works in practice but needs several hacks, all baked
into the role — documented here so you know what to touch if a Nextcloud upgrade
breaks something.

### 1. Traefik StripPrefix + OVERWRITE* env vars (the core trick)

Traefik routes `https://<domain>/cloud/…` to Nextcloud but **strips `/cloud`**
before forwarding, so Nextcloud receives requests at `/`. Nextcloud rebuilds its
URLs via three env vars:

| Env var | Value | Purpose |
|---|---|---|
| `OVERWRITEWEBROOT` | `/cloud` | Prepends `/cloud` to every internal URL |
| `OVERWRITEHOST` | `<domain>` | Overrides the `Host` Nextcloud sees behind the proxy |
| `OVERWRITEPROTOCOL` | `https` | Forces HTTPS in generated URLs |

Without `OVERWRITEWEBROOT`, links would point at the domain root and break.

### 2. CLI URL (overwrite.cli.url)

Set to `https://<domain>/cloud/` via `occ config:system:set`, used by background
jobs and CLI commands that build absolute URLs outside an HTTP request.

> **Known cosmetic issue:** the container can't reach its own public URL
> (hairpin NAT), so some admin self-tests show "could not check". The features
> work; only the internal reachability test is affected.

### 3. Federation discovery routes at the domain root

`/ocm-provider` and `/ocs-provider` must be served at the **domain root**, not
under `/cloud`, for federation. Each gets its own Traefik router with no
StripPrefix. Combining them with an `||` rule makes Traefik v3 silently reject
the whole container's labels, so they are intentionally two routers.

### 4. notify_push (Client Push) path

The push daemon runs in the Nextcloud container on port 7867, published at
`https://<domain>/cloud/push` (stripped to `/`). With two services on one
container (port 80 and 7867), Traefik v3 requires explicit
`traefik.http.routers.*.service` labels on all routers, or it drops them all.

### What to check after a Nextcloud major upgrade

1. `OVERWRITEWEBROOT` still respected (UI links include `/cloud`).
2. `/ocm-provider` and `/ocs-provider` still resolve at the domain root.
3. `/cloud/push` returns 200 (`curl -I https://<domain>/cloud/push`).
4. If the admin panel shows new warnings:
   ```sh
   podman exec --user www-data nextcloud php /var/www/html/occ maintenance:repair --include-expensive
   ```

---

## Repository structure

```
deploy.sh                  # Wrapper around ansible-playbook (auto-detects creds)
ansible/
  ansible.cfg              # Ansible config (sets inventory = inventory.yml)
  inventory.yml            # Host list — every host must be listed here
  site.yml                 # Master playbook (runs all roles in order)
  group_vars/all/
    vars.yml               # Image tags + shared non-secret config
    vault.yml.example      # Global vault template (only acme_email)
    vault.yml              # ENCRYPTED global secret — never commit unencrypted
  host_vars/
    example-server.yml     # Template for a host's vars.yml
    <hostname>/            # One directory per host:
      vars.yml             #   plain per-host config (IP, domain, SSH key)
      vault.yml.example    #   per-host secret template (fully commented)
      vault.yml            #   ENCRYPTED per-host secrets — never commit
  roles/
    traefik/tasks/main.yml            # Reverse proxy + TLS
    static_site/...                   # Landing page (nginx)
    nextcloud/tasks/main.yml          # Nextcloud + MariaDB + Valkey
    forgejo/tasks/main.yml            # Forgejo + MariaDB
    collabora/tasks/main.yml          # Collabora document server (fallback)
    eurooffice/tasks/main.yml         # EuroOffice document server (primary)
    authelia/tasks/main.yml           # SSO/OIDC provider (on by default)
README.md                  # This file
RUNBOOK.md                 # Operational runbook: logs, diagnostics, common fixes
PODMAN-README.md           # One-time host setup (rootless Podman + containers user)
```

# Experimental: Email (SMTP) + Single Sign-On (Authelia)

> **Status: experimental, untested scaffolding.** This branch
> (`claude/experimental-authelia-smtp`) adds outbound email and an Authelia
> identity provider on top of the stable stack. Everything is **off by default**
> and gated behind two flags, so running the playbook on this branch with the
> defaults behaves exactly like `stable`. Turn the features on only after you
> have filled in the secrets below, and expect to validate/iterate on the
> server — the Authelia schema in particular moves between releases.
>
> The hardened, known-good baseline lives on the **`stable`** branch.

---

## What this adds

| Feature | Flag | What it powers |
|---|---|---|
| SMTP relay | `enable_smtp` | Password-reset & notification emails for Nextcloud, Forgejo, and Authelia |
| Authelia | `enable_authelia` | A single login (OIDC) shared by Nextcloud and Forgejo, served at `https://<domain>/auth`, plus a reusable forward-auth middleware for protecting bare routes |

Both flags live in `ansible/group_vars/all/vars.yml` and default to `false`.

---

## Part 1 — SMTP (do this first; Authelia reuses it)

You do **not** run a mail server. You relay through an existing one — ideally
the university's SMTP server (ask DEIB/Polimi IT for the host; it is often
`smtp.polimi.it` or similar, on port 587 STARTTLS).

### 1.1 Set the relay in `vars.yml`

```yaml
enable_smtp: true
smtp_host: "smtp.polimi.it"     # <-- the real host once you know it
smtp_port: 587
smtp_security: "starttls"       # starttls (587) | tls (465) | none (25)
smtp_from: "noreply@spqr-project.deib.polimi.it"
```

### 1.2 Set credentials in the vault

```yaml
# host_vars/<host>/vault.yml  (encrypted, per instance)
vault_smtp_user:     "your-smtp-login"     # leave "" if the relay allows
vault_smtp_password: "your-smtp-password"  # unauthenticated on-campus sending
```

Many university relays accept unauthenticated mail from on-campus IPs — if so,
leave both blank and `mail_smtpauth` is set to `0` automatically.

### 1.3 Apply and test

```bash
./deploy.sh                    # or ansible-playbook as usual
```

- **Nextcloud:** Admin → Basic settings → *Send email* test button.
- **Forgejo:** the mailer is configured via env; trigger a password reset to test.

---

## Part 2 — Authelia (OIDC single sign-on)

Authelia runs as one container on the `edge` network, served under `/auth` on
the main domain (no subdomain needed). It acts as an **OpenID Connect
provider**: Nextcloud and Forgejo delegate login to it. Users sign in once
against Authelia and then click "Log in with Authelia" in each app.

### 2.1 Generate the secrets

All of these go into the per-host encrypted vault
(`host_vars/<host>/vault.yml`). The example file
`host_vars/spqr-project/vault.yml.example` lists every key with its
generator command. Summary:

```bash
# Four random secrets (session, storage encryption, reset-JWT, OIDC HMAC):
openssl rand -hex 32      # run four times, one per secret

# OIDC issuer signing key (RSA private key, PEM):
openssl genrsa 4096       # paste the whole PEM into vault_authelia_oidc_jwks_key

# Admin password hash (argon2):
podman run --rm docker.io/authelia/authelia:4.39 \
  authelia crypto hash generate argon2 --password 'YourAdminPassword'

# One OIDC client-secret PAIR per app (plaintext + pbkdf2 hash):
podman run --rm docker.io/authelia/authelia:4.39 \
  authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 48
#   -> "Random Password" is the PLAINTEXT (goes to the app's vault var)
#   -> "Digest"          is the HASH      (goes to the *_hash vault var)
```

Fill in, for each of Forgejo and Nextcloud:
`vault_oidc_<app>_client_secret` (plaintext) **and**
`vault_oidc_<app>_client_secret_hash` (the digest). They must be a matched pair
from the same command run.

### 2.2 Enable and deploy

```yaml
# vars.yml
enable_authelia: true
```

```bash
./deploy.sh
```

This will:
- deploy the Authelia container and route `https://<domain>/auth`
- auto-add an `authelia` OIDC login source to Forgejo
- install `user_oidc` in Nextcloud and register the `authelia` provider

The OIDC redirect URIs are already pre-registered in Authelia's config:

| App | Redirect URI |
|---|---|
| Forgejo | `https://<domain>/git/user/oauth2/authelia/callback` |
| Nextcloud | `https://<domain>/cloud/apps/user_oidc/code` |

### 2.3 Log in

1. Go to `https://<domain>/auth` — you should get the Authelia portal.
2. Log in with the admin user from your `users_database.yml` (see below).
3. In Forgejo's login page, click **Sign in with authelia**.
4. In Nextcloud's login page, click **Log in with Authelia**.

---

## Managing users — the approval workflow

There is **no self-service signup**: a person can log into anything only if you
have added them to Authelia. Adding them *is* the approval. Users are driven by
the `authelia_users` list in your **per-host** encrypted vault
(`host_vars/<host>/vault.yml`) — each instance carries its own user list, so
spqr-project and quouskwe-project never share logins. Onboarding is a data edit,
not a template edit.

**To approve / add a user:**

1. Generate their password hash:
   ```bash
   podman run --rm docker.io/authelia/authelia:4.39 \
     authelia crypto hash generate argon2 --password 'TheirPassword'
   ```
2. Add an entry to `authelia_users` in the vault:
   ```yaml
   authelia_users:
     - username: "admin"
       displayname: "Administrator"
       email: "you@example.com"
       password_hash: "$argon2id$v=19$..."
       groups: [admins]
     - username: "alice"            # <-- new, approved user
       displayname: "Alice Rossi"
       email: "alice@polimi.it"
       password_hash: "$argon2id$v=19$..."
       groups: [users]
   ```
3. Re-run the playbook. (`groups` defaults to `[users]`; `displayname` defaults
   to the username.)

**To revoke a user:** set `disabled: true` on their entry (keeps the record) or
delete it entirely, then re-run.

### Changing a password — and why the vault is the source of truth

The `password_hash` in the vault is the **authoritative** copy. The playbook
renders `users_database.yml` from `authelia_users` on every run and overwrites
the file inside the container. This has one important consequence:

> **Anything that changes a password *only* inside the container is temporary.**
> The next `ansible-playbook` run re-renders `users_database.yml` from the vault
> and reverts to the hash stored there — the user is then locked out with their
> old password.

So a password change is **not** complete until the new hash is back in the vault.
There are two ways a password gets changed:

**A. Admin changes it (recommended, works without SMTP).**

1. Generate a new hash:
   ```bash
   podman run --rm docker.io/authelia/authelia:4.39 \
     authelia crypto hash generate argon2 --password 'TheNewPassword'
   ```
2. Replace that user's `password_hash` in `host_vars/<host>/vault.yml`:
   ```bash
   ansible-vault edit host_vars/spqr-project/vault.yml
   ```
3. Re-run the playbook. Done — vault and container now agree.

**B. User self-resets via the portal (requires SMTP configured).**

If `enable_smtp` is on, the portal's *Forgot password?* link emails a reset
token; completing it rewrites `users_database.yml` **inside the container only**.
That works immediately, but to make it survive the next deploy you must pull the
new hash back into the vault:

1. Read the hash Authelia just wrote:
   ```bash
   sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
     podman exec authelia cat /config/users_database.yml
   ```
2. Copy that user's new `password` hash into `password_hash` in
   `host_vars/<host>/vault.yml` (`ansible-vault edit`).
3. Re-run the playbook so the two stay in sync.

   Until you do step 2–3, treat the reset as provisional: a redeploy will undo
   it. (Without SMTP there is no self-service reset at all — use method A.)

This file-backend friction is the cost of keeping users in Ansible. It scales
fine to a few dozen users. When self-service password management becomes a real
need, switch Authelia's `authentication_backend` from `file` to **LDAP** (e.g.
lldap/OpenLDAP): users then own their passwords in the directory, the vault no
longer holds hashes, and the whole revert problem disappears — without touching
anything in Nextcloud or Forgejo. That is the natural future upgrade path.

---

## Protecting a bare route with forward-auth

Nextcloud and Forgejo use OIDC (above) because they have their own login pages.
For something with **no** login of its own (a future internal dashboard, a
metrics endpoint, the Collabora admin panel, …) attach the `authelia@docker`
forward-auth middleware on that container's router labels:

```yaml
traefik.http.routers.<name>.middlewares: "authelia@docker"
```

Requests are then bounced through the Authelia portal first; only logged-in
users reach the service.

---

## Caveats / things to verify on the server

- **Untested.** The Authelia config targets schema **4.39**; if you pin a
  different tag, reconcile the config. The usual breaking points between versions
  are the `server.address` path syntax, the `jwks` key structure under
  `identity_providers.oidc`, and the `notifier` address scheme (e.g.
  `submission://` vs `smtp+starttls://`). The JWT reset-password secret is
  intentionally absent from `configuration.yml` — it is injected via the
  `AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET` env var, which
  Authelia maps to the equivalent config key automatically. Check container logs
  after first boot:
  ```bash
  sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
    podman logs authelia
  ```
- **Subpath OIDC issuer.** Because Authelia is under `/auth`, the issuer is
  `https://<domain>/auth` and discovery is at
  `https://<domain>/auth/.well-known/openid-configuration`. If an app complains
  about issuer mismatch, that prefix is the first thing to check.
- **Bind-mount permissions.** Authelia writes `db.sqlite3` and (without SMTP)
  `notification.txt` into `/etc/authelia`. If it logs permission errors under
  rootless Podman, adjust ownership of `/etc/authelia` or set `PUID`/`PGID` on
  the container to match.
- **Forgejo auth source idempotency.** The role adds the `authelia` source only
  if `forgejo admin auth list` doesn't already show it. If you change the client
  secret later, remove and re-add the source (`forgejo admin auth list` →
  `update-oauth`).
- **Nextcloud groups.** `user_oidc` maps `preferred_username`/`email`/`name`.
  Group sync from Authelia is not wired; add it if you need group-based shares.

---

## Rolling back

Everything here is gated, so the simplest rollback is to set both flags back to
`false` and re-run. To drop the experiment entirely, deploy from the **`stable`**
branch instead of this one. Authelia leaves a `container-authelia.service` unit
and `/etc/authelia` behind — stop/disable the unit and remove the directory if
you want it fully gone.

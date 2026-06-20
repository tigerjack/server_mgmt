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
# group_vars/all/vault.yml  (encrypted)
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

All of these go into the encrypted vault (`group_vars/all/vault.yml`). The
example file `group_vars/all/vault.yml.example` lists every key with its
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

## Managing Authelia users

Users live in a flat file, templated from
`ansible/roles/authelia/templates/users_database.yml.j2`. The bootstrap admin
comes from the vault (`vault_authelia_admin_*`). To add more users, generate a
hash and extend the template:

```bash
podman run --rm docker.io/authelia/authelia:4.39 \
  authelia crypto hash generate argon2 --password 'TheirPassword'
```

```yaml
# users_database.yml.j2
  alice:
    disabled: false
    displayname: "Alice"
    password: "$argon2id$v=19$..."   # the generated hash
    email: "alice@example.com"
    groups: [users]
```

Re-run the playbook to push the change. (When you outgrow a flat file, Authelia
can switch its `authentication_backend` to LDAP without changing anything in the
apps — that is the natural future upgrade path.)

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
  different tag, reconcile the config (`server.address` path syntax, the
  `identity_validation`/`jwks` sections, and `notifier` address scheme are the
  usual breaking points). Check `scont podman logs authelia` after first boot.
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

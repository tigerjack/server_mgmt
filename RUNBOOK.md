# Runbook — diagnostics and common operations

Quick reference for inspecting running services and resolving common problems.
All commands assume you are SSH'd into the server as your personal user
(`sperriello` or similar). The rootless containers run under the `containers`
system user. The `scont` alias is defined on the server and expands to:

```bash
alias scont='sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers)'
```

Prepend every `podman` or `systemctl --user` command with it:

```bash
scont podman logs --tail 50 authelia
scont systemctl --user status container-authelia.service
```

---

## Quick health check

Is everything up and serving? Three independent checks:

```bash
# 1. All containers running (look for "Up" and a sane uptime, no restart loop)
scont podman ps

# 2. Each app answers over HTTPS through Traefik (200/302/30x = alive)
curl -sS -o /dev/null -w "auth:  %{http_code}\n" https://spqr-project.deib.polimi.it/auth/
curl -sS -o /dev/null -w "cloud: %{http_code}\n" https://spqr-project.deib.polimi.it/cloud/
curl -sS -o /dev/null -w "git:   %{http_code}\n" https://spqr-project.deib.polimi.it/git/

# 3. systemd considers each unit active (prints last log lines inline too)
scont systemctl --user status container-authelia.service container-nextcloud.service \
  container-forgejo.service container-traefik.service
```

A `502 Bad Gateway` from curl usually means Traefik is holding a stale container
IP — restart Traefik (see Traefik section). Empty `podman ps` output for a
container that should be running means it crashed on start; check its journal.

---

## Inspecting logs

Because containers are managed with `generate_systemd: new: true`, each restart
runs `podman run --rm` and creates a fresh container — `podman logs` only shows
output since the last restart and is empty if the container just started. Use
**journald** to see logs across restarts.

These are **rootless user services**. Read their logs from the system journal
filtering on the *user-unit* field (your login user must be in the `adm` or
`systemd-journal` group — `sperriello` is):

```bash
# Last 50 lines (survives container restarts)
sudo journalctl _SYSTEMD_USER_UNIT=container-authelia.service -n 50
sudo journalctl _SYSTEMD_USER_UNIT=container-nextcloud.service -n 50
sudo journalctl _SYSTEMD_USER_UNIT=container-forgejo.service -n 50
sudo journalctl _SYSTEMD_USER_UNIT=container-traefik.service -n 50

# Live feed (Ctrl-C to stop)
sudo journalctl _SYSTEMD_USER_UNIT=container-authelia.service -f
```

> **Why this field and not `-u`?** The `-u` flag matches *system* units
> (`_SYSTEMD_UNIT`). These are *user* units, stored under `_SYSTEMD_USER_UNIT`,
> so `sudo journalctl -u container-authelia.service` returns "No entries".
> `scont journalctl --user` also fails here: the `containers` user isn't in the
> `systemd-journal` group, so it can't read the journal ("insufficient
> permissions"). Querying the system journal with `sudo` + the user-unit field
> is the reliable path.

`podman logs` still works for the current run if you need to check something
immediately after a start:

```bash
scont podman logs --tail 50 authelia
```

---

## Authelia — user can't log in or reset password

**1. Check the logs while the user tries again:**

```bash
sudo journalctl _SYSTEMD_USER_UNIT=container-authelia.service -f
```

Common error patterns and what they mean:

| Log message | Cause |
|---|---|
| `user not found` | Username not in `users_database.yml` — check spelling, or the entry was never added |
| `authentication failed` | Wrong password. If the user just reset it via the portal, check whether the vault was re-synced (see below) |
| `error reading the authentication database` | `users_database.yml` is malformed — missing field, bad YAML indentation, or a non-argon2 hash |
| `failed to send an email` / `notifier: smtp: ... lookup smtp-relay.brevo.com: i/o timeout` | Authelia can't reach/resolve the SMTP relay — password reset emails won't send. See "SMTP relay unreachable" below |
| `token_endpoint_auth_method ... does not allow this method` (client `forgejo`) | Forgejo OIDC auth-method mismatch — the Authelia `forgejo` client must use `client_secret_basic` (fixed in `configuration.yml.j2`; redeploy the authelia role) |
| `302` to `/auth` repeatedly | Session cookie issue — user should clear cookies and retry |

**Benign log noise (safe to ignore — logged at `error` level but harmless):**

| Log message | Why it's harmless |
|---|---|
| `Request timeout occurred ... read tcp ...->...: i/o timeout` `method=GET path=/ status_code=408` | The `remote_ip` is Traefik, not a user. Traefik keeps idle keep-alive connections to the backend; when one sits idle past Authelia's read timeout it's closed with a 408. Normal keep-alive reaping — no real request is dropped. |
| `Error occurred during reload ... open /config/users_database.yml: permission denied` (service=watcher) | The user file was edited with plain `sudo` and is now owned by `root`; Authelia (running as `containers`) can't read it, so the reload fails and it keeps the **old** data in memory (stale email/password). Fix ownership — see "Editing the user file" below |
| `token ... already revoked` / `the token has been revoked` during `/api/reset-password` | A reset link was opened more than once (double-click, browser prefetch, page refresh). The first use consumed the token and the reset succeeded; the second hit is correctly rejected. |

**2. Confirm the user exists in the live file:**

Authelia's user database is at `/etc/authelia/users_database.yml` on the server.

```bash
sudo grep -A5 'USERNAME' /etc/authelia/users_database.yml
```

If the entry is missing or wrong (e.g. a typo'd email — reset mail goes to the
address recorded here, *not* what the user types), edit it directly. **Edit as
the `containers` user** so the file stays readable by Authelia:

```bash
sudo -u containers nano /etc/authelia/users_database.yml
```

> **Never edit it with plain `sudo nano`.** That rewrites the file owned by
> `root`; Authelia runs as `containers` and can no longer read it, so the
> `watch: true` reload fails with `permission denied` and the **old** data stays
> in memory (the classic "fixed the email but reset mail still goes to the old
> address"). If you already did it, restore ownership:
> ```bash
> sudo chown containers:containers /etc/authelia/users_database.yml
> sudo chmod 600 /etc/authelia/users_database.yml
> sudo -u containers touch /etc/authelia/users_database.yml   # trigger a reload
> ```

See README § "Adding a user without running the playbook" for the exact format.
The file backend runs with `watch: true`, so Authelia hot-reloads on save.

> **After editing, confirm the reload actually happened.** A malformed YAML save
> *or a permission-denied* is rejected and Authelia keeps the *old* data in
> memory — exactly how a fixed email keeps sending to the old one. Check the log:
> ```bash
> sudo journalctl _SYSTEMD_USER_UNIT=container-authelia.service -n 10
> ```
> Look for a clean reload and no `Error occurred during reload`. If the change
> still isn't applied, restart Authelia **and Traefik** (Authelia alone gets a
> new IP → Traefik 502 until it re-discovers):
> ```bash
> scont systemctl --user restart container-authelia.service
> scont systemctl --user restart container-traefik.service
> ```

**3. Reset the password for them (no SMTP needed):**

Generate a new hash and paste it into the live file:

```bash
# On server or local machine:
scont podman run --rm docker.io/authelia/authelia:4.39 \
  authelia crypto hash generate argon2 --password 'TempPassword123'

# Edit as the containers user (see ownership warning above):
sudo -u containers nano /etc/authelia/users_database.yml   # replace the password: field
```

Authelia hot-reloads on save (`watch: true`). Tell the user their temporary
password and ask them to reset it via the portal immediately.

> **Remember to update the vault** before the next playbook run, or the change
> will be reverted (`ansible-vault edit host_vars/<host>/vault.yml`).

**4. Password reset via portal isn't sending email:**

```bash
sudo journalctl _SYSTEMD_USER_UNIT=container-authelia.service -n 30
```

If SMTP is working but the user doesn't receive the mail:

```bash
# Check if Authelia fell back to the file notifier (means SMTP failed silently):
sudo ls -la /etc/authelia/notification.txt
sudo cat /etc/authelia/notification.txt   # contains the reset URL
```

Send that URL to the user out of band.

**Mail is sent but to the wrong address.** Authelia mails the address recorded
in `users_database.yml`, not what the user types. Check the **Brevo dashboard →
Transactional → Email → Logs**: it shows the exact recipient and the delivery
status (Delivered / Bounced / Blocked) for every message. If the recipient is
wrong, the user's `email:` field is stale — fix it in the file (step 2 above)
**and confirm the reload happened** (a rejected reload keeps the old address in
memory, so mail keeps going to the old one until Authelia is restarted). Then
mirror the fix into the vault. If Brevo shows *Delivered* to the right address
but the user still doesn't see it, it's spam filtering or the recipient's mail
server rejecting `promethence.com` — check the bounce reason in the Brevo log.

#### SMTP relay unreachable (`lookup smtp-relay.brevo.com: i/o timeout`)

Authelia couldn't resolve or reach the relay, so the reset email never left the
server. Diagnose from inside the container's network namespace and from the host:

```bash
# Does DNS resolve from inside the Authelia container's netns?
scont podman exec authelia getent hosts smtp-relay.brevo.com 2>/dev/null \
  || echo "no resolver tools in image — test from another container below"

# Resolve + reach the relay from a throwaway container on the same network:
scont podman run --rm --network edge docker.io/alpine \
  sh -c 'nslookup smtp-relay.brevo.com; nc -zv smtp-relay.brevo.com 587'

# Compare against the host itself:
getent hosts smtp-relay.brevo.com
nc -zv smtp-relay.brevo.com 587
```

Likely causes and fixes:

- **aardvark-dns cold start (most common here).** Podman's per-network resolver
  is slow to answer the *first* external lookup after the container has been
  idle, so Authelia's single SMTP dial times out and the reset errors; clicking
  again succeeds because the resolver is now warm. The Authelia container sets
  `dns_option: [timeout:5, attempts:3]` (`container_dns_options` in
  `group_vars/all/vars.yml`) so its resolver waits and retries instead of failing
  on the first slow answer. If you still see first-attempt timeouts, raise the
  timeout/attempts and redeploy the authelia role.
- **Outbound port 587 blocked** from the server's network. If `nc` from the host
  also fails, it's a firewall/egress policy issue (campus networks often block
  outbound SMTP) — ask DEIB IT, or relay over a permitted port.

Until SMTP is reliable, use method 3 above (admin sets the password directly) or
read the reset URL from `notification.txt` — neither needs email.

---

## Nextcloud — issues

```bash
# Application logs
sudo journalctl _SYSTEMD_USER_UNIT=container-nextcloud.service -n 50

# Nextcloud's own log (more detailed for app-level errors)
scont podman exec --user www-data nextcloud tail -100 /var/www/html/data/nextcloud.log \
  | python3 -m json.tool --no-ensure-ascii 2>/dev/null | grep -A5 '"message"'

# Run an occ command
scont podman exec --user www-data nextcloud php /var/www/html/occ <command>

# Useful occ commands:
scont podman exec --user www-data nextcloud php /var/www/html/occ user:list
scont podman exec --user www-data nextcloud php /var/www/html/occ user:info <username>
scont podman exec --user www-data nextcloud php /var/www/html/occ status
scont podman exec --user www-data nextcloud php /var/www/html/occ maintenance:repair
```

---

## Forgejo — issues

```bash
sudo journalctl _SYSTEMD_USER_UNIT=container-forgejo.service -n 50

# Run a forgejo admin command
scont podman exec --user git forgejo forgejo admin user list
scont podman exec --user git forgejo forgejo admin user info --username <username>
scont podman exec --user git forgejo forgejo admin auth list   # check OIDC source is present
```

---

## Traefik — routing issues

```bash
sudo journalctl _SYSTEMD_USER_UNIT=container-traefik.service -n 50

# If a service returns 502 Bad Gateway after a container restart,
# restart Traefik so it re-discovers the new container IP:
scont systemctl --user restart container-traefik.service
```

---

## Container status

```bash
# All containers and their state
scont podman ps -a

# Systemd unit status (shows restart history)
scont systemctl --user status container-authelia.service
```

---

## SMTP — test the relay without deploying

```bash
swaks \
  --to 'recipient@example.com' \
  --from 'noreply@promethence.com' \
  --server smtp-relay.brevo.com \
  --port 587 --tls \
  --auth LOGIN \
  --auth-user 'your-brevo-login' \
  --auth-password 'your-smtp-api-key' \
  --header 'Subject: SMTP test' \
  --body 'Relay is working.'
```

---

## Restarting services

```bash
scont systemctl --user restart container-authelia.service
scont systemctl --user restart container-nextcloud.service
scont systemctl --user restart container-forgejo.service
scont systemctl --user restart container-traefik.service

# Always restart Traefik after restarting any app container,
# or Traefik will hold the stale container IP and return 502.
```

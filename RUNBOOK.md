# Runbook — diagnostics and common operations

Quick reference for inspecting running services and resolving common problems.
All commands assume you are SSH'd into the server as your personal user
(`sperriello` or similar). The rootless containers run under the `containers`
system user; prefix every `podman` command with the wrapper below, or define
a shell alias for the session:

```bash
alias pc='sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) podman'
```

The examples below use `pc` as that alias.

---

## Inspecting logs

```bash
# Last 50 lines
pc logs authelia   --tail 50
pc logs nextcloud  --tail 50
pc logs forgejo    --tail 50
pc logs traefik    --tail 50

# Live feed (Ctrl-C to stop)
pc logs -f authelia
```

---

## Authelia — user can't log in or reset password

**1. Check the logs while the user tries again:**

```bash
pc logs -f authelia
```

Common error patterns and what they mean:

| Log message | Cause |
|---|---|
| `user not found` | Username not in `users_database.yml` — check spelling, or the entry was never added |
| `authentication failed` | Wrong password. If the user just reset it via the portal, check whether the vault was re-synced (see below) |
| `error reading the authentication database` | `users_database.yml` is malformed — missing field, bad YAML indentation, or a non-argon2 hash |
| `failed to send an email` | SMTP misconfigured or Brevo rejected the message — check SMTP section below |
| `302` to `/auth` repeatedly | Session cookie issue — user should clear cookies and retry |

**2. Confirm the user exists in the live file:**

```bash
sudo grep -A5 'USERNAME' /etc/authelia/users_database.yml
```

If the entry is missing, add it directly (takes effect immediately, no restart):

```bash
sudo nano /etc/authelia/users_database.yml
```

See README § "Adding a user without running the playbook" for the exact format.

**3. Reset the password for them (no SMTP needed):**

Generate a new hash and paste it into the live file:

```bash
# On server or local machine:
pc run --rm docker.io/authelia/authelia:4.39 \
  authelia crypto hash generate argon2 --password 'TempPassword123'

sudo nano /etc/authelia/users_database.yml   # replace the password: field
```

Authelia reloads the file automatically. Tell the user their temporary password
and ask them to reset it via the portal immediately.

> **Remember to update the vault** before the next playbook run, or the change
> will be reverted (`ansible-vault edit host_vars/<host>/vault.yml`).

**4. Password reset via portal isn't sending email:**

```bash
pc logs authelia --tail 30   # look for smtp/notifier errors
```

If SMTP is working but the user doesn't receive the mail:

```bash
# Check if Authelia fell back to the file notifier (means SMTP failed silently):
sudo ls -la /etc/authelia/notification.txt
sudo cat /etc/authelia/notification.txt   # contains the reset URL
```

Send that URL to the user out of band.

---

## Nextcloud — issues

```bash
# Application logs
pc logs nextcloud --tail 50

# Nextcloud's own log (more detailed for app-level errors)
pc exec --user www-data nextcloud tail -100 /var/www/html/data/nextcloud.log \
  | python3 -m json.tool --no-ensure-ascii 2>/dev/null | grep -A5 '"message"'

# Run an occ command
pc exec --user www-data nextcloud php /var/www/html/occ <command>

# Useful occ commands:
pc exec --user www-data nextcloud php /var/www/html/occ user:list
pc exec --user www-data nextcloud php /var/www/html/occ user:info <username>
pc exec --user www-data nextcloud php /var/www/html/occ status
pc exec --user www-data nextcloud php /var/www/html/occ maintenance:repair
```

---

## Forgejo — issues

```bash
pc logs forgejo --tail 50

# Run a forgejo admin command
pc exec --user git forgejo forgejo admin user list
pc exec --user git forgejo forgejo admin user info --username <username>
pc exec --user git forgejo forgejo admin auth list   # check OIDC source is present
```

---

## Traefik — routing issues

```bash
pc logs traefik --tail 50

# If a service returns 502 Bad Gateway after a container restart,
# restart Traefik so it re-discovers the new container IP:
sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
  systemctl --user restart container-traefik.service
```

---

## Container status

```bash
# All containers and their state
pc ps -a

# Systemd unit status (shows restart history)
sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
  systemctl --user status container-authelia.service
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
alias sc='sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) systemctl --user'

sc restart container-authelia.service
sc restart container-nextcloud.service
sc restart container-forgejo.service
sc restart container-traefik.service

# Always restart Traefik after restarting any app container,
# or Traefik will hold the stale container IP and return 502.
```

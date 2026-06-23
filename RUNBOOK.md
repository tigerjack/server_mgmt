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

## Inspecting logs

Because containers are managed with `generate_systemd: new: true`, each restart
runs `podman run --rm` and creates a fresh container — `podman logs` only shows
output since the last restart and is empty if the container just started. Use
**journald** to see logs across restarts:

```bash
# Last 50 lines (survives container restarts)
sudo journalctl _UID=$(id -u containers) -u container-authelia.service -n 50
sudo journalctl _UID=$(id -u containers) -u container-nextcloud.service -n 50
sudo journalctl _UID=$(id -u containers) -u container-forgejo.service -n 50
sudo journalctl _UID=$(id -u containers) -u container-traefik.service -n 50

# Live feed (Ctrl-C to stop)
sudo journalctl _UID=$(id -u containers) -u container-authelia.service -f
```

`podman logs` still works for the current run if you need to check something
immediately after a start:

```bash
scont podman logs --tail 50 authelia
```

---

## Authelia — user can't log in or reset password

**1. Check the logs while the user tries again:**

```bash
sudo journalctl _UID=$(id -u containers) -u container-authelia.service -f
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
scont podman run --rm docker.io/authelia/authelia:4.39 \
  authelia crypto hash generate argon2 --password 'TempPassword123'

sudo nano /etc/authelia/users_database.yml   # replace the password: field
```

Authelia reloads the file automatically. Tell the user their temporary password
and ask them to reset it via the portal immediately.

> **Remember to update the vault** before the next playbook run, or the change
> will be reverted (`ansible-vault edit host_vars/<host>/vault.yml`).

**4. Password reset via portal isn't sending email:**

```bash
sudo journalctl _UID=$(id -u containers) -u container-authelia.service -n 30
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
sudo journalctl _UID=$(id -u containers) -u container-nextcloud.service -n 50

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
sudo journalctl _UID=$(id -u containers) -u container-forgejo.service -n 50

# Run a forgejo admin command
scont podman exec --user git forgejo forgejo admin user list
scont podman exec --user git forgejo forgejo admin user info --username <username>
scont podman exec --user git forgejo forgejo admin auth list   # check OIDC source is present
```

---

## Traefik — routing issues

```bash
sudo journalctl _UID=$(id -u containers) -u container-traefik.service -n 50

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

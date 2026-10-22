# Runbook

Diagnosing and fixing a running server. Commands are run on the server over
SSH as your personal user.

## Basics

Containers run rootless under the `containers` user. Run Podman and
`systemctl --user` commands as that user with the `scont` alias (set up in
[host-setup.md](host-setup.md#6-add-the-scont-alias)):

```bash
alias scont='sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers)'
```

**`cd /tmp` first.** Rootless Podman `chdir`s into your current directory
after switching user; from your home (mode 700) it stops with
`cannot chdir to /home/<you>:` before doing anything.

Each container is a user unit named `container-<name>.service`. The main
names: `traefik`, `authelia`, `static-site`, `nextcloud`, `db_nextcloud`,
`valkey_nextcloud`, `forgejo`, `db_forgejo`, `forgejo-runner`,
`eurooffice-ds`, `collabora`.

**After restarting any app container, restart Traefik too**, or it may keep
routing to the old container IP and return `502`
([why](services.md#traefik-and-stale-container-ips)):

```bash
scont systemctl --user restart container-nextcloud.service
scont systemctl --user restart container-traefik.service
```

## Health check

```bash
cd /tmp

# 1. Containers up, with a sane uptime (no restart loop)
scont podman ps -a

# 2. Each app answers through Traefik (200/302 = alive)
DOMAIN=spqr-project.deib.polimi.it    # or quouskwe-project.deib.polimi.it
for p in / /cloud/ /git/ /auth/; do
  curl -sS -o /dev/null -w "$p %{http_code}\n" "https://$DOMAIN$p"
done

# 3. systemd's view, with recent log lines
scont systemctl --user status container-traefik.service container-authelia.service \
  container-nextcloud.service container-forgejo.service
```

A `502` usually means Traefik has a stale container IP: restart Traefik. A
container missing from `podman ps` crashed on start: read its log.

## Logs

Each start of a unit creates a fresh container, so `podman logs` only covers
the current run. For history across restarts, read the system journal by
**user-unit** field:

```bash
sudo journalctl _SYSTEMD_USER_UNIT=container-nextcloud.service -n 50
sudo journalctl _SYSTEMD_USER_UNIT=container-authelia.service -f      # follow live

scont podman logs --tail 50 authelia                                  # current run only
```

`journalctl -u container-x.service` finds nothing because `-u` matches
*system* units. `scont journalctl --user` fails because `containers` can't
read the journal.

## Traefik

```bash
sudo journalctl _SYSTEMD_USER_UNIT=container-traefik.service -n 50
```

**502 after an overnight auto-update.** The app is healthy (e.g.
`scont podman exec --user www-data nextcloud php occ status` works) but the
public URL returns 502. Restart Traefik, then check the auto-update drop-in
that should have done it:

```bash
scont systemctl --user restart container-traefik.service
scont systemctl --user cat podman-auto-update.service | grep ExecStartPost
```

**Certificates.** Let's Encrypt certificates are in
`/etc/traefik/letsencrypt/acme.json` and renew automatically. To force new
ones, e.g. after testing against the staging CA, delete the file and re-run
the traefik role, which recreates it with the permissions Traefik requires:

```bash
sudo rm /etc/traefik/letsencrypt/acme.json                   # on the server
./deploy.sh --limit <host> --tags traefik                    # on your machine
```

To test without hitting Let's Encrypt rate limits, add
`--certificatesresolvers.letsencrypt.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory`
to the `Run traefik` command in `roles/traefik/tasks/main.yml`. Staging
certificates aren't trusted by browsers; remove the line and reset as above
when done.

## Authelia: login problems

Follow the log while the user tries again:

```bash
sudo journalctl _SYSTEMD_USER_UNIT=container-authelia.service -f
```

| Log message | Meaning |
|---|---|
| `user not found` | Not in `users_database.yml`: typo, or never added to the vault |
| `authentication failed` | Wrong password: [reset it](users.md#reset-a-users-password) |
| `error reading the authentication database` | Broken `users_database.yml`: bad YAML, missing field, or a non-argon2 hash |
| `Error occurred during reload ... permission denied` | The file was edited with plain `sudo` and is now owned by root; Authelia keeps the **old** data. [Fix ownership](users.md#edit-the-live-user-file) |
| `failed to send an email`, `lookup smtp-relay.brevo.com: i/o timeout` | Can't reach the SMTP relay: [see below](#smtp-relay-unreachable) |
| `token_endpoint_auth_method ... does not allow this method` (client `forgejo`) | The `forgejo` client must use `client_secret_basic`, as `configuration.yml.j2` does; redeploy the authelia role |
| repeated `302` to `/auth` | Session cookie problem: the user clears cookies and retries |

Harmless noise, even though it's logged as `error`:

| Log message | Why it's harmless |
|---|---|
| `Request timeout occurred ... i/o timeout ... status_code=408` from Traefik's IP | Traefik's idle keep-alive connections being closed; no user request is lost |
| `token ... already revoked` during `/api/reset-password` | A reset link was opened twice (double click, prefetch, refresh). The first use worked. |

To look at a user's live entry (the file is bind-mounted on the host):

```bash
sudo grep -A6 '  USERNAME:' /etc/authelia/users_database.yml
```

To change it, see [Edit the live user file](users.md#edit-the-live-user-file).

### Password reset mail

Reset mail goes to the `email` in `users_database.yml`, not to what the user
types.

- **No SMTP, or SMTP failed:** Authelia writes the reset link to
  `/etc/authelia/notification.txt`. Send it to the user yourself:
  `sudo cat /etc/authelia/notification.txt`.
- **Sent to the wrong address:** Brevo's log (Transactional → Email → Logs)
  shows the recipient. Fix the user's `email` in the vault and the live file,
  then confirm the reload: a rejected reload keeps the old address in memory.
- **Delivered but not received:** spam filtering or the recipient's server
  rejecting the sender domain; Brevo's log shows the bounce reason.

### SMTP relay unreachable

```bash
cd /tmp
# From a throwaway container on the same network as Authelia:
scont podman run --rm --network edge docker.io/library/alpine \
  sh -c 'nslookup smtp-relay.brevo.com; nc -zv smtp-relay.brevo.com 587'
# From the host:
getent hosts smtp-relay.brevo.com && nc -zv smtp-relay.brevo.com 587
```

- **First attempt times out, second works:** Podman's network DNS
  (aardvark-dns) answers slowly after idling. The authelia role already
  bypasses it with its own `resolv.conf` (`1.1.1.1`, `8.8.8.8`) and a 30 s
  SMTP timeout. Check that the container really uses it, and raise the
  timeout in `configuration.yml.j2` if needed:
  `scont podman exec authelia cat /etc/resolv.conf`.
- **Fails from the host too:** outbound port 587 is blocked on the network.
  Ask DEIB IT, or use another port the relay supports.

To test the relay itself, see [smtp.md](smtp.md#test-the-relay-before-deploying).

## Nextcloud

```bash
cd /tmp
sudo journalctl _SYSTEMD_USER_UNIT=container-nextcloud.service -n 50

# Nextcloud's own log, for app-level errors
scont podman exec --user www-data nextcloud tail -100 /var/www/html/data/nextcloud.log \
  | python3 -m json.tool --no-ensure-ascii 2>/dev/null | grep -A5 '"message"'

# occ
scont podman exec --user www-data nextcloud php occ status
scont podman exec --user www-data nextcloud php occ user:list
scont podman exec --user www-data nextcloud php occ user:info <username>
scont podman exec --user www-data nextcloud php occ app:list
scont podman exec --user www-data nextcloud php occ maintenance:repair

# PHP version, and the hardening ini being active (expect 0)
scont podman exec nextcloud php -v
scont podman exec nextcloud php -r 'echo ini_get("session.upload_progress.enabled"), PHP_EOL;'
```

To pull a fixed image before the nightly update, see
[upgrades.md](upgrades.md#security-fixes).

## Forgejo

```bash
cd /tmp
sudo journalctl _SYSTEMD_USER_UNIT=container-forgejo.service -n 50

scont podman exec --user git forgejo forgejo admin user list
scont podman exec --user git forgejo forgejo admin user info --username <username>
scont podman exec --user git forgejo forgejo admin auth list    # authelia source present?
```

# Services

What each role deploys, followed by the implementation notes that explain
the less obvious config. All containers run rootless as `containers` (except
an [isolated CI runner](ci.md#shared-and-isolated-modes), which runs as `ci`), are
created with `generate_systemd` (unit `container-<name>.service`, restart on
failure), and use the image pins in `group_vars/all/vars.yml`.

## Roles

### `traefik`

Reverse proxy and the only container with host ports: 80 (redirects to
HTTPS), 443, and 2222 (TCP passthrough to Forgejo's SSH server). It discovers
the other containers through the rootless Podman API socket and routes by
their `traefik.*` labels (`exposedByDefault=false`), over the shared `edge`
network. Certificates come from Let's Encrypt (HTTP-01) and are stored in
`/etc/traefik/letsencrypt/acme.json`. A security-headers middleware (HSTS,
nosniff, frame options) from `files/security-headers.yml` applies to every
HTTPS route.

The role also enables `podman-auto-update.timer` and its Traefik-restart
drop-in; see [upgrades.md](upgrades.md#automatic-updates).

### `authelia`

Login portal at `/auth` and the OIDC provider for Nextcloud and Forgejo
(Authelia 4.39, file-based users). Config is rendered to `/etc/authelia/` on
the host and bind-mounted as `/config`. It also defines the `authelia@docker`
forward-auth middleware for routes with no login of their own. Only deployed
when `enable_authelia` is true (the default). Users and passwords:
[users.md](users.md).

### `static_site`

nginx serving `roles/static_site/files/<static_site_dir>/`, copied to
`/etc/static-site/html/` and mounted read-only. Each host sets its own
directory (`site-spqr`, `site-quouskwe`; the latter is a git submodule). Its
router is the catch-all for the domain: longer path rules like `/cloud` win.

### `nextcloud`

Three containers: `nextcloud` (Apache + mod_php image), `db_nextcloud`
(MariaDB) and `valkey_nextcloud` (Redis-compatible cache and locking).
Served at `/cloud`, see [Nextcloud under `/cloud`](#nextcloud-under-cloud).

On each run the role also:

- installs `spreed` (Talk), `eurooffice`, `contacts`, `contactsinteraction`,
  `groupfolders`, `forms`, `polls`, `tasks`; enables `encryption` and
  `notify_push`; disables `photos`;
- routes Office formats to EuroOffice and disables `richdocuments` (the
  Collabora connector);
- sets the DB user's password from the vault (`ALTER USER`), SMTP settings,
  and the Authelia OIDC provider (`user_oidc`);
- mounts `templates/php-hardening.ini.j2` (rendered to
  `/etc/nextcloud/php-hardening.ini`) as `conf.d/zz-hardening.ini`. It
  currently sets `session.upload_progress.enabled = 0`, which Nextcloud
  doesn't use and which closes one attack path of the October 2026 PHP2Shell
  CVEs.

The local `admin` account (from the vault) is created on first install only
and is the break-glass admin; SSO users never get Nextcloud admin.

### `forgejo`

Two containers: `forgejo` and `db_forgejo` (MariaDB). Served at `/git`
(StripPrefix; Forgejo rebuilds URLs from `ROOT_URL`). Its built-in SSH server
listens on 2222 behind Traefik. Registration is limited to external (OIDC)
accounts. The role creates the local admin account, adds Authelia as a login
source on the first run, and re-applies the group mappings on every run (see
[users.md](users.md#groups-and-permissions)).

To use short git remotes, add this to `~/.ssh/config` on your machine:

```
Host example.com
    User git
    Port 2222
    IdentityFile ~/.ssh/id_ed25519   # the key registered in your Forgejo profile
```

Then `git clone example.com:owner/repo.git`. Without it:
`git clone ssh://git@example.com:2222/owner/repo.git`.

### `forgejo_runner`

Forgejo Actions runner: runs each CI job in a container of its own, on the
same host as Forgejo. No web route. How jobs run, writing and testing
workflows, its variables and its shared and isolated modes:
[ci.md](ci.md).

### `eurooffice` and `collabora`

**EuroOffice** (an ONLYOFFICE fork) is the document editor. Nextcloud's
`eurooffice` app points at it at `/eurooffice-ds`, and the browser loads the
editor from there. The image is pinned by digest.

**Collabora** is still deployed (routes `/cool`, `/browser`, `/hosting`) but
Nextcloud doesn't use it, because the nextcloud role disables
`richdocuments`. Set `enable_collabora: false` in a host's `vars.yml` to skip
it and save RAM (promethence-server does). That only stops future deploys;
on a host where it already runs, also
`scont systemctl --user disable --now container-collabora.service`. To switch back,
re-enable `richdocuments` and remove the task that disables it from the
nextcloud role.

## Implementation notes

### Traefik and stale container IPs

Recreating a container gives it a new IP on `edge`. Traefik is supposed to
notice through the Podman socket, but the watch on the rootless socket can
miss the event, and Traefik keeps routing to the old IP: the app works, the
public URL returns `502`. Three safeguards, all needed:

1. `site.yml` ends with a Traefik restart tagged `always`.
2. The authelia role restarts Traefik right after recreating Authelia,
   because the OIDC setup that follows needs `/auth` to work.
3. A `podman-auto-update.service.d/restart-traefik.conf` drop-in restarts
   Traefik after every automatic image update.

If you restart an app container by hand, restart Traefik too.

### Nextcloud under `/cloud`

Nextcloud doesn't officially support a subpath. The role makes it work with:

- **StripPrefix + overwrite variables.** Traefik strips `/cloud` before
  forwarding, and Nextcloud puts it back in every URL it generates via
  `OVERWRITEWEBROOT=/cloud`, `OVERWRITEHOST=<domain>` and
  `OVERWRITEPROTOCOL=https`. `overwrite.cli.url` is set to
  `https://<domain>/cloud/` for cron and `occ`.
- **Federation discovery at the root.** `/ocm-provider` and `/ocs-provider`
  must be served at the domain root, so each has its own router without
  StripPrefix. They're two routers on purpose: a rule with `||` makes Traefik
  v3 silently drop **all** of the container's labels.
- **Explicit services.** The container serves two ports (80 for Nextcloud,
  7867 for `notify_push` at `/cloud/push`), so every router names its
  service with `routers.*.service`. Without it Traefik v3 drops them all.
- **Known cosmetic issue.** The container can't reach its own public URL
  (hairpin NAT), so some admin self-checks show "could not check". The
  features work.

What to check after a Nextcloud major upgrade is in
[upgrades.md](upgrades.md#nextcloud).

### Same-host OIDC

Authelia, Nextcloud and Forgejo share one host and one domain, which needs
two workarounds for the server-to-server OIDC calls:

- **Hairpin through `/etc/hosts`.** Podman copies the host's `/etc/hosts`,
  which maps the FQDN to `127.0.1.1`, so the apps would call themselves
  instead of Traefik. The Forgejo and Nextcloud containers get an `etc_hosts`
  entry mapping the domain to the host's real IP.
- **Nextcloud's local-address block.** Nextcloud refuses to fetch from
  same-host addresses (`LocalServerException`), so the role sets
  `allow_local_remote_servers=true` when Authelia is enabled.

The OIDC issuer is `https://<domain>/auth`, with discovery at
`/auth/.well-known/openid-configuration`; issuer-mismatch errors usually come
from this prefix.

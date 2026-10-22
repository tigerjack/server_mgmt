# Upgrades and image updates

## How images are pinned

All images are set in `ansible/group_vars/all/vars.yml`, always with a
fully-qualified name and never `:latest`. Containers labelled
`io.containers.autoupdate: registry` are updated automatically when their tag
is republished (see [Automatic updates](#automatic-updates)), so the tag
decides how far an automatic update can go:

| Image | Pin | Automatic updates bring |
|---|---|---|
| Traefik, nginx, MariaDB, Authelia, Forgejo runner | `major.minor` | patch releases |
| Valkey | `major` (`8-alpine`) | minor and patch releases |
| Nextcloud (`34-apache`), Forgejo (`15`) | `major` | minor and patch releases; never a new major |
| Collabora | exact version | only a rebuild of that exact tag; bump by hand |
| EuroOffice | digest | nothing; bump by hand (the registry has no version tags) |

Before deploying a new host, or every few months, check the pins are still
supported: [Forgejo releases](https://forgejo.org/releases/) (non-LTS majors
get about three months of fixes),
[Nextcloud](https://hub.docker.com/_/nextcloud),
[Traefik](https://hub.docker.com/_/traefik).

## Automatic updates

The traefik role enables `podman-auto-update.timer` for the `containers`
user. Once a day it pulls each labelled image, and if the tag now points at a
new image it **recreates** that container.

A recreated container comes back with a new IP, which Traefik can miss
(`502`). A drop-in, `podman-auto-update.service.d/restart-traefik.conf`,
restarts Traefik after every run. So when triggering an update by hand,
start the service rather than running bare `podman auto-update`:

```bash
cd /tmp
scont podman auto-update --dry-run                  # what would be updated
scont systemctl --user start podman-auto-update.service
scont systemctl --user list-timers podman-auto-update.timer   # last and next run
```

## Security fixes

When a fix ships in a base image (for example the October 2026 PHP2Shell
CVEs, fixed in PHP 8.5.12 for Nextcloud 34), upstream rebuilds the image
under the **same tag**. The nightly timer picks it up; to get it now and
confirm:

1. Check the version inside the running container, e.g.
   `scont podman exec nextcloud php -v`. Checking the tag isn't enough.
2. If it's still old, start `podman-auto-update.service` as above and check
   again.
3. If it's still old, upstream hasn't republished yet. For a critical,
   exploited bug, consider stopping the service until it does:
   `scont systemctl --user stop container-nextcloud.service`.

## Bumping a version by hand

Read the release notes, change the tag (or digest) in
`group_vars/all/vars.yml`, and deploy that role:

```sh
./deploy.sh --limit <host> --tags <role>
```

Upgrade one host first and let it run for a day before the other.

- **Authelia:** the config targets 4.39. Breaking changes between versions
  usually hit `server.address` path syntax, the `jwks` structure under
  `identity_providers.oidc`, or the notifier address scheme. Check the logs
  after a bump.
- **Collabora:** an unpinned overnight jump (25 → 26) once broke document
  opening, which is why it's an exact pin.
- **EuroOffice:** read the running digest with
  `scont podman inspect eurooffice-ds --format '{{.ImageDigest}}'`.

## Nextcloud

Nextcloud refuses to skip a major version: go **one major at a time**.

1. Back up the database and the `nextcloud-data` volume (same pattern as
   [Forgejo's backup](#1-back-up-before-every-hop)).
2. Set the next major in `nextcloud_image`, e.g. `docker.io/nextcloud:35-apache`.
3. `./deploy.sh --limit <host> --tags nextcloud`, and follow the upgrade in
   `sudo journalctl _SYSTEMD_USER_UNIT=container-nextcloud.service -f`.
4. Check the parts that depend on the `/cloud` subpath
   ([why](services.md#nextcloud-under-cloud)):
   - links in the UI include `/cloud`;
   - `https://<domain>/ocm-provider` and `/ocs-provider` still answer at the
     domain root;
   - `curl -I https://<domain>/cloud/push` returns 200;
   - if the admin overview shows new warnings:
     `scont podman exec --user www-data nextcloud php occ maintenance:repair --include-expensive`.
5. Repeat for the next major.

## Forgejo

Forgejo also goes **one major at a time** (15 → 16 → …). Each hop runs
database migrations on first start and takes about ten minutes plus checks.

### 0. Before the first hop

- Announce a maintenance window. Each hop is a few minutes of downtime; a
  failed one means restoring from backup.
- Read the breaking changes of every major you'll cross
  (<https://forgejo.org/releases/>). The parts of this setup most likely to be
  affected:
  - `FORGEJO__section__KEY` environment variable names (forgejo role)
  - the `forgejo admin auth add-oauth` / `update-oauth` flags used for
    Authelia and the group mappings
  - MariaDB support
  - the built-in SSH server on 2222

### 1. Back up before every hop

```bash
cd /tmp
# Database (root password: vault_forgejo_db_root_password)
scont podman exec db_forgejo mariadb-dump -uroot -p'<ROOT_PW>' --all-databases \
  > ~/forgejo-db-backup-$(date +%F).sql

# Data volume: repositories, avatars, app.ini
sudo -u containers mkdir -p /home/containers/backups
scont podman run --rm -v forgejo-data:/data:ro -v /home/containers/backups:/backup \
  docker.io/library/alpine tar czf /backup/forgejo-data-$(date +%F).tar.gz -C /data .
```

To roll back: restore the previous tag in `vars.yml`, redeploy, recreate the
database from the dump, and untar the data volume.

### 2. Bump one major and deploy

```yaml
# ansible/group_vars/all/vars.yml
forgejo_image: "codeberg.org/forgejo/forgejo:16"
```

```bash
./deploy.sh --limit <host> --tags forgejo
sudo journalctl _SYSTEMD_USER_UNIT=container-forgejo.service -f
```

Don't interrupt a running migration. The unit allows an hour to start.

If the role fails on an unrecognized `add-oauth`/`update-oauth` flag, the CLI
changed. Check what it expects now and adjust the argument lists in
`ansible/roles/forgejo/tasks/main.yml`:

```bash
scont podman exec --user git forgejo forgejo admin auth update-oauth --help | grep -i group
```

### 3. Check before the next hop

- [ ] `https://<domain>/git/` loads
- [ ] a normal user can log in through Authelia
- [ ] an existing repository browses (file list and a file)
- [ ] `git clone` and `git push` over SSH (port 2222) work
- [ ] `scont podman exec --user git forgejo forgejo admin auth list` still
      shows the `authelia` source
- [ ] a user in a mapped group is still in their teams
      ([query](users.md#forgejo-teams-from-groups))

# Purpose
The goal is to have a single configuration for different servers that should
run:
- Static site
- Nextcloud
- Forgejo

Up to now, the managed servers are:
- spqr-project
- quouskwe-project
- (planned) promethence

## Assumptions
- All hosts already have podman and a rootless `containers` system user set up,
  with `loginctl enable-linger containers` so its systemd user services keep
  running without an active login session. This playbook doesn't (re-)provision
  that. For podman setup, check PODMAN-README.md
- Firewall rules and any upstream routing are handled elsewhere - this
  playbook only opens ports inside the containers it manages. The full
  set of ports that need to reach these hosts from outside is: 80, 443,
  and 2222 (all three terminate in the single `traefik` container).
- DNS for each host's `domain` (see `host_vars/`) already points at that
  host. Each is a single hostname - no wildcard or subdomain control
  needed, since everything lives under one domain via subdirectories:
  `/` (landing page), `/cloud` (Nextcloud), `/git` (Forgejo).

## First run
```
mkdir group_vars/all # first
cp group_vars/vault.yml.example group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml                            # fill in real secrets
ansible-vault encrypt group_vars/all/vault.yml
$EDITOR host_vars/quouskwe-project.yml host_vars/spqr-project.yml  # real domains
ansible-playbook site.yml --ask-vault-pass
```

## What's where
- `roles/traefik` - the only container with host ports published. Owns
  TLS (Let's Encrypt via HTTP-01, since there's just one hostname per
  server - no need for a wildcard/DNS-01 challenge) and discovers every
  other container automatically via podman's docker-compatible socket
  and `traefik.*` labels. Also TCP-forwards Forgejo's SSH traffic on
  :2222, so SSH doesn't need its own host port mapping outside Traefik.
- `roles/static_site` - nginx serving a read-only bind mount, behind
  Traefik's catch-all router (matches anything `/cloud` and `/git`
  didn't already claim).
- `roles/nextcloud` - app + mariadb + valkey (Valkey replaces Redis here:
  same wire protocol, same `REDIS_HOST` env var Nextcloud already
  expects, but a permissively-licensed, actively-growing open-source
  project rather than Redis's post-2024 source-available license).
  Mounted at `/cloud`, with the prefix stripped before it reaches the
  app and `OVERWRITEWEBROOT` telling Nextcloud to put the prefix back
  into any links/URLs it generates.
- `roles/forgejo` - app + its own mariadb, mounted at `/git` with the
  prefix left intact (Forgejo expects the proxy to forward the path
  as-is, the opposite of Nextcloud). Rootless image, to match the
  no-root-in-containers posture everything else here uses; SSH is
  Forgejo's built-in Go SSH server (the rootless image can't bind
  OpenSSH on a privileged port), exposed only through Traefik's TCP
  router.

## Version policy
Every image is pinned to a major.minor tag in `group_vars/all.yml`
rather than `:latest`. `podman-auto-update` (enabled by the traefik role,
since it only needs enabling once per host) picks up patch releases
published under the same tag automatically; you bump the major.minor
yourself, deliberately, after reading release notes - this matters most
for Nextcloud, which refuses to skip a major version on upgrade.
Forgejo specifically has a fast-moving non-LTS track (~3 months of
support per release) versus a once-a-year LTS track - re-check
https://forgejo.org/releases/ before you deploy, the pinned tag here may
already be stale by the time you run this.

## Cloning from Forgejo
Since SSH is on a non-default port, either pass it explicitly:
`git clone ssh://git@<domain>:2222/<owner>/<repo>.git`, or add a
`Host` block to your local `~/.ssh/config` so plain `git@<domain>:...`
remotes work too.


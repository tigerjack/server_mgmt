# CLAUDE.md

Ansible playbook that deploys a self-hosted stack (Traefik, static site,
Nextcloud, Forgejo + Actions runner, Authelia SSO, EuroOffice/Collabora) as
**rootless Podman containers** under a `containers` system user, all behind
**one domain** with path-based routing (no subdomains).

Detailed docs — read the relevant one before changing behaviour it describes:

- `README.md` — overview, architecture, doc index, repo layout
- `docs/host-setup.md` — one-time host prep (rootless Podman, sudo-rs swap, `scont`)
- `docs/deploying.md` — adding a host, vault secrets, `deploy.sh` credentials, what a run does
- `docs/services.md` — per-role reference; Traefik stale IPs, Nextcloud subpath, same-host OIDC
- `docs/users.md` — Authelia users, passwords, groups → Forgejo/Nextcloud permissions
- `docs/smtp.md` — SMTP relay setup
- `docs/upgrades.md` — image pins, auto-update, security fixes, Nextcloud/Forgejo majors
- `docs/runbook.md` — on-server diagnostics (logs, common fixes)

Keep these docs in sync when you change behaviour they describe. Each topic
lives in one file; link to it rather than repeating it.

## Commands

```sh
./deploy.sh                              # all hosts, all roles
./deploy.sh --limit spqr-project         # one host
./deploy.sh --limit <host> --tags forgejo  # one role (tag = role name)
./deploy.sh --check                      # any ansible-playbook flag is forwarded
PLAYBOOK=verify.yml ./deploy.sh --limit <host>  # read-only smoke test (verify.yml)

# Syntax check (run from ansible/ so ansible.cfg is picked up)
cd ansible && ansible-playbook site.yml --syntax-check --vault-password-file ../.vault_pass

ansible-vault edit ansible/host_vars/<host>/vault.yml
```

`deploy.sh` uses `.vault_pass` if present (else prompts) and only adds
`--ask-become-pass` when no `ansible_become_pass` is found in vars or vaults.
It `cd`s into `ansible/` because `ansible.cfg` must be in the CWD.

There are no tests or linters; verify with `--syntax-check`, with
`--check --limit <host> --tags <role>` against a real host when possible, and
after a deploy with `verify.yml` (services answer, units active, runner
connected). `--check` fails at a `podman_container` + `generate_systemd`
task when the container doesn't exist yet; that's a check-mode artifact.

## Layout

- `ansible/site.yml` — one play per role, in dependency order: `traefik` →
  `authelia` (only when `enable_authelia`) → `static_site` → `nextcloud` →
  `forgejo` → `forgejo_runner` → `collabora` (only when `enable_collabora`) →
  `eurooffice`, then a final Traefik restart play tagged `always`.
- `ansible/group_vars/all/vars.yml` — image pins and shared defaults.
  `vault.yml` here holds only `acme_email`.
- `ansible/host_vars/<host>/{vars.yml,vault.yml}` — per-host config and
  secrets. Hosts: `spqr-project`, `quouskwe-project` (must also be listed in
  `inventory.yml`); `promethence-server` has host_vars with TODO placeholders
  and is commented out in the inventory until they're filled in.
  `example-server.yml` and `*.yml.example` are templates.
- `ansible/roles/<role>/tasks/main.yml` — task files. Templates go in
  `templates/`, static files in `files/`.
- `ansible/roles/static_site/files/<static_site_dir>/` — per-host landing page
  (`site-spqr`, `site-quouskwe`; the latter is a git submodule).
- `scripts/` — one-off helpers (`convert.py`: Authelia users DB → vault
  `authelia_users`; `notify-usernames.sh`: mail users their username, dry-run
  by default).

## Conventions

- **Every container runs rootless as `containers_user`**: tasks use
  `become: true` + `become_user: "{{ containers_user }}"` and
  `ansible.builtin.systemd: scope: user`. Containers are created with
  `containers.podman.podman_container` + `generate_systemd` (`new: true`,
  `restart_policy: on-failure`), giving `container-<name>.service` user units.
  Roles follow the pattern: stop the unit (`failed_when: false`) → create
  dirs/config → (re)create the container → enable/start the unit.
  Exception: with `forgejo_runner_isolated: true` the runner and its jobs run
  as `forgejo_runner_ci_user` (`ci`) instead, with their own Podman socket and
  network, so CI can't reach production (`docs/services.md`).
- **Fully-qualified image names** always (`docker.io/library/...`); never bare
  names, never `:latest`. Pin `major.minor` so `podman-auto-update` only picks
  up patches (label `io.containers.autoupdate: "registry"`). Exceptions:
  Nextcloud, Forgejo and Valkey pin only the major; Collabora is an exact
  version pin and EuroOffice is a digest pin (auto-update doesn't apply to
  digests), both bumped by hand.
- **Routing is via Traefik labels** on each container (`traefik.enable=true`;
  `exposedByDefault=false`). Traefik is the only container with host ports
  (80/443/2222) and reaches others on the shared `edge` network.
- **Secrets live in the per-host vault** (`vault_*` vars), never in plain vars
  and never shared across hosts. Vault files are committed **encrypted** to a
  **public** repo. Never commit one decrypted (check `head -1` shows
  `$ANSIBLE_VAULT`), and never print decrypted vault contents.
- Files use the `# {{ ansible_managed }}` header. **`ansible_managed` is only
  defined in the `template` module.** Using it in `copy: content:` fails on
  current ansible-core. Put managed files in `roles/<role>/templates/*.j2`.

## Gotchas that shape the code

- **Traefik stale-IP 502s.** Recreating a container gives it a new IP, and
  Traefik's rootless-socket watch can miss the change. That's why `site.yml`
  ends with an `always` Traefik restart, the authelia role restarts Traefik
  after (re)creating its container, and the traefik role installs a
  `podman-auto-update.service.d/restart-traefik.conf` drop-in. Keep all three.
- **Nextcloud under `/cloud`** relies on StripPrefix + `OVERWRITEWEBROOT`/
  `OVERWRITEHOST`/`OVERWRITEPROTOCOL`, two separate routers for
  `/ocm-provider` and `/ocs-provider` at the root (an `||` rule makes Traefik
  v3 silently drop all of the container's labels), and explicit
  `routers.*.service` labels because the container serves two ports.
- **Same-host OIDC**: Forgejo/Nextcloud get an `etc_hosts` override mapping
  the domain to the real host IP (Podman maps the FQDN to `127.0.1.1`), and
  Nextcloud needs `allow_local_remote_servers=true`.
- **Isolated CI runner**: `ci` can't join `edge`, so it reaches Forgejo via
  Traefik on the host IP. pasta can't reach the host's own IP from a
  namespace without Traefik's port forwarding, so `ci` uses slirp4netns
  (gone in Podman 6). The role probes the route on every deploy.
- **Authelia** config targets 4.39. `users_database.yml` is re-rendered from
  the vault's `authelia_users` on every run, but the role first reads the
  server copy and keeps each existing user's password hash (users reset their
  own passwords in place). The vault decides who exists, emails, names and
  groups; its `password_hash` only seeds new users.
- **EuroOffice is the editor**: the nextcloud role routes Office formats to it
  and disables `richdocuments` (Collabora).
- **Forgejo / Nextcloud majors** must be upgraded one major at a time.
- The quouskwe host ran `sudo-rs`, which Ansible can't drive ("Timeout waiting
  for privilege escalation prompt"). See `docs/host-setup.md` step 1.

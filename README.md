# server_mgmt

Ansible playbook that deploys a self-hosted collaboration stack as **rootless
Podman containers**, all behind **one domain** with path-based routing:

| Path | Service |
|---|---|
| `/` | Static landing page (nginx) |
| `/cloud` | Nextcloud: files, calendar, contacts, Talk; EuroOffice is the document editor |
| `/git` | Forgejo (git forge) with a same-host Actions runner; git over SSH on port `2222` |
| `/auth` | Authelia: login portal and OIDC single sign-on for Nextcloud and Forgejo |

Managed hosts: `spqr-project`, `quouskwe-project`.

## Architecture

```
Browser ──► Traefik :80/:443 ─┬─► /               static site
                              ├─► /cloud          Nextcloud ──┐
                              ├─► /git            Forgejo   ──┼── log in via Authelia (OIDC)
                              ├─► /auth           Authelia  ◄─┘
                              └─► /eurooffice-ds  EuroOffice document server (opened from Nextcloud)
        Traefik :2222 ────────► Forgejo git over SSH
```

- Every container runs **rootless** under a `containers` system user and is
  managed as a systemd user unit, `container-<name>.service`.
- **Traefik** is the only container with host ports. It discovers the others
  through the rootless Podman API socket, routes them by their `traefik.*`
  labels over a shared `edge` network, and gets TLS certificates from Let's
  Encrypt.
- There are **no subdomains**. Running Nextcloud and Forgejo under a subpath
  needs a few workarounds, described in
  [services.md](docs/services.md#implementation-notes).
- **Secrets** live in a per-host Ansible vault, committed to this public repo
  **encrypted**.

## Documentation

| Read | When you want to |
|---|---|
| [docs/host-setup.md](docs/host-setup.md) | Prepare a fresh server (rootless Podman, `containers` user, sudo). Once per host. |
| [docs/deploying.md](docs/deploying.md) | Add a host, fill in its secrets, run the playbook |
| [docs/services.md](docs/services.md) | Know what each role deploys and why the unusual config is there |
| [docs/users.md](docs/users.md) | Add or remove users, reset passwords, map groups to permissions |
| [docs/smtp.md](docs/smtp.md) | Turn on outgoing mail (password resets, notifications) |
| [docs/upgrades.md](docs/upgrades.md) | Understand image pins and auto-updates, apply a security fix, upgrade Nextcloud or Forgejo to a new major |
| [docs/runbook.md](docs/runbook.md) | Diagnose or fix something on a running server |

## Everyday commands

From the repo root:

```sh
./deploy.sh                                        # all hosts, all roles
./deploy.sh --limit spqr-project                   # one host
./deploy.sh --limit spqr-project --tags authelia   # one role (tag = role name)
./deploy.sh --limit spqr-project --check --diff    # dry run; any ansible-playbook flag is forwarded

ansible-vault edit ansible/host_vars/<host>/vault.yml   # a host's secrets and users

# Syntax check (from ansible/, so ansible.cfg is picked up)
cd ansible && ansible-playbook site.yml --syntax-check
```

## Repository layout

```
deploy.sh                      wrapper around ansible-playbook (finds vault and sudo passwords)
ansible/
  ansible.cfg                  must be in the working directory; deploy.sh cd's here
  inventory.yml                host list; every host must be listed here
  site.yml                     one play per role, in dependency order
  group_vars/all/
    vars.yml                   image pins and shared defaults
    vault.yml                  ENCRYPTED; holds only acme_email
  host_vars/
    example-server.yml         template for a new host's vars.yml
    <host>/vars.yml            per-host config: address, domain, feature flags
    <host>/vault.yml           ENCRYPTED per-host secrets and Authelia users
    <host>/vault.yml.example   commented template of every secret
  roles/
    traefik/                   reverse proxy, TLS, podman-auto-update timer
    authelia/                  SSO portal and OIDC provider
    static_site/               landing page; files/<static_site_dir>/ per host
                               (files/site-quouskwe is a git submodule)
    nextcloud/                 Nextcloud + MariaDB + Valkey
    forgejo/                   Forgejo + MariaDB
    forgejo_runner/            Forgejo Actions runner
    eurooffice/                EuroOffice document server (Nextcloud's editor)
    collabora/                 Collabora document server (deployed, not used by Nextcloud)
scripts/
  convert.py                   Authelia users_database.yml -> vault authelia_users list
  notify-usernames.sh          email every user their username (dry run by default)
docs/                          see the table above
CLAUDE.md                      notes for AI coding agents working on this repo
```

Clone with `git clone --recurse-submodules`, or run `git submodule update
--init` in an existing clone, so the quouskwe landing page is present.

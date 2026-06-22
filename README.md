# server_mgmt

Ansible playbook for managing self-hosted servers running:

- **Static landing page** at `/`
- **Nextcloud** at `/cloud`
- **Forgejo** at `/git` (HTTP) and `:2222` (SSH)
- **Collabora Online** (document server, secondary)
- **EuroOffice Document Server** (document server, primary)

Everything runs as rootless Podman containers under a dedicated `containers`
system user. Traefik handles TLS (Let's Encrypt HTTP-01) and reverse-proxies
all services from a single domain.

---

## Prerequisites

Each target host needs:

- A `containers` system user with lingering enabled and a working rootless
  Podman setup — follow **PODMAN-README.md** once per host before running the
  playbook.
- A public DNS A record pointing your domain at the server's IP (needed for
  Let's Encrypt to issue a certificate).
- Ports 80, 443, and 2222 reachable from the internet.

---

## What to change before first run

### 1. Add a host file

Create `ansible/host_vars/<your-hostname>.yml` by copying the example:

```sh
cp ansible/host_vars/example-server.yml ansible/host_vars/myserver.yml
$EDITOR ansible/host_vars/myserver.yml
```

Fields to fill in:

| Field | What to put |
|---|---|
| `ansible_host` | Server IP or resolvable hostname |
| `ansible_user` | `root` (all servers require root SSH access) |
| `ansible_ssh_private_key_file` | Path to **your personal SSH key** — the same one you already use to SSH into this server manually (e.g. `~/.ssh/id_ed25519`). |
| `domain` | Your public domain, e.g. `example.com`. All three services live under this one domain. |

One file per server. If a server runs only some services, edit `ansible/site.yml`
to limit which roles apply to which hosts (use `hosts:` with a specific hostname
or a group).

### 2. Create and encrypt the vault

```sh
cd ansible
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml   # fill in every CHANGE_ME value
ansible-vault encrypt group_vars/all/vault.yml
```

The vault holds all secrets: database passwords, the Nextcloud admin password,
and the Forgejo admin account. The `.example` file lists every variable with a
description. **Never commit `vault.yml` unencrypted.**

Optionally, save the vault password in `.vault_pass` (already in `.gitignore`)
so you don't have to type it every run:

```sh
echo "your-vault-password" > .vault_pass
chmod 600 .vault_pass
```

### 3. Check image versions

`ansible/group_vars/all/vars.yml` pins every image to a `major.minor` tag.
Before deploying, verify the pinned tags are still current — especially Forgejo,
which has a short support window (~3 months per non-LTS release):

- Forgejo releases: <https://forgejo.org/releases/>
- Nextcloud: <https://hub.docker.com/_/nextcloud>
- Traefik: <https://hub.docker.com/_/traefik>

---

## Running the playbook

Ansible SSHes in as your personal user and uses `sudo` for privileged tasks.
You need to supply both your vault password and your sudo password:

```sh
cd ansible

# Standard run - prompts for vault password then sudo password:
ansible-playbook site.yml --ask-vault-pass --ask-become-pass

# With a vault password file (only sudo prompt remains):
ansible-playbook site.yml --vault-password-file ../.vault_pass --ask-become-pass

# Limit to a single host:
ansible-playbook site.yml --vault-password-file ../.vault_pass --ask-become-pass --limit spqr-project

# Limit to a single role (e.g. after updating Forgejo config):
ansible-playbook site.yml --vault-password-file ../.vault_pass --ask-become-pass --tags forgejo
```

If you want to avoid typing the sudo password every run, add it to the vault:

```sh
# In vault.yml, add:
vault_become_pass: "your_sudo_password"

# In group_vars/all/vars.yml, add:
ansible_become_pass: "{{ vault_become_pass }}"
```

Then you only need `--vault-password-file` and no `--ask-become-pass`.

---

## What each role does

### `traefik`

The only container with host ports (80, 443, 2222). Discovers all other
containers via the rootless Podman API socket and routes traffic based on
`traefik.*` labels. Issues and renews TLS certificates automatically via
Let's Encrypt HTTP-01. Also TCP-forwards Forgejo's git-over-SSH on port 2222.

### `static_site`

Nginx serving a read-only bind-mount from `roles/static_site/files/site/`.
Acts as the catch-all router (matches everything that `/cloud` and `/git`
don't claim). Replace `index.html` with your actual landing page content.

### `nextcloud`

Three containers: the Nextcloud app (Apache variant), MariaDB, and Valkey
(a Redis-compatible cache with a permissive open-source licence).

Mounted at `/cloud` via Traefik's StripPrefix middleware — Nextcloud receives
requests at `/` and rebuilds `/cloud` URLs itself via the `OVERWRITEWEBROOT`
env var.

> **Note:** Nextcloud does not officially support subpath installs. This setup
> works in practice but may break on major upgrades. If you hit issues, the
> fallback is a dedicated subdomain (`cloud.example.com`).

### `forgejo`

Two containers: Forgejo app and its own MariaDB instance. Mounted at `/git`
via Traefik's StripPrefix middleware — Forgejo receives requests at `/` and
reconstructs `/git` URLs itself via `ROOT_URL` in `app.ini`.

SSH git access is on port 2222 (TCP-forwarded through Traefik):

```sh
# Clone explicitly with port:
git clone ssh://git@example.com:2222/owner/repo.git

# Or add to ~/.ssh/config to use plain git@ remotes:
Host example.com
    Port 2222
```

### `collabora`

Collabora Online document server (secondary). Connected to Nextcloud via the
`richdocuments` app. Runs on the internal `edge` network; not exposed directly.

### `eurooffice`

EuroOffice Document Server (primary, ONLYOFFICE-compatible). Connected to
Nextcloud via the `eurooffice` app. Like Collabora it runs on the internal
network only. Both document servers are deployed; Nextcloud uses EuroOffice
by default — Collabora is available as a fallback.

---

## After deployment

### Let's Encrypt certificates

Traefik requests certificates from **Let's Encrypt production** immediately on
first deploy. Certificates are stored in `/etc/traefik/letsencrypt/acme.json`
on the host (bind-mounted into the Traefik container) and renewed automatically.

If you want to test the stack before going live (e.g. to avoid hitting
Let's Encrypt's rate limits during iteration), add the staging CA flag to the
`Run traefik` task in `roles/traefik/tasks/main.yml`:

```yaml
- "--certificatesresolvers.letsencrypt.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory"
```

Staging issues untrusted certs but has no rate limits. When you're ready for
production, remove that line, re-run the traefik role, and delete `acme.json`
so a fresh certificate is requested:

```sh
# On the server, as the containers user:
rm /etc/traefik/letsencrypt/acme.json
systemctl --user restart container-traefik.service
```

### Automatic image updates

The traefik role enables `podman-auto-update.timer`, which checks daily for
new patch releases published under the same `major.minor` tag and restarts
affected containers. To bump a major or minor version, update the tag in
`group_vars/all/vars.yml` and re-run the relevant playbook.

### Nextcloud major version upgrades

Nextcloud refuses to skip a major version. Upgrade one major version at a
time: update the image tag, run the playbook, wait for the upgrade to
complete, then repeat for the next major version.

---

## Repository structure

```
deploy.sh                  # Convenience wrapper around ansible-playbook
ansible/
  ansible.cfg              # Ansible configuration (sets inventory = inventory.yml)
  inventory.yml            # Host list — add your servers here
  site.yml                 # Master playbook (runs all roles in order)
  group_vars/all/
    vars.yml               # Image tags and shared non-secret config
    vault.yml.example      # Template for secrets (copy → vault.yml, encrypt)
    vault.yml              # ENCRYPTED secrets - never commit unencrypted
  host_vars/
    example-server.yml     # Template for per-server config (copy and rename)
    <your-server>.yml      # One file per managed server
  roles/
    traefik/tasks/main.yml            # Reverse proxy + TLS
    static_site/tasks/main.yml        # Landing page (nginx)
    static_site/files/site/index.html # Landing page HTML - edit freely
    nextcloud/tasks/main.yml          # Nextcloud + MariaDB + Valkey
    forgejo/tasks/main.yml            # Forgejo + MariaDB
    collabora/tasks/main.yml          # Collabora Online document server
    eurooffice/tasks/main.yml         # EuroOffice document server (primary)
README.md                  # This file
PODMAN-README.md           # One-time host setup (rootless Podman + containers user)
```

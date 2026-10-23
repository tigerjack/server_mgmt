# Deploying

How to add a host and run the playbook. The example host is `myserver` with
domain `example.com`.

## Prerequisites

- The host is prepared per [host-setup.md](host-setup.md): rootless Podman,
  the `containers` user with lingering, DNS and open ports, plus the `ci`
  user if it will run an isolated CI runner (step 9).
- On your machine: the full `ansible` package (it includes the
  `containers.podman` and `community.general` collections the roles use), and
  this repo cloned **with submodules** (`git submodule update --init`).

## Add a new host

### 1. List it in the inventory

```yaml
# ansible/inventory.yml
all:
  hosts:
    spqr-project:
    myserver:          # must match the host_vars/<name>/ directory
```

A `host_vars/` directory alone is not enough. Without this entry Ansible
fails with *"Could not match supplied host pattern"*.

### 2. Create its config

```sh
cd ansible
mkdir host_vars/myserver
cp host_vars/example-server.yml             host_vars/myserver/vars.yml
cp host_vars/spqr-project/vault.yml.example host_vars/myserver/vault.yml.example
cp host_vars/myserver/vault.yml.example     host_vars/myserver/vault.yml
```

In `vars.yml`:

| Variable | Value |
|---|---|
| `ansible_host` | server IP or hostname |
| `ansible_user` | your SSH login user |
| `ansible_ssh_private_key_file` | your SSH key, e.g. `~/.ssh/id_ed25519` |
| `domain` | public domain; every service lives under it |
| `static_site_dir` | landing page directory under `roles/static_site/files/` |
| `enable_smtp`, `smtp_*` | optional, see [smtp.md](smtp.md) |
| `enable_authelia` | `true` by default; `false` skips SSO entirely |
| `enable_collabora` | `true` by default; `false` skips the unused Collabora server |
| `forgejo_runner_isolated` | `false` by default; `true` runs CI as the `ci` user, see [services.md](services.md#forgejo_runner) |

Any default in `group_vars/all/vars.yml` can be overridden here.

### 3. Fill in its secrets

Every variable in `vault.yml` has a comment explaining what it is and how to
generate it. In short:

| Secrets | How to generate |
|---|---|
| Database and admin passwords (`vault_*_db_*`, `vault_*_admin_*`), `vault_eurooffice_jwt_secret` | free choice; `openssl rand -hex 32` is a good default |
| `vault_authelia_session_secret`, `vault_authelia_storage_encryption_key`, `vault_authelia_jwt_secret`, `vault_authelia_oidc_hmac_secret` | `openssl rand -hex 32`, a different value for each |
| `vault_authelia_oidc_jwks_key` (signs the tokens Authelia issues) | `openssl genrsa 4096`; paste the whole PEM, indented under the `\|` |
| `vault_oidc_{forgejo,nextcloud}_client_secret` and `..._hash` | see below, once per app |
| `vault_smtp_user`, `vault_smtp_password` | only with SMTP, see [smtp.md](smtp.md) |
| `vault_forgejo_runner_secret` | only with `forgejo_runner_isolated`: `openssl rand -hex 20` (exactly 40 hex characters) |
| `authelia_users` | at least one user, see [users.md](users.md#add-a-user) |

OIDC client secrets come as a plaintext + hash pair:

```sh
podman run --rm docker.io/authelia/authelia:4.39 \
  authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 48
# "Random Password" -> vault_oidc_<app>_client_secret       (used by the app)
# "Digest"          -> vault_oidc_<app>_client_secret_hash  (stored by Authelia)
```

Generate everything fresh for each host; hosts never share secrets, keys or
users. Then encrypt:

```sh
ansible-vault encrypt host_vars/myserver/vault.yml
head -1 host_vars/myserver/vault.yml      # must print $ANSIBLE_VAULT;...
```

### 4. Create the global vault (first host only)

It holds a single value shared by all hosts, the Let's Encrypt account email:

```sh
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml          # set acme_email
ansible-vault encrypt group_vars/all/vault.yml
```

### 5. Check the image pins

Make sure the tags in `group_vars/all/vars.yml` are still supported, Forgejo
especially (non-LTS releases get about three months of fixes). See
[upgrades.md](upgrades.md#how-images-are-pinned).

### 6. Deploy and verify

```sh
./deploy.sh --limit myserver
```

```sh
for p in / /cloud/ /git/ /auth/; do
  curl -sS -o /dev/null -w "$p %{http_code}\n" "https://example.com$p"
done
```

`200` or `302` means the service is up. The first certificate can take a
minute. For a `502` or TLS errors see [runbook.md](runbook.md#traefik).

## Running the playbook

### Passwords `deploy.sh` needs

- **Vault password.** Read from `.vault_pass` in the repo root if present
  (gitignored; `chmod 600`), otherwise prompted.
- **Sudo password.** Not prompted if `ansible_become_pass` is set in plain
  vars, or inside a vault that `deploy.sh` can decrypt with `.vault_pass`.
  Otherwise it adds `--ask-become-pass`, which takes **one** password for all
  hosts. If the hosts' sudo passwords differ, deploy with `--limit` one host at
  a time, or store each password in its host vault:
  ```yaml
  # host_vars/<host>/vault.yml
  ansible_become_pass: "that host's sudo password"
  ```
  A value in the vault wins over what you type at the prompt, so update it if
  you change your sudo password on the server.

### What a run does

- `site.yml` runs one play per role, in dependency order: `traefik` →
  `authelia` → `static_site` → `nextcloud` → `forgejo` → `forgejo_runner` →
  `collabora` → `eurooffice`. Each play is tagged with its role name.
- Each role **stops its containers first**, rewrites their config, recreates
  them and starts them again, so that service is briefly down. If a run fails
  in the middle of a role, the service can stay stopped. Fix the cause and
  re-run, or start it by hand:
  `cd /tmp && scont systemctl --user start container-<name>.service`.
- A final play, tagged `always`, restarts Traefik on every run, even with
  `--tags`, so it picks up the recreated containers' new IPs (see
  [services.md](services.md#traefik-and-stale-container-ips)).

### Vault hygiene

Vault files are committed **encrypted** to a **public** repo. Before every
commit, `head -1` of each `vault.yml` must show `$ANSIBLE_VAULT`. Never commit
`.vault_pass`, and never print decrypted vault contents into logs or issues.

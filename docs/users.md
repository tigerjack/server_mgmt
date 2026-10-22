# Users and single sign-on

Regular users log in through **Authelia** at `https://<domain>/auth`, and the
same login works for Nextcloud and Forgejo (OIDC). There is **no
self-registration**: a person can log in only if they're in the
`authelia_users` list of that host's vault. Each host has its own users.

Nextcloud and Forgejo accounts are created on a user's first SSO login. The
local admin accounts from the vault bypass Authelia and are for setup and
emergencies only.

From the portal users can log in, set up TOTP, change their password in
settings, and reset a forgotten one. Reset mail needs [SMTP](smtp.md); without
it, see [runbook.md](runbook.md#password-reset-mail).

## Where user data lives

Authelia reads `/etc/authelia/users_database.yml` on the server. The
authelia role re-renders that file on every run, merging two sources:

| Data | Comes from |
|---|---|
| Which users exist, their email, display name, groups, `disabled` | **the vault** (`authelia_users`) |
| Password of a user already in the server file | **the server file**; deploys keep it |
| Password of a new user | the vault's `password_hash`, used once to create them |

In practice:

- Passwords users set themselves survive deploys. There is nothing to copy
  back into the vault.
- Changing `password_hash` in the vault does **not** change an existing
  user's password. To reset one, edit the server file
  ([below](#reset-a-users-password)).
- A user who is only in the server file is **removed** on the next deploy.
  Every user must be in the vault.
- The vault hashes are only a fallback: if the server file is ever lost (for
  example after rebuilding the host), users get back the password from their
  vault entry.

## Add a user

1. **Make a password hash.** Prefer a random throwaway password, so the
   person picks their own with *Forgot password?* and you never handle it:
   ```sh
   podman run --rm docker.io/authelia/authelia:4.39 \
     authelia crypto hash generate argon2 --password 'some-random-throwaway'
   ```
2. **Add them to the host's vault** with
   `ansible-vault edit ansible/host_vars/<host>/vault.yml`:
   ```yaml
   authelia_users:
     - username: "alice"              # unique, lowercase
       displayname: "Alice Rossi"
       email: "alice@polimi.it"       # reset mail goes here, so get it right
       password_hash: "$argon2id$v=19$..."
       groups: [users]                # see "Groups and permissions"
   ```
   The role refuses to run if `username`, `email` or an `$argon2…`
   `password_hash` is missing. A broken entry in the server file would stop
   Authelia from starting, locking everyone out.
3. **Deploy Authelia:** `./deploy.sh --limit <host> --tags authelia`. Logins
   are down for a few seconds while Authelia and Traefik restart.
4. **Tell them.** They log in at `https://<domain>/auth`, or reset their
   password first. `scripts/notify-usernames.sh` (run on the server) emails
   every user their username; it's a dry run unless you pass `--send`.

To give access right away without a deploy, see
[Edit the live user file](#edit-the-live-user-file), then still add them to
the vault.

## Remove or disable a user

Set `disabled: true` on their entry, or delete it, and deploy Authelia. They
can no longer log in via SSO. Their Nextcloud and Forgejo accounts and data
are kept; disable or delete those in each app if needed.

## Reset a user's password

- **They do it:** *Forgot password?* on the portal (needs SMTP), or the
  password change in the portal settings while logged in.
- **You do it:** generate a hash as above, then replace that user's
  `password:` field in the server file
  ([how to edit it](#edit-the-live-user-file)). Authelia reloads it, and later
  deploys keep it. Send them the temporary password and ask them to change it.

Optionally also put the new hash in the vault as `password_hash`, so the
fallback is current.

## Edit the live user file

For changes that can't wait for a deploy, such as granting access now or
fixing a wrong email. Authelia watches the file and reloads it on save.

1. Edit it **as the `containers` user**:
   ```bash
   sudo -u containers nano /etc/authelia/users_database.yml
   ```
   > **Never use plain `sudo nano`.** It saves the file owned by `root`;
   > Authelia (running as `containers`) can't read it, the reload fails with
   > `permission denied`, and the **old** data stays in memory. A typical
   > result is reset mail still going to the old address. To repair:
   > ```bash
   > sudo chown containers:containers /etc/authelia/users_database.yml
   > sudo chmod 600 /etc/authelia/users_database.yml
   > sudo -u containers touch /etc/authelia/users_database.yml   # trigger a reload
   > ```

   The format differs from the vault: users are keyed by name, and the hash
   field is `password`, not `password_hash`:
   ```yaml
   users:
     alice:
       disabled: false
       displayname: "Alice Rossi"
       password: "$argon2id$v=19$..."
       email: "alice@polimi.it"
       groups:
         - users
   ```
2. **Confirm the reload worked.** A YAML error or permission problem is
   rejected silently and Authelia keeps the old data:
   ```bash
   sudo journalctl _SYSTEMD_USER_UNIT=container-authelia.service -n 10
   ```
   Look for no `Error occurred during reload`. If the change still isn't
   applied, restart Authelia **and then Traefik**:
   ```bash
   cd /tmp
   scont systemctl --user restart container-authelia.service
   scont systemctl --user restart container-traefik.service
   ```
3. **Mirror the change in the vault**, except a password, which the server
   keeps anyway. Otherwise the next deploy removes a new user or reverts the
   email, name or groups.

`scripts/convert.py` turns a copy of the server file into the vault's
`authelia_users` format: `python3 scripts/convert.py users_database.yml`.

## Groups and permissions

Each user's `groups` are sent to Nextcloud and Forgejo in the OIDC `groups`
claim. Changes apply at the user's **next login**.

| Group | Effect | Setting (`group_vars/all/vars.yml`) |
|---|---|---|
| `admins` | Forgejo admin | `forgejo_oidc_admin_group` |
| any group | a Nextcloud group of the same name (quotas, group folders, sharing rules) | `nextcloud_oidc_group_provisioning` |
| any group | membership of Forgejo org teams, if mapped | `forgejo_oidc_group_team_map` |

- Group names are free-form. A user with no `groups` gets `users`.
- **Nextcloud admin is never granted by a group.** It stays with the local
  `admin` account, a break-glass login that works even if SSO is down.
- Provisioned Nextcloud groups show hashed IDs in `occ group:list` but their
  real names in the UI.
- After changing `forgejo_oidc_admin_group` or the team map, run the forgejo
  role (`./deploy.sh --limit <host> --tags forgejo`). It updates the existing
  login source; no need to recreate it.

### Forgejo teams from groups

`forgejo_oidc_group_team_map` maps an Authelia group to teams in Forgejo
organizations. Override it per host in `host_vars/<host>/vars.yml`:

```yaml
forgejo_oidc_group_team_map:
  polimi:                  # Authelia group
    polimi: [Members]      # -> org "polimi", team "Members"
  developers:
    polimi: [Developers]
```

- **The orgs and teams must already exist.** The mapping only manages
  membership. Create them in the Forgejo UI first (`/git/org/create`).
- **Membership syncs at login.** Nothing happens in the background.
- **Removal is on by default** (`forgejo_oidc_group_team_map_removal`): a user
  who leaves the group leaves the team at their next login.
- **Map changes need a forgejo deploy.** The role passes the map to
  `forgejo admin auth update-oauth --group-team-map … --group-team-map-removal`
  on every run, so `vars.yml` is the source of truth.

To see what Forgejo holds, and who is in which team (DB root password is
`vault_forgejo_db_root_password`):

```bash
cd /tmp
scont podman exec db_forgejo mariadb -uroot -p'<ROOT_PW>' forgejo \
  -e "SELECT cfg FROM login_source WHERE name='authelia';" | grep -o 'GroupTeamMap[^,]*'

scont podman exec db_forgejo mariadb -uroot -p'<ROOT_PW>' forgejo -e "
  SELECT u.name AS user, o.name AS org, t.name AS team
  FROM team_user tu
  JOIN team t ON tu.team_id = t.id
  JOIN user o ON t.org_id = o.id
  JOIN user u ON tu.uid = u.id;"
```

## Linking existing accounts

A user who already has a local Nextcloud or Forgejo account is linked to it
on first SSO login, rather than getting a duplicate, if the username and
email match their `authelia_users` entry:

- **Forgejo** asks once for the existing account's password, then shows the
  link under Settings → Security.
- **Nextcloud** matches on the `preferred_username` claim. Check with
  `occ user:list` that there's no duplicate.

## Protecting other routes

A route with no login of its own can require an Authelia login by adding the
forward-auth middleware to that container's labels:

```yaml
traefik.http.routers.<name>.middlewares: "authelia@docker"
```

## Notes

- **Changing an OIDC client secret.** The forgejo role adds the `authelia`
  login source only if it's missing, and `update-oauth` doesn't change the
  secret. Delete the source
  (`forgejo admin auth delete-oauth --id <id>`) and re-run the role.
- **Larger user bases.** The file backend is fine for a few dozen users.
  Beyond that, switching Authelia to LDAP (e.g. lldap) moves users and
  passwords out of the vault, with no change to Nextcloud or Forgejo.

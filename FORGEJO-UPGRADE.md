# Forgejo major-version upgrade runbook

Forgejo must be upgraded **one major version at a time** (9 → 10 → 11 → … ),
never in a single jump. Each hop runs DB migrations automatically on first
start; a hop is only "done" when the checklist at the bottom passes. Budget
~10 minutes per hop plus verification.

Upgrade **one host first** (e.g. quouskwe-project), let it soak for a day,
then repeat on the other. The two stacks are identical — use that.

---

## 0. Before the first hop

- Announce a maintenance window to users (each hop = a few minutes of
  downtime; a failed hop = restore from backup).
- Skim the release notes for every major you will cross:
  <https://forgejo.org/releases/> — read the **breaking changes** section.
  v11 is an LTS release and consolidates many changes; read that one closely.
  The parts of OUR setup most likely to be affected:
  - `FORGEJO__section__KEY` env-var config names (see the forgejo role env)
  - the OIDC/OAuth login source (Authelia) and its CLI flags
  - MariaDB support status
  - built-in SSH server behaviour (we run it on 2222 behind Traefik TCP)

## 1. Backup (repeat before EVERY hop)

```bash
# DB dump (root password from the vault: vault_forgejo_db_root_password)
scont podman exec db_forgejo mariadb-dump -uroot -p'<ROOT_PW>' --all-databases \
  > ~/forgejo-db-backup-$(date +%F).sql

# data volume: repos, avatars, app.ini
mkdir -p /home/containers/backups
scont podman run --rm -v forgejo-data:/data:ro -v /home/containers/backups:/backup \
  docker.io/library/alpine tar czf /backup/forgejo-data-$(date +%F).tar.gz -C /data .
```

Restore path (if a hop fails): put the previous image tag back in vars.yml,
redeploy, drop and re-create the DB from the dump, untar the data volume.

## 2. Bump ONE major in vars.yml

```yaml
# ansible/group_vars/all/vars.yml
forgejo_image: "codeberg.org/forgejo/forgejo:10"   # then :11, :12, ...
```

## 3. Deploy and watch the migration

```bash
./deploy.sh --tags forgejo --limit <host>
sudo journalctl _SYSTEMD_USER_UNIT=container-forgejo.service -f
```

Watch for migration lines completing and the web server starting. Do NOT
interrupt a running migration (units have TimeoutStartSec=3600 — let it work).

## 4. Per-hop verification checklist

- [ ] Web UI loads at `https://<domain>/git/`
- [ ] Login via Authelia (OIDC) works for a normal user
- [ ] An existing repo browses fine (file listing + a blob)
- [ ] `git clone` + `git push` over SSH (port 2222) work
- [ ] `scont podman exec --user git forgejo forgejo admin auth list`
      still lists the `authelia` source
- [ ] Group→team mapping still works (see below)

All green → next hop (back to step 1).

---

## The group→team mapping, explained

**What it does.** Authelia puts each user's groups (from `authelia_users` in
the vault) into the OIDC `groups` claim. Forgejo can translate those groups
into **org-team memberships** at login time. The translation table is
`forgejo_oidc_group_team_map` in vars (or host_vars):

```yaml
forgejo_oidc_group_team_map:
  polimi:                # Authelia group ...
    polimi: [Members]    # ... -> org "polimi", team "Members"
```

**How it gets into Forgejo.** The forgejo role passes the map (as JSON) to
`forgejo admin auth add-oauth` / `update-oauth` via two CLI flags:

- `--group-team-map '<json>'` — the translation table
- `--group-team-map-removal` — also REMOVE users from mapped teams when they
  are no longer in the Authelia group (controlled by
  `forgejo_oidc_group_team_map_removal`, on by default)

The `update-oauth` task re-applies the map on every deploy, so vars.yml is
the source of truth. The map is stored inside the login source config — check
what Forgejo currently holds with:

```bash
scont podman exec db_forgejo mariadb -uroot -p'<ROOT_PW>' forgejo \
  -e "SELECT cfg FROM login_source WHERE name='authelia';" | grep -o 'GroupTeamMap[^,]*'
```

**The rules that trip people up:**

1. **Orgs and teams must already exist** — the mapping only manages
   membership; it never creates orgs or teams. Create them in the Forgejo UI
   first.
2. **Sync happens at login** — a user added to an Authelia group gets the
   team membership on their NEXT Forgejo login (log out, log in). Nothing is
   pushed in the background.
3. **Map changes need a deploy** — editing vars.yml does nothing until
   `./deploy.sh --tags forgejo` re-runs update-oauth.

**Why it matters during upgrades.** The `add-oauth`/`update-oauth` CLI flags
occasionally get renamed between majors. If the forgejo role fails on an
unrecognized flag after a version hop:

```bash
# see what the new CLI expects
scont podman exec --user git forgejo forgejo admin auth update-oauth --help | grep -i group
```

then adjust the flag names in `ansible/roles/forgejo/tasks/main.yml`
(both the add-oauth and update-oauth tasks build their argv lists there).

**Post-hop functional test:** log in as an OIDC user who belongs to a mapped
group and confirm team membership:

```bash
scont podman exec db_forgejo mariadb -uroot -p'<ROOT_PW>' forgejo -e "
  SELECT u.name AS user, o.name AS org, t.name AS team
  FROM team_user tu
  JOIN team t ON tu.team_id = t.id
  JOIN user o ON t.org_id = o.id
  JOIN user u ON tu.uid = u.id;"
```

The logged-in user must appear in every team their groups map to.

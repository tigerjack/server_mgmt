# Host setup

One-time preparation of a server, done by hand as root over SSH before the
first deploy. It takes a host from "fresh Ubuntu, maybe with Docker" to
"rootless Podman with the `containers` user the playbook expects". Firewall
rules are not covered here.

When you're done, continue with [deploying.md](deploying.md).

## Before you start

- A public DNS **A record** for the host's domain pointing at its IP. Let's
  Encrypt needs it to issue the certificate.
- Ports **80, 443 and 2222** reachable from the internet (2222 is git over
  SSH).
- Your personal login user (e.g. `sperriello`) with sudo rights and your SSH
  key installed. Ansible connects as this user.

## 1. Make sudo work for Ansible

Ansible connects as your personal user and uses `sudo` for privileged tasks.
It runs `sudo -S -p "<marker>"`, waits for its own prompt marker on stderr,
then feeds the password on stdin.

Recent Ubuntu releases ship **`sudo-rs`** (the Rust rewrite) as `sudo`. It
ignores Ansible's `-p` marker and authenticates through polkit, so Ansible
never sees a prompt and the run fails with:

```
Timeout (32s) waiting for privilege escalation prompt
```

Check which one the host has:

```sh
sudo --version     # "sudo-rs ..." (quouskwe had this) vs "Sudo version 1.9.x" (spqr)
sudo -n true       # sudo-rs: "interactive authentication is required"
```

Raising timeouts or changing groups does not help. **Fix: replace sudo-rs with
classic sudo.** The `sudo` command is provided by the `sudo-rs` package, so a
reinstall just brings sudo-rs back. Install the classic `sudo` package instead.
It conflicts with `sudo-rs`, so apt removes sudo-rs in the same transaction.

Keep a **root shell open in a second terminal** (`sudo -i`) so a half-finished
swap can't lock you out, then:

```sh
apt update
apt install sudo              # apt says it will REMOVE sudo-rs
# if apt says sudo is already the newest version:
apt install sudo sudo-rs-     # the trailing '-' removes sudo-rs

sudo --version                # now "Sudo version 1.9.x"
apt-mark hold sudo            # stop upgrades from bringing sudo-rs back
```

Undo the hold later with `apt-mark unhold sudo`.

> **Alternative: passwordless sudo.** Simpler, but a broader privilege grant:
> ```sh
> echo 'sperriello ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/sperriello
> chmod 440 /etc/sudoers.d/sperriello
> visudo -c
> ```

## 2. Remove Docker (if present)

```sh
dpkg -l | grep -i docker      # docker.io (distro) or docker-ce (Docker's repo)
```

Podman does not import Docker's storage: everything in `/var/lib/docker` is
lost on purge. Back up any volume you care about first:

```sh
docker run --rm -v <volume>:/data -v "$(pwd)":/backup alpine \
  tar czf /backup/<volume>.tar.gz -C /data .
```

Then remove it:

```sh
systemctl disable --now docker.service docker.socket
apt purge -y docker.io docker-doc docker-compose docker-compose-v2 \
  podman-docker containerd runc \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc   # Docker's repo, if added
rm -rf /var/lib/docker /var/lib/containerd /etc/docker
groupdel docker 2>/dev/null || true
apt autoremove -y
```

## 3. Install Podman

```sh
apt update
apt install -y podman uidmap slirp4netns fuse-overlayfs dbus-user-session acl
podman --version
```

| Package | Why |
|---|---|
| `uidmap` | `newuidmap`/`newgidmap` for rootless user namespaces |
| `slirp4netns` | user-mode networking for rootless containers |
| `fuse-overlayfs` | storage fallback on kernels without unprivileged overlayfs |
| `dbus-user-session` | without it every `systemctl --user` fails with "Failed to connect to bus", and the playbook manages containers that way |
| `acl` | `setfacl`, which Ansible needs to `become_user` an unprivileged user |

Once `acl` is on every host, `allow_world_readable_tmpfiles` can be removed
from `ansible/ansible.cfg`.

## 4. Create the `containers` user

```sh
useradd --system --create-home --home-dir /home/containers --shell /usr/sbin/nologin containers
passwd -l containers          # no login; access only via sudo -u containers
```

Rootless Podman needs a subuid/subgid range, which system accounts don't
always get:

```sh
grep containers /etc/subuid /etc/subgid
# if either prints nothing:
usermod --add-subuids 100000-165535 --add-subgids 100000-165535 containers
```

## 5. Enable lingering

Without it, the `containers` user's systemd instance, and every container,
stops when your SSH session ends and doesn't start at boot:

```sh
loginctl enable-linger containers
loginctl show-user containers | grep Linger    # Linger=yes
```

## 6. Add the `scont` alias

All server-side docs use `scont` to run a command as `containers` with the
right runtime directory. Add it to your personal user's shell rc
(`~/.bashrc` or `~/.zshrc`):

```bash
alias scont='sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers)'
```

Run `scont podman …` from a directory `containers` can read, e.g. `cd /tmp`
first. Rootless Podman `chdir`s into your current directory after switching
user; from your home (mode 700) it stops with `cannot chdir to /home/<you>:`.

## 7. Check Podman as `containers`

```sh
cd /tmp
scont podman info | grep -i -e cgroupversion -e cgroupmanager   # expect: v2, systemd
scont podman info --format '{{.Store.GraphDriverName}}'         # expect: overlay, not vfs
scont podman run --rm docker.io/library/hello-world
```

Note the fully-qualified image name. Podman only falls back to Docker Hub for
bare names if `unqualified-search-registries` says so, which is why the
playbook always uses full names (`docker.io/library/...`).

## 8. Enable the Podman API socket (optional)

Traefik discovers containers through this socket. The `traefik` role enables
it anyway; doing it now just confirms it works:

```sh
scont systemctl --user enable --now podman.socket
scont systemctl --user status podman.socket    # listening on /run/user/<uid>/podman/podman.sock
```

## 9. Create the `ci` user (isolated CI only)

Only for hosts with `forgejo_runner_isolated: true` (promethence-server). The
Forgejo runner and its jobs run there as a second rootless user, so they can't
touch production ([why](ci.md#shared-and-isolated-modes)). Same steps as 4–5, but
its subuid/subgid block must not overlap **any** other user's, including the
blocks Ubuntu gives regular users. The deploy fails if it does.

```sh
useradd --system --create-home --home-dir /home/ci --shell /usr/sbin/nologin ci
passwd -l ci

cat /etc/subuid /etc/subgid      # find a free block; 300000-365535 if nothing is there
usermod --add-subuids 300000-365535 --add-subgids 300000-365535 ci

loginctl enable-linger ci
```

Add a matching alias next to `scont`, and check it works:

```bash
alias sci='sudo -u ci XDG_RUNTIME_DIR=/run/user/$(id -u ci)'
```

```sh
cd /tmp
sci podman run --rm docker.io/library/hello-world
```

The `forgejo_runner` role does the rest: it enables `ci`'s Podman socket and
auto-update timer, creates its `ci` network, and caps its systemd slice.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Failed to connect to bus` on `systemctl --user` | `dbus-user-session` missing (step 3) or lingering off (step 5) |
| `newuidmap: open of /proc/.../setgroups failed` or `insufficient UIDs or GIDs available` | subuid/subgid range missing or too small (step 4) |
| `Timeout waiting for privilege escalation prompt` during a deploy | host runs `sudo-rs` (step 1) |
| Containers gone after a reboot | lingering not enabled, or reset after a rebuild/snapshot restore (step 5) |
| `cannot chdir to /home/<you>:` | run `scont podman` from `/tmp` (step 6) |
| Deploy fails with `User ci does not exist` or `range of ci overlaps range of …` | step 9 |

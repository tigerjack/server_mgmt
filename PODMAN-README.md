# Podman setup (replacing Docker)

Run this once, as root over SSH, on each host before the ansible playbook is
run. It gets a host from "has Docker" to "has a working rootless Podman with the
`containers` user the playbook expects." It deliberately doesn't touch firewall
rules - that's handled elsewhere.

## 0. Make sudo work non-interactively for Ansible

The playbook connects as your personal user (e.g. `sperriello`) and uses
`become` (sudo) for privileged tasks. Ansible drives sudo non-interactively: it
runs `sudo -S -p "<marker>"` and watches stderr for its own prompt marker, then
feeds the password on stdin.

Recent Ubuntu releases ship **`sudo-rs`** (the Rust rewrite of sudo) as the
default `sudo`. `sudo-rs` does **not** drive the password prompt the way classic
C sudo does — it doesn't honour Ansible's `-p` marker and routes authentication
through polkit, so there's no prompt on the tty for Ansible to detect. The run
dies with:

```
Timeout (32s) waiting for privilege escalation prompt
```

and a quick check confirms it:

```sh
sudo --version          # quouskwe prints "sudo-rs ..."; spqr prints "Sudo version 1.9.x"
sudo -n true            # sudo-rs prints "sudo: interactive authentication is required" (polkit wording)
```

This is purely a host difference: the older host (spqr) runs classic sudo and
works out of the box; the newer host (quouskwe) runs sudo-rs and times out. It
has nothing to do with the `adm` group or the connection timeout — tuning those
changes nothing.

**Fix (recommended): give the deploy user passwordless sudo.** With no prompt to
detect and no interactive auth required, both classic sudo and sudo-rs work, and
the playbook runs without `--ask-become-pass`:

```sh
# as root, replacing `sperriello` with your deploy user:
echo 'sperriello ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/sperriello
chmod 440 /etc/sudoers.d/sperriello
visudo -c                       # verify syntax before logging out
sudo -n true                    # should now succeed silently
```

> **Alternative: replace sudo-rs with classic sudo.** If you want to keep
> password-prompted sudo, install the classic implementation, which Ansible can
> drive normally:
> ```sh
> apt install --reinstall sudo   # pulls classic sudo, displacing sudo-rs
> sudo --version                 # confirm it now reports "Sudo version 1.9.x"
> ```
> Passwordless sudo is simpler for an automated deploy target; switching back to
> classic sudo is the choice if your security policy requires a password.

## 1. Remove Docker

Check what's actually installed first - Docker on Ubuntu shows up either
as the distro's own `docker.io` package, or as `docker-ce` if it was
installed from Docker's own apt repo:

```sh
dpkg -l | grep -i docker
```

If you have containers/volumes you actually care about, back them up
before removing anything - Podman doesn't import Docker's storage, so
anything in `/var/lib/docker` is gone once you purge it:

```sh
# example: back up a named volume before it disappears
docker run --rm -v <volume_name>:/data -v "$(pwd)":/backup alpine \
  tar czf /backup/<volume_name>.tar.gz -C /data .
```

Then remove it:

```sh
systemctl disable --now docker.service docker.socket

# whichever of these are actually installed (apt won't complain about
# packages that aren't present):
apt purge -y docker.io docker-doc docker-compose docker-compose-v2 \
  podman-docker containerd runc \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# only if Docker's own apt repo was added:
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc

rm -rf /var/lib/docker /var/lib/containerd /etc/docker
groupdel docker 2>/dev/null || true
apt autoremove -y
```

## 2. Install Podman

```sh
apt update
apt install -y podman uidmap slirp4netns fuse-overlayfs dbus-user-session acl
```

- `uidmap` provides `newuidmap`/`newgidmap`, required for rootless user
  namespaces.
- `slirp4netns` gives rootless containers user-mode networking.
- `fuse-overlayfs` is a fallback storage driver; both your kernels
  (6.8, 7.0) are new enough to support unprivileged native overlayfs, so
  this mostly won't be needed, but it's a cheap safety net.
- `dbus-user-session` is the one people most often forget: without it,
  `systemctl --user ...` fails with "Failed to connect to bus" - which
  is exactly what the ansible playbook uses to manage each container's
  service.
- `acl` provides `setfacl`, which Ansible needs when `become_user` targets
  an unprivileged user like `containers`. Without it you get
  `chmod: invalid mode: 'A+user:containers:rx:allow'` errors.

Confirm it installed and note the version - the two hosts are on
different Ubuntu releases (matching the kernel versions you mentioned),
so don't be surprised if they land on different Podman versions:

```sh
podman --version
```

## 3. Create the rootless `containers` user

```sh
useradd --system --create-home --home-dir /home/containers --shell /usr/sbin/nologin containers
passwd -l containers   # no interactive login needed; access is only via `sudo -u containers`
```

System accounts don't always get an automatic subuid/subgid range, and
rootless Podman needs one to map container UIDs to unprivileged host
UIDs. Check, and add one if it's missing:

```sh
grep containers /etc/subuid /etc/subgid
# if either grep prints nothing:
usermod --add-subuids 100000-165535 --add-subgids 100000-165535 containers
```

## 4. Enable lingering

This is the single most important step and the one that's easiest to
forget. Without it, `containers`'s systemd user instance (and everything
running under it) stops the moment your SSH session disconnects:

```sh
loginctl enable-linger containers
loginctl show-user containers | grep Linger   # should print Linger=yes
```

## 5. Sanity-check cgroups

Both kernels here default to cgroups v2 with the systemd driver, but
confirm it. Note that this command should be executed from a path accessible to containers, so first of all go with `cd tmp`:

```sh
sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
  podman info | grep -i  -e cgroupversion -e cgroupmanager
# expect: systemd v2
```

## 6. Smoke-test rootless Podman

```sh
sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
  podman run --rm docker.io/library/hello-world
```

Notice the fully-qualified `docker.io/library/...` image name rather
than just `hello-world`. Podman doesn't always assume Docker Hub for bare
image names the way `docker pull` does - it depends on
`unqualified-search-registries` in `/etc/containers/registries.conf`.
Rather than relying on that being configured the way you expect, the
ansible playbook always uses fully-qualified image references
(`docker.io/library/nextcloud`, `codeberg.org/forgejo/forgejo`, etc.) for
exactly this reason - worth keeping that habit if you add anything else
later.

Check the storage driver while you're at it - you want `overlay`, not
the much slower `vfs` fallback:

```sh
sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
  podman info --format '{{.Store.GraphDriverName}}'
```

## 7. Enable the Podman API socket

The reverse proxy discovers containers through Podman's
Docker-compatible API socket. The ansible playbook's `traefik` role
already enables this itself (so this step is idempotent either way) -
running it manually now is just useful for confirming it works before
ansible touches anything:

```sh
sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
  systemctl --user enable --now podman.socket

sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers) \
  systemctl --user status podman.socket
```

It should be listening at `/run/user/<uid>/podman/podman.sock`, which is
the exact path the `traefik` role looks up dynamically and bind-mounts
into the proxy container.

## 8. Hand off to ansible

At this point each host has rootless Podman, a `containers` user with
lingering enabled, a working subuid/subgid range, and the API socket
reachable - everything the playbook from here on assumes already exists.
Run `ansible-playbook site.yml` next.

## Troubleshooting

- **"Failed to connect to bus"** on any `systemctl --user` command:
  either `dbus-user-session` isn't installed (step 2) or lingering isn't
  enabled (step 4) - that error means there's no user systemd/D-Bus
  instance running for `containers` at all.
- **"newuidmap: open of /proc/.../setgroups failed" or "potentially
  insufficient UIDs or GIDs available"**: the subuid/subgid range from
  step 3 is missing or too small. Re-check `grep containers /etc/subuid
  /etc/subgid`.
- **Containers don't survive a reboot**: almost always means lingering
  (step 4) didn't actually get enabled, or got reset - it's tied to the
  user account and survives package upgrades, but double-check with
  `loginctl show-user containers` if a host has been rebuilt or restored
  from a snapshot.

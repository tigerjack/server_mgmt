# CI: the Forgejo Actions runner

Forgejo queues Actions jobs but doesn't run them. The `forgejo_runner` role
runs a runner (`act_runner`) on the same host as Forgejo, which picks up each
job and runs it in a container of its own. Every host has one, named after
the host (`spqr-project`, …), and it serves every repo on that host's Forgejo.

## How a job runs

1. The runner daemon (container `forgejo-runner`, unit
   `container-forgejo-runner.service`) polls Forgejo for jobs.
2. A job with `runs-on: docker` matches the runner's `docker` label, which
   maps to the image `node:20-bookworm` (`forgejo_runner_labels`).
3. The runner starts a job container from that image as a **sibling**, through
   a rootless Podman socket, runs the steps in it, and removes it.

One job runs at a time per host; others wait in the queue. Each job container
is capped at 2 GB of memory (no swap) and 2 CPUs, and is stopped after 1 hour.
These are the `forgejo_runner_*` variables in
[Configuration](#configuration), kept low because CI shares the host with
everything else.

Where the runner runs depends on the host's mode
([Shared and isolated modes](#shared-and-isolated-modes)): spqr-project and
quouskwe-project use the shared mode, promethence-server the isolated one.

## Writing workflows

Put workflows in `.forgejo/workflows/*.yml` in the repo. If the repo has no
**Actions** tab, enable Actions in its Settings → Units.

```yaml
on: [push]
jobs:
  test:
    runs-on: docker              # the only label the runners have
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm test
```

- **Another image**: `container: image: docker.io/library/python:3.12` under
  the job replaces `node:20-bookworm`. JavaScript actions, `actions/checkout`
  among them, run with the image's `node`, so they fail in an image without
  it.
- **Actions** named without a host, like `actions/checkout@v4`, are fetched
  from `https://data.forgejo.org`, which mirrors the common ones. For any
  other, give the full URL: `uses: https://github.com/owner/action@v1`.
- **Reaching Forgejo from a job**: use `${{ github.server_url }}`, not the
  public URL. It is the address the runner registered with:
  `http://forgejo:3000` in shared mode, `https://<domain>/git` in isolated
  mode. Checkout uses it already. In shared mode, the public URL
  (`https://<domain>/…`, for Forgejo or any other service) is unreachable from
  a job: inside the container the domain resolves to `127.0.1.1`.
- **No container builds**: jobs get no Podman socket, so `docker build`,
  `docker run` and testcontainers fail. Only an isolated host can allow it
  ([below](#jobs-that-build-or-run-containers)).
- **No host paths**: workflows can't bind-mount host directories into jobs.
- **Secrets**: add them in the repo's Settings → Actions → Secrets and read
  them as `${{ secrets.NAME }}`.

## Testing the runner

**After a deploy**, `verify.yml` checks, among the rest, that the runner
logged `declared successfully` since it last started, i.e. it's connected to
Forgejo ([deploying.md](deploying.md#6-deploy-and-verify)):

```sh
PLAYBOOK=verify.yml ./deploy.sh --limit <host>
```

As a Forgejo admin, Site administration → Actions → Runners shows the same:
the runner is **Idle** or **Active** when connected, **Offline** when not.

**End to end**, push a test workflow to a throwaway branch of any repo:

```sh
git switch -c ci-smoke
mkdir -p .forgejo/workflows
cat > .forgejo/workflows/smoke.yml <<'EOF'
on: [push]
jobs:
  smoke:
    runs-on: docker
    steps:
      - run: echo "job container up on $(uname -n), node $(node --version)"
      - uses: actions/checkout@v4
      - run: git log -1 --oneline
EOF
git add .forgejo/workflows/smoke.yml
git commit -m "CI smoke test"
git push -u origin ci-smoke
```

Then open the run in the repo's Actions tab:

| What happens | What it means |
|---|---|
| No run appears | Actions is off for the repo (Settings → Units) |
| Stuck on "Waiting" | No connected runner with the label: check `runs-on: docker` and that the runner is online |
| The first step passes | The runner picked up the job and started a job container. The first run is slow: it pulls `node:20-bookworm`. |
| Checkout passes | The job container can reach Forgejo. CI works end to end. |

To watch from the server while it runs:

```bash
cd /tmp
sudo journalctl _SYSTEMD_USER_UNIT=container-forgejo-runner.service -f   # "task N repo is <owner>/<repo> ..."
scont podman ps          # another terminal: the job container, while it runs (sci on an isolated host)
```

Clean up with `git push origin --delete ci-smoke`.

## Configuration

Defaults are in `ansible/group_vars/all/vars.yml`; override any of them in a
host's `vars.yml`.

| Variable | Default | Meaning |
|---|---|---|
| `forgejo_runner_image` | `code.forgejo.org/forgejo/runner:12.0` | runner image; isolated mode needs `12.7` or newer ([upgrades.md](upgrades.md#how-images-are-pinned)) |
| `forgejo_runner_labels` | `docker:docker://node:20-bookworm` | labels and their images, comma-separated `<label>:docker://<image>` |
| `forgejo_runner_capacity` | `1` | jobs that run at once |
| `forgejo_runner_job_timeout` | `1h` | a job is stopped after this |
| `forgejo_runner_job_memory` | `2g` | memory per job container (memory = memory + swap, so no swap) |
| `forgejo_runner_job_cpus` | `2` | CPUs per job container |
| `forgejo_runner_daemon_memory` | `512m` | memory for the runner daemon itself |
| `forgejo_runner_instance_url` | `http://forgejo:3000` | shared mode: where the runner and jobs reach Forgejo |
| `forgejo_runner_isolated` | `false` | run as the `ci` user ([below](#shared-and-isolated-modes)) |
| `forgejo_runner_ci_user` | `ci` | isolated: the user |
| `forgejo_runner_ci_network` | `ci` | isolated: network of the runner and its jobs |
| `forgejo_runner_job_docker_access` | `false` | isolated: give jobs `ci`'s Podman socket ([below](#jobs-that-build-or-run-containers)) |
| `forgejo_runner_ci_memory_max` | `4G` | isolated: memory ceiling for everything `ci` runs |
| `forgejo_runner_ci_cpu_quota` | `200%` | isolated: CPU ceiling for everything `ci` runs (`100%` = one CPU) |

Isolated mode also needs `vault_forgejo_runner_secret` in the host's vault
(`openssl rand -hex 20`).

Apply changes with `./deploy.sh --limit <host> --tags forgejo_runner`. It
recreates only the runner, without waiting for running jobs: a job in
progress is lost.

### Changing the labels

**Isolated mode**: change `forgejo_runner_labels` and redeploy. The runner
declares its labels to Forgejo every time it starts.

**Shared mode**: the labels were saved at registration in `/data/.runner`
(in the `forgejo-runner-data` volume), and the role registers only when that
file is missing. So, after changing `forgejo_runner_labels`:

```bash
cd /tmp
scont systemctl --user stop container-forgejo-runner.service
scont podman run --rm -v forgejo-runner-data:/data code.forgejo.org/forgejo/runner:12.0 rm /data/.runner
```

Delete the old runner in Site administration → Actions → Runners, then
redeploy with `--tags forgejo_runner`, which registers a new one.

### Rotating the isolated runner's secret

The first 16 hex characters of `vault_forgejo_runner_secret` identify the
runner, the other 24 are its password. Change only the last 24 and redeploy:
the role updates the runner in Forgejo and in its config. Changing the first
16 registers a second runner; delete the old one in Forgejo.

## Shared and isolated modes

| | Shared (default) | Isolated |
|---|---|---|
| Hosts | spqr-project, quouskwe-project | promethence-server |
| Runs as | `containers`, beside production | `ci`: its own rootless Podman, subuid range and socket |
| Podman socket | the production one (Traefik's) | `ci`'s, which controls only CI containers |
| Network | `edge`; reaches Forgejo at `http://forgejo:3000` | `ci`, on slirp4netns; reaches Forgejo at `https://<domain>/git/` ([why](#reaching-forgejo-from-an-isolated-runner)) |
| Registration | token generated on the first deploy; state in `/data/.runner` in the `forgejo-runner-data` volume | Forgejo 15 offline registration with `vault_forgejo_runner_secret`, re-applied on every deploy; UUID and token in `/etc/forgejo-runner/config.yaml` (0600) |
| Total resource ceiling | only the per-job caps | `forgejo_runner_ci_memory_max` / `forgejo_runner_ci_cpu_quota` on `ci`'s systemd slice |
| Shell alias on the server | `scont` | `sci` ([host-setup.md](host-setup.md#9-create-the-ci-user-isolated-ci-only)) |

**Why isolated.** In shared mode the runner holds the socket that controls
every production container, and a job that escapes its container lands as
`containers`, which owns all the data. Under `ci`, both land in a user that
owns nothing but CI. That only holds if `ci`'s subuid/subgid ranges are its
own, so the role fails if they overlap any other user's.

### Jobs that build or run containers

For `docker build` or testcontainers, set
`forgejo_runner_job_docker_access: true` (isolated mode only). Jobs then get
`ci`'s socket at `/var/run/docker.sock` (`docker_host: automount`). The cost:
such a job can control every CI container, including the runner, read its
token, and mount any host path `ci` can read. The containers it starts aren't
bound by the per-job caps, only by the slice ceiling. Acceptable when you
trust everyone who can push a workflow. Note that any Authelia user can
create a repo and push one.

### Moving a host to isolated mode

1. Create the `ci` user ([host-setup.md](host-setup.md#9-create-the-ci-user-isolated-ci-only)).
2. Add `vault_forgejo_runner_secret` to the host's vault (`openssl rand -hex 20`).
3. In its `vars.yml`, set `forgejo_runner_isolated: true` and a runner image
   of at least `12.7` (`server.connections` needs it).
4. `./deploy.sh --limit <host> --tags forgejo_runner`.
5. Remove the old runner:
   `cd /tmp && scont systemctl --user disable --now container-forgejo-runner.service`,
   then delete it in Forgejo under Site administration → Actions → Runners.

## Implementation notes

### Access to the Podman socket

The runner image runs as uid 1000. In a rootless container that uid maps to a
subuid, not to the runner user, so it can't open the user's Podman socket
(mode 0660): the daemon logs `permission denied` on `podman.sock` and the unit
crash-loops. The role runs the daemon as container root (`user: "0:0"`),
which on the host *is* the runner user: no more access than the socket
already grants.

### Reaching Forgejo from an isolated runner

An isolated runner is on the same machine as Forgejo but not on the same
network: each rootless user has its own network namespaces, and `edge` exists
only in `containers`'. So the runner and its jobs reach Forgejo the way a
browser does, through Traefik's port 443 on the host. Two things stand in the
way:

- **The name.** As for [same-host OIDC](services.md#same-host-oidc), the
  domain would resolve to `127.0.1.1`. The runner (`etc_hosts`) and every job
  (`--add-host` in `config.yaml`) map it to the host's real IP.
- **The route to that IP.** pasta, Podman 5's default rootless network,
  copies the host's IP into the container's namespace, so a connection to it
  never leaves the namespace and fails. Inside `containers`' namespace it
  still works, because Traefik's port forwarding lives there; `ci`'s has
  none. slirp4netns routes the connection out to the host, so the role sets
  it as `ci`'s `default_rootless_network_cmd`. Tested on spqr-project, from
  containers pointed at the host's IP: `edge` and slirp4netns got through,
  pasta didn't.

The role probes `<host IP>:443` from the `ci` network on every deploy and
fails if it's unreachable. Podman 6 removes slirp4netns, so on a Podman 6
host this probe fails and the role needs a pasta-based route instead.

Shared mode needs none of this: the runner and its jobs are on `edge` and use
`http://forgejo:3000`. They don't get the `127.0.1.1` fix, which is why the
public URL doesn't work from a shared-mode job.

## Troubleshooting

Runner logs and common failures (`permission denied` on the socket, an
isolated runner that can't reach Forgejo) are in
[runbook.md](runbook.md#actions-runner).

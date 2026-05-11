# Agent Sandbox — Development Notes

A rootless Docker container running `claude --dangerously-skip-permissions` against the user's project, wired into the host's `minikube`. You edit files from the host; the agent runs inside the container. End-user docs are in `README.md`.

## Files

- `Dockerfile` — image recipe; parameterized by `UID`/`GID`/`USERNAME` build args
- `run.sh` — host-side launcher; rebuilds image on label drift, mounts `~/.claude`, wires minikube net
- `Makefile` — image management (`build`/`rebuild`/`clean`/`inspect`/`size`/`shell`)

## Design invariants

1. **Container user mirrors host user** — name *and* UID/GID. `run.sh` always passes the host's actual username via `--build-arg USERNAME`. This matters because claude config (plugin marketplaces, MCP server paths, etc.) stores **absolute host paths**; the only way to resolve them inside the container is for `$HOME` to match. The same logic applies to the project bind-mount: the workspace is mounted at its host path rather than a synthetic `/workspace`, so any path the agent prints back to the user is copy-pasteable on the host. `run.sh` refuses to launch if the workspace path equals/contains `$HOME` or sits inside `~/.claude` — those would collide with the home-dir mounts.

2. **`~/.claude` mount split:**
   - Base directory RW — session state, todos, memory, projects, `claude.json`, credentials.
   - `settings.json` RO overlay — contains host hooks, which are executable code the host claude runs. An agent inside the sandbox must not be able to modify them.
   - `plugins/` RO overlay — plugin manifests can declare hooks that the host claude runs, same threat as `settings.json`. Trade-off: marketplace refresh inside the sandbox fails with `EROFS`; refresh from the host instead. Was briefly RW for exactly this reason — closing the hook-injection channel was judged more important than in-sandbox refresh.

3. **kubeconfig rewrite:** `clusters[].cluster.server → https://minikube:8443`. The container joins the `minikube` docker network where the API server is reachable as the hostname `minikube` on 8443. Cert paths under `~/.minikube/...` resolve naturally because `$HOME` matches host — *no sed-based path remap is needed* (was needed earlier when container user was `dev`).

4. **Image is per-host-user.** `run.sh` reads labels `sandbox.uid`/`sandbox.gid`/`sandbox.username` and rebuilds on drift, or when `REBUILD=1`. Single tag (`:latest`), per-machine image.

## Build details that bit us

- **`docker build --network=host` is required.** On this host the docker0 bridge crawled at ~55 KB/s to GitHub releases; with host networking it's ~5 MB/s. Both `run.sh` and the `Makefile` set this.
- **`curl --retry 3 --retry-delay 5 --connect-timeout 30`** — avoid `--max-time`. The latter caps each attempt regardless of progress, so a slow-but-functional download will time out on every retry. `--connect-timeout` only bounds the connection handshake.
- **Tool versions are pinned via `ARG`** at the top of the Dockerfile. Bump in one place. Verify asset names exist before bumping — GitHub release naming conventions shift (capitalization, arch suffix) without notice.

## Adding host paths to the container

For local plugin marketplaces or other host directories that claude config references by absolute path:

```bash
EXTRA_MOUNTS="/path/one /path/two" ./run.sh
```

Each path is bind-mounted RW at the same path inside the container.

## Force rebuild

```bash
REBUILD=1 ./run.sh   # ignore label check; uses Docker layer cache
make rebuild         # ignore Docker layer cache too (--no-cache)
```

## Threat model boundary

The agent has YOLO permissions on:
- the container filesystem,
- the bind-mounted host project (mounted at its host path),
- host `~/.claude` (except `settings.json` and `~/.claude.json` is RW — claude needs to write to it),
- the host `minikube` cluster (via the joined docker network).

It cannot reach:
- host files outside the explicit mounts,
- the host Docker socket (intentionally unmounted — no container escape),
- hosts beyond the `minikube` docker bridge.

Loosening any of these — adding the docker socket, mounting `$HOME`, opening additional networks — is a deliberate weakening of the boundary. Be explicit about why.

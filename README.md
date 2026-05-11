# Agent Sandbox

A rootless container that runs `claude --dangerously-skip-permissions` against your project, with `kubectl`/`helm`/`stackablectl`/Rust/Node pre-installed, wired into your host `minikube`. You edit files from the host with whatever editor you already use; the agent runs YOLO inside the container, where its blast radius is limited to the explicit bind mounts.

## Prerequisites

- Linux host with Docker running.
- Optional but expected: `minikube` with `--driver=docker`.

## First run

```bash
cd <some-project>
/path/to/agent-sandbox/run.sh
```

On first invocation, `run.sh` builds the image (~3-5 min — kubectl/helm/stackablectl/minikube/Node/Rust toolchain). Subsequent runs reuse the cached image and drop you straight into `claude`.

## What's mounted

The container `$HOME` mirrors the host `$HOME` (same username, same UID/GID), so every mount lands at the same absolute path inside the container as it has on the host. This is deliberate — claude config stores absolute host paths (plugin marketplaces, MCP server paths) and they need to resolve unchanged.

| Host path | Mode | Why |
| --- | --- | --- |
| `<workspace>` | rw | your code — edit it from the host, the agent sees the same bytes |
| `~/.claude` | rw | session state, memory, auth |
| `~/.claude/settings.json` | **ro** overlay | host hook config — agent must not modify (note: `settings.local.json` and project-level `.claude/settings.json` are still RW; see threat model) |
| `~/.claude/plugins` | **ro** overlay | plugin manifests can declare hooks; same threat as `settings.json`. Marketplace refresh fails inside the sandbox — refresh from the host. |
| `~/.claude.json` | rw | claude writes to this at runtime |
| `~/.minikube` | ro | cluster certs and CA (mounted only if a cluster is running) |
| `$TMP_KUBECONFIG` | ro | rewritten kubeconfig pointing at `https://minikube:8443` (cert paths are unchanged — they resolve naturally because `$HOME` matches) |

Everything else (rustup toolchains, npm caches, anything the agent installs) lives inside the container and evaporates on exit.

## Cluster networking

`run.sh` joins the container to the `minikube` docker network so `kubectl`/`helm` reach the API server at `https://minikube:8443`. The host kubeconfig is rewritten on the fly: only `clusters[].cluster.server` is changed to `https://minikube:8443`. Cert paths under `~/.minikube/...` are left alone because container `$HOME` matches host `$HOME` and `~/.minikube` is bind-mounted at the same path.

## Common operations

| What | How |
| --- | --- |
| Run from any project | `~/path/to/agent-sandbox/run.sh` |
| Force a rebuild | `REBUILD=1 ~/path/to/agent-sandbox/run.sh` |
| Override target workspace | `~/path/to/agent-sandbox/run.sh /some/other/dir` |

## Threat model

The agent inside the container runs as a non-root user (no sudo available) but otherwise has full permissions over the container filesystem and the network. It can:
- read and write everything in the bind-mounted workspace (your project files);
- read and write everything in `~/.claude` *except* `settings.json` and `plugins/` — this includes session transcripts under `projects/`, memory under `projects/<dir>/memory/`, `settings.local.json`, and `~/.claude.json`;
- run arbitrary `kubectl` against your host `minikube`;
- pull packages, install crates, hit the internet without restriction.

It **cannot**:
- modify host `~/.claude/settings.json` or anything under `~/.claude/plugins/` (RO overlays) — but it *can* modify `~/.claude/settings.local.json` and any project-level `.claude/settings.json` inside the workspace, both of which can declare hooks that the **host** claude executes;
- modify any host file outside `~/.claude` and the workspace;
- access the host Docker socket (so it cannot escape the container or kill its siblings);
- escalate to root inside the container (sudo is not installed);
- target hosts beyond the `minikube` docker network without DNS/route help.

The threat model assumes the agent is *non-malicious but error-prone*. If you need to defend against an actively adversarial agent (jailbreak, prompt-injection), note that several persistence channels into the host claude remain open: writable session history under `~/.claude/projects/`, `settings.local.json`, and workspace-level hook config. Closing them means giving up `claude resume` continuity.

## Known gotchas

- **kubeconfig staleness** — if you `minikube delete && minikube start` while a sandbox is running, the cert paths inside the container go stale. Exit and re-run `run.sh`.
- **Driver lock-in** — `--driver=docker` is required for the network join to work. `kvm2` or `virtualbox` won't be on the `minikube` docker network.
- **No in-container image builds** — there's no `buildah` / rootless-docker setup in the image. If you want a `build → minikube image load` flow, do the build on the host and load from there.
- **Marketplace refresh fails in-sandbox** — `~/.claude/plugins` is RO. Run `/plugin marketplace update` (or equivalent) from the host claude instead.
- **Open network egress** — the agent can `cargo install` whatever it wants. If exfiltration is in your threat model, this tool isn't it.
- **macOS untested** — minikube docker-driver networking + `~/.minikube` paths get messy across the macOS VM boundary. Linux only for now.
- **Session history shared** — the in-container `claude` uses your host `~/.claude/projects/` for session storage; in-sandbox conversations show up in `claude resume` on the host. By design — that's how memory persists across runs.

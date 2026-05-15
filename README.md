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

| Host path / source | Mode | Why |
| --- | --- | --- |
| `<workspace>` | rw | your code — edit it from the host, the agent sees the same bytes |
| Docker volume `agent-sandbox-home-$USER` → `$HOME` | rw | persistent `$HOME` — tool caches (cargo, npm), per-cwd bash history, anything the agent installs in `$HOME`. Auto-seeded from the image on first use; the nested mounts below shadow their paths inside this volume. |
| `~/.claude` | rw | session state, memory, auth |
| `~/.claude/settings.json` | **ro** overlay | host hook config — agent must not modify (note: `settings.local.json` and project-level `.claude/settings.json` are still RW; see threat model) |
| `~/.claude/plugins` | **ro** overlay | plugin manifests can declare hooks; same threat as `settings.json`. Marketplace refresh fails inside the sandbox — refresh from the host. |
| `~/.claude.json` | rw | claude writes to this at runtime |
| `~/.minikube` | ro | cluster certs and CA (mounted only if a cluster is running) |
| `$TMP_KUBECONFIG` | ro | rewritten kubeconfig pointing at `https://<profile>:8443` (cert paths are unchanged — they resolve naturally because `$HOME` matches) |

Anything written under `$HOME` (e.g. rustup toolchains, npm caches, fnm versions you install yourself) persists across sessions via the named volume. Anything outside `$HOME` (e.g. `/tmp`, packages installed at `/usr/local`) evaporates on exit.

Bash history is **per workspace**: `$HISTFILE` is set in `/etc/bash.bashrc` to `~/.bash_history.d/<sha1-of-workspace-path>` (the workspace path comes from `AGENT_SANDBOX_WORKSPACE`, set by `run.sh`). Parallel sessions in *different* cwds don't share history; parallel sessions in the *same* cwd append safely (`shopt -s histappend`). The volume also holds an `~/.bash_history.d/INDEX` mapping hashes back to workspace paths if you ever poke around.

## Cluster networking

`run.sh` joins the container to the minikube docker network so `kubectl`/`helm` reach the API server at `https://<profile>:8443`. The host kubeconfig is rewritten on the fly: only `clusters[].cluster.server` is changed to point at the in-network hostname. Cert paths under `~/.minikube/...` are left alone because container `$HOME` matches host `$HOME` and `~/.minikube` is bind-mounted at the same path.

The profile name is resolved in order: `MINIKUBE_PROFILE` env var > kubeconfig's `current-context` > literal `minikube`. For a default `minikube start`, you don't need to set anything. For a custom profile (`minikube start -p foo`), `current-context` will normally already be `foo` and auto-detection picks it up; set `MINIKUBE_PROFILE=foo` explicitly if your kubectl context is pointing somewhere else.

## Common operations

| What | How |
| --- | --- |
| Run from any project | `~/path/to/agent-sandbox/run.sh` |
| Force a rebuild | `REBUILD=1 ~/path/to/agent-sandbox/run.sh` |
| Override target workspace | `~/path/to/agent-sandbox/run.sh /some/other/dir` |
| Drop into a shell instead of claude | `~/path/to/agent-sandbox/run.sh --shell` (useful for running other agentic CLIs in the same sandboxed environment) |
| Reset persistent `$HOME` | `make clean-home` — wipes cargo/npm caches, fnm/Node versions installed in-sandbox, bash history. Image and image-baked tools (rust toolchain etc.) re-seed on next run. |
| Reach a service on the host (e.g. ollama) | `HOST_GATEWAY=1 ~/path/to/agent-sandbox/run.sh` — adds `host.docker.internal` pointing at the host. The service must be listening on a non-loopback interface (for ollama: `OLLAMA_HOST=0.0.0.0:11434`). |

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

- **Image rebuilds don't refresh `$HOME`.** The persistent home volume keeps its contents across rebuilds, so a Dockerfile bump to rust/node leaves the old versions in `~/.cargo` / `~/.rustup`. Mirrors host reality (an OS upgrade doesn't auto-rewrite `~/.cargo`). Run `make clean-home` to wipe the volume and re-seed from the new image on next launch.
- **Cross-session state in `$HOME`.** Two sandboxes running at once share the same `$HOME` volume. Tool caches (cargo, npm, fnm) are safe — they use lockfiles. Bash history is **not** shared between parallel sessions in different workspaces (it's keyed per workspace path), but `.bashrc`/`.profile` edits and anything else in `$HOME` are immediately visible to the other live session. If you don't want this, exit the other session first.
- **kubeconfig staleness** — if you `minikube delete && minikube start` while a sandbox is running, the cert paths inside the container go stale. Exit and re-run `run.sh`.
- **Driver lock-in** — `--driver=docker` is required for the network join to work. `kvm2` or `virtualbox` won't be on the `minikube` docker network.
- **No in-container image builds** — there's no `buildah` / rootless-docker setup in the image. If you want a `build → minikube image load` flow, do the build on the host and load from there.
- **Marketplace refresh fails in-sandbox** — `~/.claude/plugins` is RO. Run `/plugin marketplace update` (or equivalent) from the host claude instead.
- **Open network egress** — the agent can `cargo install` whatever it wants. If exfiltration is in your threat model, this tool isn't it.
- **macOS untested** — minikube docker-driver networking + `~/.minikube` paths get messy across the macOS VM boundary. Linux only for now.
- **Session history shared** — the in-container `claude` uses your host `~/.claude/projects/` for session storage; in-sandbox conversations show up in `claude resume` on the host. By design — that's how memory persists across runs.

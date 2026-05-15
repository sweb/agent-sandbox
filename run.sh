#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="stackable-agent-sandbox"
TAG="latest"

SHELL_MODE=0
WORKSPACE_ARG=""
for arg in "$@"; do
    case "$arg" in
        --shell) SHELL_MODE=1 ;;
        -*) echo "error: unknown flag '$arg'" >&2; exit 1 ;;
        *)
            if [ -n "$WORKSPACE_ARG" ]; then
                echo "error: unexpected extra argument '$arg'" >&2
                exit 1
            fi
            WORKSPACE_ARG="$arg"
            ;;
    esac
done
WORKSPACE="$(cd "${WORKSPACE_ARG:-$PWD}" && pwd)"

HOST_UID=$(id -u)
HOST_GID=$(id -g)
HOST_USER=$(id -un)
# Inside the container, $HOME is /home/$HOST_USER so absolute host paths baked
# into claude config (plugin marketplaces etc.) resolve naturally.
CONTAINER_HOME="/home/$HOST_USER"

# --- Preflight: Docker daemon ---
if ! docker info >/dev/null 2>&1; then
    echo "error: Docker doesn't appear to be running. Start the daemon and retry." >&2
    exit 1
fi

# --- Image: build if missing or if UID/GID/USERNAME labels don't match host (or REBUILD=1) ---
BUILT_UID=$(docker image inspect "$IMAGE:$TAG" --format '{{index .Config.Labels "sandbox.uid"}}' 2>/dev/null || true)
BUILT_GID=$(docker image inspect "$IMAGE:$TAG" --format '{{index .Config.Labels "sandbox.gid"}}' 2>/dev/null || true)
BUILT_USER=$(docker image inspect "$IMAGE:$TAG" --format '{{index .Config.Labels "sandbox.username"}}' 2>/dev/null || true)

if [ "${REBUILD:-}" = "1" ] \
    || [ "$BUILT_UID" != "$HOST_UID" ] \
    || [ "$BUILT_GID" != "$HOST_GID" ] \
    || [ "$BUILT_USER" != "$HOST_USER" ]; then
    echo "Building $IMAGE:$TAG for $HOST_USER ($HOST_UID:$HOST_GID)..."
    # --network=host avoids the docker0 bridge for downloads (much faster on
    # hosts where bridged NAT is slow to GitHub releases / npm / debian repos).
    docker build \
        --network=host \
        --build-arg "UID=$HOST_UID" \
        --build-arg "GID=$HOST_GID" \
        --build-arg "USERNAME=$HOST_USER" \
        --label "sandbox.uid=$HOST_UID" \
        --label "sandbox.gid=$HOST_GID" \
        --label "sandbox.username=$HOST_USER" \
        -t "$IMAGE:$TAG" \
        "$SCRIPT_DIR"
fi

# --- Build docker run args incrementally ---
DOCKER_ARGS=(
    --rm -it
    --user "$HOST_UID:$HOST_GID"
    --env "TERM=${TERM:-xterm-256color}"
)
[ -n "${COLORTERM:-}" ] && DOCKER_ARGS+=(--env "COLORTERM=$COLORTERM")

# Persistent $HOME via a named volume. Docker auto-seeds the volume from the
# image's /home/$USER on first use, so build-time installs (.cargo, .rustup)
# populate transparently. The nested ~/.claude / ~/.minikube / ~/.claude.json
# bind mounts below still shadow their paths inside this volume.
# AGENT_SANDBOX_WORKSPACE drives per-cwd $HISTFILE inside the container (see
# /etc/bash.bashrc snippet baked into the image).
HOME_VOLUME="agent-sandbox-home-$HOST_USER"
# Persistent /nix via its own named volume. Same auto-seed trick: image-layer
# /nix (populated by the build-time single-user nix install) seeds the volume
# on first attach. Closures pulled by nix-shell survive across sessions —
# without this, every new container would re-fetch GBs from cache.nixos.org.
NIX_VOLUME="agent-sandbox-nix-$HOST_USER"
DOCKER_ARGS+=(
    -v "$HOME_VOLUME:$CONTAINER_HOME"
    -v "$NIX_VOLUME:/nix"
    --env "AGENT_SANDBOX_WORKSPACE=$WORKSPACE"
)

# Expose the host to the container as `host.docker.internal`. Opt-in because
# it's only useful when something is listening on the host (e.g. ollama bound
# to 0.0.0.0) and we don't want to imply that connectivity by default.
if [ -n "${HOST_GATEWAY:-}" ]; then
    DOCKER_ARGS+=(--add-host "host.docker.internal:host-gateway")
fi

# --- Minikube wiring (non-fatal if absent) ---
TMP_KUBECONFIG=""
cleanup() {
    [ -n "$TMP_KUBECONFIG" ] && [ -f "$TMP_KUBECONFIG" ] && rm -f "$TMP_KUBECONFIG"
}
trap cleanup EXIT

if docker network inspect minikube >/dev/null 2>&1; then
    DOCKER_ARGS+=(--network=minikube)

    if [ -f "$HOME/.kube/config" ]; then
        TMP_KUBECONFIG=$(mktemp -t kubeconfig.XXXXXX)
        yq '(.clusters[].cluster.server) = "https://minikube:8443"' \
            "$HOME/.kube/config" > "$TMP_KUBECONFIG"
        # Cert paths under $HOME/.minikube are already at the right path inside
        # the container since CONTAINER_HOME mirrors $HOME — no rewrite needed.
        DOCKER_ARGS+=(-v "$TMP_KUBECONFIG:$CONTAINER_HOME/.kube/config:ro")
    fi

    if [ -d "$HOME/.minikube" ]; then
        DOCKER_ARGS+=(-v "$HOME/.minikube:$CONTAINER_HOME/.minikube:ro")
    fi
else
    echo "note: docker network 'minikube' not found — skipping cluster wiring."
    echo "      Run 'minikube start --driver=docker' first if you want kubectl access."
fi

# --- ~/.claude: RW base mount with RO overlays for hook/plugin code. ---
# settings.json and plugins/ are both vectors for code that the *host* claude
# would execute (hooks, plugin manifests with hook declarations), so the
# sandbox must not be able to write to them. Trade-off: in-sandbox marketplace
# refresh will fail with EROFS — refresh from the host instead.
if [ -d "$HOME/.claude" ]; then
    DOCKER_ARGS+=(-v "$HOME/.claude:$CONTAINER_HOME/.claude")
    if [ -f "$HOME/.claude/settings.json" ]; then
        DOCKER_ARGS+=(-v "$HOME/.claude/settings.json:$CONTAINER_HOME/.claude/settings.json:ro")
    fi
    if [ -d "$HOME/.claude/plugins" ]; then
        DOCKER_ARGS+=(-v "$HOME/.claude/plugins:$CONTAINER_HOME/.claude/plugins:ro")
    fi
fi

# claude-code looks for ~/.claude.json at the home root.
if [ -e "$HOME/.claude.json" ]; then
    DOCKER_ARGS+=(-v "$HOME/.claude.json:$CONTAINER_HOME/.claude.json")
fi

# --- Extra host dirs (e.g. local plugin marketplaces outside ~/.claude). ---
# Space-separated absolute paths; bind-mounted at the same path inside the container.
if [ -n "${EXTRA_MOUNTS:-}" ]; then
    for path in $EXTRA_MOUNTS; do
        if [ -e "$path" ]; then
            DOCKER_ARGS+=(-v "$path:$path")
        else
            echo "warning: EXTRA_MOUNTS path not found, skipping: $path" >&2
        fi
    done
fi

# --- Workspace ---
# Mount at the same path inside the container so file refs and shell commands
# the agent prints are copy-pasteable on the host. Guard against workspace
# paths that would collide with the home / ~/.claude mounts: anything that
# contains $HOME shadows the .claude RW mount, and anything inside ~/.claude
# double-mounts the same path region.
collision=""
case "$HOME/" in "$WORKSPACE/"*) collision="equals or contains \$HOME";; esac
case "$WORKSPACE/" in "$HOME/.claude/"*) collision="overlaps ~/.claude";; esac
if [ -n "$collision" ]; then
    echo "error: workspace '$WORKSPACE' $collision — refusing to mount." >&2
    exit 1
fi

DOCKER_ARGS+=(
    -v "$WORKSPACE:$WORKSPACE"
    -w "$WORKSPACE"
)

if [ "$SHELL_MODE" = "1" ]; then
    exec docker run "${DOCKER_ARGS[@]}" "$IMAGE:$TAG" bash
else
    exec docker run "${DOCKER_ARGS[@]}" \
        "$IMAGE:$TAG" \
        claude --dangerously-skip-permissions
fi

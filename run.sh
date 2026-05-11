#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="stackable-agent-sandbox"
TAG="latest"

WORKSPACE_ARG="${1:-$PWD}"
WORKSPACE="$(cd "$WORKSPACE_ARG" && pwd)"

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

exec docker run "${DOCKER_ARGS[@]}" \
    "$IMAGE:$TAG" \
    claude --dangerously-skip-permissions

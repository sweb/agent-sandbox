# syntax=docker/dockerfile:1.6
FROM debian:12-slim

ARG UID=1000
ARG GID=1000
# Username matches host so absolute host paths baked into claude config
# (e.g. plugin marketplace directories) resolve inside the container.
ARG USERNAME=dev

# Tool versions — override with --build-arg if needed
ARG KUBECTL_VERSION=1.31.0
ARG HELM_VERSION=3.16.2
ARG STACKABLECTL_VERSION=1.4.0
ARG YQ_VERSION=4.44.3
ARG UV_VERSION=0.11.13
ARG NODE_MAJOR=24
ARG NIX_VERSION=2.24.10
ARG GH_VERSION=2.92.0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Bound apt's per-connection wait so a stalled mirror fails fast instead of
# hanging the build. Applies to all subsequent apt-get invocations.
RUN printf 'Acquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
        > /etc/apt/apt.conf.d/99timeouts

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl jq ca-certificates xz-utils unzip tar gzip \
        ripgrep fd-find \
        build-essential pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Debian renames this binary — symlink to upstream name
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# mikefarah yq (the Go one — the apt package is the python yq with different syntax)
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 30 \
        "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH}" \
        -o /usr/local/bin/yq \
 && chmod +x /usr/local/bin/yq

# kubectl
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 30 \
        "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
        -o /usr/local/bin/kubectl \
 && chmod +x /usr/local/bin/kubectl

# helm
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 30 \
        "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz" \
        -o /tmp/helm.tgz \
 && tar -xzf /tmp/helm.tgz -C /tmp \
 && mv /tmp/linux-${ARCH}/helm /usr/local/bin/helm \
 && chmod +x /usr/local/bin/helm \
 && rm -rf /tmp/helm.tgz /tmp/linux-${ARCH}

# stackablectl
RUN ARCH=$(dpkg --print-architecture) \
 && case "$ARCH" in \
        amd64) STK_ARCH=x86_64-unknown-linux-gnu ;; \
        arm64) STK_ARCH=aarch64-unknown-linux-gnu ;; \
        *) echo "unsupported arch $ARCH"; exit 1 ;; \
    esac \
 && curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 30 \
        "https://github.com/stackabletech/stackable-cockpit/releases/download/stackablectl-${STACKABLECTL_VERSION}/stackablectl-${STK_ARCH}" \
        -o /usr/local/bin/stackablectl \
 && chmod +x /usr/local/bin/stackablectl

# uv (Astral Python package/project manager; also installs Python interpreters on demand)
RUN ARCH=$(dpkg --print-architecture) \
 && case "$ARCH" in \
        amd64) UV_ARCH=x86_64-unknown-linux-gnu ;; \
        arm64) UV_ARCH=aarch64-unknown-linux-gnu ;; \
        *) echo "unsupported arch $ARCH"; exit 1 ;; \
    esac \
 && curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 30 \
        "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_ARCH}.tar.gz" \
        -o /tmp/uv.tgz \
 && tar -xzf /tmp/uv.tgz -C /tmp \
 && mv /tmp/uv-${UV_ARCH}/uv /tmp/uv-${UV_ARCH}/uvx /usr/local/bin/ \
 && chmod +x /usr/local/bin/uv /usr/local/bin/uvx \
 && rm -rf /tmp/uv.tgz /tmp/uv-${UV_ARCH}

# gh (GitHub CLI)
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 30 \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
        -o /tmp/gh.tgz \
 && tar -xzf /tmp/gh.tgz -C /tmp \
 && mv /tmp/gh_${GH_VERSION}_linux_${ARCH}/bin/gh /usr/local/bin/gh \
 && chmod +x /usr/local/bin/gh \
 && rm -rf /tmp/gh.tgz /tmp/gh_${GH_VERSION}_linux_${ARCH}

# Node + claude-code (system-wide)
RUN curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 30 \
        "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g @anthropic-ai/claude-code \
 && rm -rf /var/lib/apt/lists/*

# Per-cwd bash history: $HOME is a persistent named volume shared across all
# sessions for this user, so without this every workspace would clobber the
# others' history. AGENT_SANDBOX_WORKSPACE is set by run.sh.
# Lives in /etc (image layer) not ~/.bashrc (volume) so rebuilds always pick
# up changes here without needing `docker volume rm`.
RUN cat >> /etc/bash.bashrc <<'EOF'

if [ -n "${AGENT_SANDBOX_WORKSPACE:-}" ]; then
    _hist_hash=$(printf '%s' "$AGENT_SANDBOX_WORKSPACE" | sha1sum | cut -c1-12)
    mkdir -p "$HOME/.bash_history.d"
    export HISTFILE="$HOME/.bash_history.d/$_hist_hash"
    _index="$HOME/.bash_history.d/INDEX"
    if ! grep -qxF "$_hist_hash $AGENT_SANDBOX_WORKSPACE" "$_index" 2>/dev/null; then
        printf '%s %s\n' "$_hist_hash" "$AGENT_SANDBOX_WORKSPACE" >> "$_index"
    fi
    unset _hist_hash _index
fi
shopt -s histappend

# Source the nix profile so nix is on PATH for interactive shells. The profile
# script lives in $HOME (volume), but the symlink and script are created by the
# image-time installer and survive into the seeded-on-first-use home volume.
if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
EOF

# Pre-create /nix owned by the agent user so the single-user nix installer
# (run later, as that user, without sudo) can populate it. System-wide nix.conf
# goes in next to it. sandbox=false because rootless docker can't provide the
# user namespaces nix's build sandbox needs — small reproducibility loss in
# exchange for working nix-shell inside the container. flakes/nix-command on
# because newer Stackable repos use them.
RUN mkdir -m 0755 /nix \
 && chown ${UID}:${GID} /nix \
 && mkdir -p /etc/nix
RUN cat > /etc/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
sandbox = false
EOF

# User creation (parameterized — run.sh rebuilds with matching UID/GID/USERNAME if labels don't match).
# No sudo: the agent has no legitimate need for root inside the container, and
# without docker userns-remap, in-container root maps to host UID 0.
RUN groupadd -g ${GID} ${USERNAME} \
 && useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME}

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Rust toolchain (per-user; cargo/rustc/clippy/rustfmt for operator dev — drop rust-analyzer
# since there's no in-container editor needing an LSP server)
ENV PATH=/home/${USERNAME}/.local/bin:/home/${USERNAME}/.cargo/bin:/usr/local/bin:/usr/bin:/bin \
    RUSTUP_HOME=/home/${USERNAME}/.rustup \
    CARGO_HOME=/home/${USERNAME}/.cargo
RUN curl --proto '=https' --tlsv1.2 -sSf --retry 3 --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 30 \
        https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --default-toolchain stable --profile minimal \
        --component clippy --component rustfmt \
 && rm /tmp/rustup-init.sh

# nix (single-user, no daemon). /nix and /etc/nix/nix.conf were prepared above;
# the installer reuses both. --no-modify-profile keeps the installer out of
# ~/.bashrc — we source nix.sh from /etc/bash.bashrc (image layer) instead, so
# PATH is set up regardless of whether the persistent $HOME volume has been
# seeded yet.
RUN curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 30 \
        "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" \
        -o /tmp/nix-install.sh \
 && sh /tmp/nix-install.sh --no-daemon --no-modify-profile \
 && rm /tmp/nix-install.sh

ENV KUBECONFIG=/home/${USERNAME}/.kube/config \
    SHELL=/bin/bash

# CMD intentionally unset — run.sh always passes an explicit command.

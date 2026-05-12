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

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl jq ca-certificates xz-utils unzip tar gzip \
        ripgrep fd-find \
        build-essential pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Debian renames this binary — symlink to upstream name
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# mikefarah yq (the Go one — the apt package is the python yq with different syntax)
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
        "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH}" \
        -o /usr/local/bin/yq \
 && chmod +x /usr/local/bin/yq

# kubectl
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
        "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
        -o /usr/local/bin/kubectl \
 && chmod +x /usr/local/bin/kubectl

# helm
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
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
 && curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
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
 && curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
        "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_ARCH}.tar.gz" \
        -o /tmp/uv.tgz \
 && tar -xzf /tmp/uv.tgz -C /tmp \
 && mv /tmp/uv-${UV_ARCH}/uv /tmp/uv-${UV_ARCH}/uvx /usr/local/bin/ \
 && chmod +x /usr/local/bin/uv /usr/local/bin/uvx \
 && rm -rf /tmp/uv.tgz /tmp/uv-${UV_ARCH}

# Node + claude-code (system-wide)
RUN curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
        "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g @anthropic-ai/claude-code \
 && rm -rf /var/lib/apt/lists/*

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
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal \
            --component clippy --component rustfmt

ENV KUBECONFIG=/home/${USERNAME}/.kube/config \
    SHELL=/bin/bash

# CMD intentionally unset — run.sh always passes an explicit command.

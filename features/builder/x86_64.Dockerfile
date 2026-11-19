# Builder image for portable/build-tools.sh (x86_64 host).
# Same toolchains as the zsh-builder devcontainer feature, without needing
# the devcontainer CLI: portable/builder.sh image builds it.
FROM ubuntu:24.04
COPY features/src/zsh-builder /tmp/zsh-builder
RUN bash /tmp/zsh-builder/install.sh && rm -rf /tmp/zsh-builder
ENV CARGO_HOME="/usr/local/cargo"
ENV RUSTUP_HOME="/usr/local/rustup"
ENV PATH="/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/zig:${PATH}"
# Docker CLI only (static): cross: and STATIC_ALPINE recipes start their own
# containers through the host's socket when built with compose.yaml.
ARG DOCKER_CLI_VERSION=29.1.3
ARG DOCKER_CLI_SHA256=c019c608ba2bb009dd673f3230e4d743f36a78d36166c6c2444c05d0aa9ff0d9
RUN curl -fsSL -o /tmp/docker.tgz "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" \
    && echo "${DOCKER_CLI_SHA256}  /tmp/docker.tgz" | sha256sum -c - \
    && tar -xzf /tmp/docker.tgz -C /usr/local/bin --strip-components=1 docker/docker \
    && rm /tmp/docker.tgz

# Builder image for scripts/portable/build-tools.sh (x86_64 host).
# Same toolchains as the zsh-builder devcontainer feature, without needing
# the devcontainer CLI: scripts/portable/builder.sh image builds it.
FROM ubuntu:24.04
COPY features/src/zsh-builder /tmp/zsh-builder
RUN bash /tmp/zsh-builder/install.sh && rm -rf /tmp/zsh-builder
ENV CARGO_HOME="/usr/local/cargo"
ENV RUSTUP_HOME="/usr/local/rustup"
ENV PATH="/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/zig:${PATH}"

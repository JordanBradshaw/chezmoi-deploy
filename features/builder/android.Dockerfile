# Builder image for the moto-termux profile: the x86_64 builder plus the
# Android NDK (LTS) and Rust's aarch64-linux-android target. build-tools.sh's
# ndk cargo driver and Android Go builds use $ANDROID_NDK_HOME.
# portable/builder.sh image builds it after zsh-builder:local.
ARG BASE=zsh-builder:local
FROM ${BASE}
ARG NDK_VERSION=r30
ARG NDK_SHA1=5107f898313790e449e87eee2183d9a20602dee9
RUN apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /tmp/ndk.zip "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip" \
    && echo "${NDK_SHA1}  /tmp/ndk.zip" | sha1sum -c - \
    && unzip -q /tmp/ndk.zip -d /opt \
    && mv "/opt/android-ndk-${NDK_VERSION}" /opt/android-ndk \
    && rm /tmp/ndk.zip
RUN rustup target add aarch64-linux-android && chmod -R a+rX /usr/local/rustup
ENV ANDROID_NDK_HOME="/opt/android-ndk"

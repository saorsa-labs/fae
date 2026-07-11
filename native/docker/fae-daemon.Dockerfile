# syntax=docker/dockerfile:1
# Build-only Linux daemon proof. This image is never published.
FROM rust:1.96.0-bookworm@sha256:c993d32d95cc146bd12c84d66f0b924a6a96f3988325f39c144f2f9893dea120 AS rust-toolchain

FROM ubuntu:24.04@sha256:52df9b1ee71626e0088f7d400d5c6b5f7bb916f8f0c82b474289a4ece6cf3faf

ENV DEBIAN_FRONTEND=noninteractive \
    CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH=/usr/local/cargo/bin:${PATH}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        git \
        libasound2-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

COPY --from=rust-toolchain /usr/local/cargo /usr/local/cargo
COPY --from=rust-toolchain /usr/local/rustup /usr/local/rustup

WORKDIR /workspace
COPY vendor/ vendor/
COPY crates/ crates/

WORKDIR /workspace/crates
RUN rustc --version | grep -F 'rustc 1.96.0 '
RUN cargo build --locked --release -p fae-daemon --all-features

# These rlibs exist only when fae-daemon's default-on `parakeet` feature
# compiled both the sherpa wrapper and its native sys crate. This closes the
# old no-feature Zig gap.
RUN test -n "$(find target/release/deps -name 'libsherpa_onnx-*.rlib' -print -quit)" \
    && test -n "$(find target/release/deps -name 'libsherpa_onnx_sys-*.rlib' -print -quit)"

# Preserve the Parakeet packaging bar: sherpa/ONNX remain static, libstdc++ is
# the only C++ runtime, and every other dynamic dependency is an expected ALSA
# or glibc runtime library. Any new dependency fails this build proof.
RUN set -eu; \
    bin=target/release/fae-daemon; \
    test -x "$bin"; \
    ldd "$bin" | tee /tmp/fae-daemon.ldd; \
    ! grep -F 'not found' /tmp/fae-daemon.ldd; \
    grep -F 'libstdc++.so.6' /tmp/fae-daemon.ldd; \
    ! grep -Ei 'lib(onnxruntime|sherpa|kaldi|openfst)' /tmp/fae-daemon.ldd; \
    awk '{ print $1 }' /tmp/fae-daemon.ldd \
        | sed 's#^.*/##' \
        | sort -u \
        | grep -Ev '^(linux-vdso\.so\.1|ld-linux-x86-64\.so\.2|libasound\.so\.2|libc\.so\.6|libdl\.so\.2|libgcc_s\.so\.1|libm\.so\.6|libpthread\.so\.0|librt\.so\.1|libstdc\+\+\.so\.6)$' \
        > /tmp/fae-daemon-unexpected-libs.txt \
        || true; \
    test ! -s /tmp/fae-daemon-unexpected-libs.txt \
        || { echo 'ERROR: unexpected fae-daemon runtime dependencies:' >&2; cat /tmp/fae-daemon-unexpected-libs.txt >&2; exit 1; }

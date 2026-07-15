#!/bin/sh
set -eu

# Allowed SONAMEs for fae-daemon's runtime deps. The shared-library SONAMEs
# (libc.so.6, libstdc++.so.6, ...) are identical across amd64/arm64; only the
# ELF dynamic linker name differs, so both are allow-listed here. A binary
# linking anything outside this set (e.g. a surprise libbogus.so) is rejected.

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <ldd-output>" >&2
    exit 2
fi

ldd_output=$1
unexpected=$(
    awk '{ print $1 }' "$ldd_output" \
        | sed 's#^.*/##' \
        | sort -u \
        | grep -Ev '^(linux-vdso\.so\.1|ld-linux-x86-64\.so\.2|ld-linux-aarch64\.so\.1|libasound\.so\.2|libc\.so\.6|libdl\.so\.2|libgcc_s\.so\.1|libm\.so\.6|libpthread\.so\.0|librt\.so\.1|libstdc\+\+\.so\.6)$' \
        || true
)

if [ -n "$unexpected" ]; then
    echo "ERROR: unexpected fae-daemon runtime dependencies:" >&2
    printf '%s\n' "$unexpected" >&2
    exit 1
fi

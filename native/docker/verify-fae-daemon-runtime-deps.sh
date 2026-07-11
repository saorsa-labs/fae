#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <ldd-output>" >&2
    exit 2
fi

ldd_output=$1
unexpected=$(
    awk '{ print $1 }' "$ldd_output" \
        | sed 's#^.*/##' \
        | sort -u \
        | grep -Ev '^(linux-vdso\.so\.1|ld-linux-x86-64\.so\.2|libasound\.so\.2|libc\.so\.6|libdl\.so\.2|libgcc_s\.so\.1|libm\.so\.6|libpthread\.so\.0|librt\.so\.1|libstdc\+\+\.so\.6)$' \
        || true
)

if [ -n "$unexpected" ]; then
    echo "ERROR: unexpected fae-daemon runtime dependencies:" >&2
    printf '%s\n' "$unexpected" >&2
    exit 1
fi

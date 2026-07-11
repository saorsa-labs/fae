#!/bin/sh
set -eu

checker=${1:-"$(dirname "$0")/verify-fae-daemon-runtime-deps.sh"}
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

printf '%s\n' \
    'linux-vdso.so.1 (0x00007fff)' \
    'libstdc++.so.6 => /lib/x86_64-linux-gnu/libstdc++.so.6 (0x00007fff)' \
    'libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007fff)' \
    '/lib64/ld-linux-x86-64.so.2 (0x00007fff)' \
    > "$tmpdir/allowed.ldd"
"$checker" "$tmpdir/allowed.ldd"

cp "$tmpdir/allowed.ldd" "$tmpdir/unexpected.ldd"
printf '%s\n' \
    'libbogus.so.1 => /opt/surprise/libbogus.so.1 (0x00007fff)' \
    >> "$tmpdir/unexpected.ldd"

if "$checker" "$tmpdir/unexpected.ldd" 2> "$tmpdir/rejection.txt"; then
    echo 'ERROR: checker accepted an unexpected runtime dependency' >&2
    exit 1
fi

grep -F 'libbogus.so.1' "$tmpdir/rejection.txt" > /dev/null

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0

echo "[guard-no-rust] checking active CI workflows for rust/cargo reintroduction..."
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -e "$wf" ] || continue
  if grep -nEi '\b(cargo|rustup|actions-rs|dtolnay/rust-toolchain|Swatinem/rust-cache)\b' "$wf"; then
    echo "[guard-no-rust] ERROR: forbidden rust/cargo references found in active workflow: $wf" >&2
    fail=1
  fi
done

echo "[guard-no-rust] checking justfile default dev recipes (build/test/check)..."
for recipe in build test check; do
  block="$(awk -v r="$recipe" '
    $0 ~ "^" r "(:|[[:space:]])" {inblk=1; print; next}
    inblk && $0 ~ /^[^[:space:]#].*:/ {exit}
    inblk {print}
  ' justfile)"

  if [ -z "$(printf '%s\n' "$block" | tr -d '[:space:]')" ]; then
    echo "[guard-no-rust] ERROR: required justfile recipe '$recipe' is missing" >&2
    fail=1
    continue
  fi

  if [ "$(printf '%s\n' "$block" | wc -l | tr -d '[:space:]')" -lt 2 ]; then
    echo "[guard-no-rust] ERROR: required justfile recipe '$recipe' is empty" >&2
    printf '%s\n' "$block" >&2
    fail=1
    continue
  fi

  if ! printf '%s\n' "$block" | tail -n +2 | grep -Eq '[^[:space:]#]'; then
    echo "[guard-no-rust] ERROR: required justfile recipe '$recipe' has no executable body" >&2
    printf '%s\n' "$block" >&2
    fail=1
    continue
  fi

  if printf '%s\n' "$block" | grep -Eiq '\b(cargo|rustup|clippy|rustfmt)\b'; then
    echo "[guard-no-rust] ERROR: recipe '$recipe' contains forbidden rust/cargo tooling" >&2
    printf '%s\n' "$block" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "[guard-no-rust] FAILED" >&2
  exit 1
fi

echo "[guard-no-rust] OK"

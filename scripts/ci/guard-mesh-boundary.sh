#!/usr/bin/env bash
# guard-mesh-boundary.sh — machine-enforce the conductor ↔ x0x boundary (M4-C).
#
# WHY THIS EXISTS (M4, 2026-06-27):
# M4 introduces `ConductorMeshDelegationPort` so the conductor can delegate to
# same-owner peers (OwnerFleet lane). The port + its DTOs are pure conductor
# types — x0x/x0x-compute types must NEVER cross the boundary. The DTO
# translation happens in a FUTURE adapter (M4-E, REST to a localhost
# x0x-computed daemon), behind the port. Until then M4 is dormant: no x0x crate
# is a dependency.
#
# This guard makes that invariant STRUCTURAL, matching the fae-metaopt boundary
# discipline (guard-metaopt-boundary.sh). It runs in ci-linux.yml alongside
# fmt/clippy/tests and is locally runnable via `just guard-mesh-boundary`.
#
# THE BOUNDARY (scoped to deps/imports, NOT comment tokens):
#
# Conductor prose comments mention "x0x" as architecture context (e.g. recipe.rs
# "OwnerFleet is x0x same-owner"). Those are intentionally ALLOWED. What is
# FORBIDDEN is an actual x0x DEPENDENCY or IMPORT:
#   1. Cargo:        `x0x` / `x0x-compute` / `x0x_compute` in any fae Cargo.toml.
#   2. Rust imports: `use x0x` / `x0x::` / `x0x_compute::` / `x0x-compute::`
#                     in crates/fae-daemon/src/conductor/**.
#
# Check 1 (Cargo) is repo-wide; check 2 (imports) is conductor-scoped because
# the adapter (when it exists) may legitimately live elsewhere under a feature
# flag — but the conductor CORE must stay x0x-free so the gate pipeline
# (mode/membrane/budget/approval) and telemetry can never be bypassed by an
# x0x type taking a shortcut.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0

# ── Check 1: no x0x/x0x-compute Cargo dependency anywhere in fae ──────────────
echo "[guard-mesh-boundary] checking fae Cargo.toml files for x0x deps..."
cargo_violations=0
# Match x0x as a crate dep line, not a path/comment. Cargo dep lines look like
# `x0x = "..."` / `x0x-compute = ...` / `x0x_compute = ...`. Avoid matching the
# many prose mentions of "x0x" in doc-comments inside Cargo.toml. Scan BOTH the
# workspace root (crates/Cargo.toml) and every member (crates/*/Cargo.toml) so
# a dep snuck in at the workspace level is caught.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "[guard-mesh-boundary]   VIOLATION (Cargo): $line"
  cargo_violations=$((cargo_violations + 1))
done < <(grep -rEn '^[[:space:]]*x0x(-compute|_compute)?[[:space:]]*=' crates/Cargo.toml crates/*/Cargo.toml || true)

if [ "$cargo_violations" -gt 0 ]; then
  echo "[guard-mesh-boundary] $cargo_violations forbidden x0x Cargo dependency/dependencies."
  echo "[guard-mesh-boundary] M4 is dormant: real transport (M4-E) is blocked on x0x-compute's"
  echo "[guard-mesh-boundary] real backend. The future REST adapter must NOT be a crate dep."
  fail=1
else
  echo "[guard-mesh-boundary] Cargo: clean (no x0x/x0x-compute deps)."
fi

# ── Check 2: no x0x/x0x-compute IMPORTS in the conductor core ────────────────
echo "[guard-mesh-boundary] checking conductor core for x0x imports..."
import_violations=0
# `use x0x` (any form) and path-qualified `x0x::` / `x0x_compute::` / `x0x-compute::`.
# Existing prose comments saying "x0x" (no `::` or `use`) are intentionally NOT matched.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "[guard-mesh-boundary]   VIOLATION (import): $line"
  import_violations=$((import_violations + 1))
done < <(grep -rEn '(use[[:space:]]+x0x|[^a-zA-Z0-9_]x0x(-compute|_compute)?::)' \
  crates/fae-daemon/src/conductor --include='*.rs' || true)

if [ "$import_violations" -gt 0 ]; then
  echo "[guard-mesh-boundary] $import_violations forbidden x0x import(s) in conductor core."
  echo "[guard-mesh-boundary] x0x types must stay behind ConductorMeshDelegationPort."
  echo "[guard-mesh-boundary] Prose comments mentioning x0x as architecture context are ALLOWED;"
  echo "[guard-mesh-boundary] `use x0x::...` / `x0x::Type` imports are NOT."
  fail=1
else
  echo "[guard-mesh-boundary] conductor imports: clean (no x0x types; prose mentions allowed)."
fi

if [ "$fail" -ne 0 ]; then
  echo "[guard-mesh-boundary] FAILED — boundary breached."
  exit 1
fi

echo "[guard-mesh-boundary] PASSED — boundary intact."

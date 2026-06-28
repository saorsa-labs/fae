#!/usr/bin/env bash
# guard-mesh-boundary.sh — machine-enforce the conductor ↔ external-mesh boundary
# (M4-C; extended M6-A for the x0x-symphony family).
#
# WHY THIS EXISTS (M4, 2026-06-27; extended M6, 2026-06-27):
# M4 introduced `ConductorMeshDelegationPort` so the conductor can delegate to
# same-owner peers (OwnerFleet lane). The port + its DTOs are pure conductor
# types — x0x/x0x-compute types must NEVER cross the boundary. The DTO
# translation happens in a FUTURE adapter (M4-E, REST to a localhost
# x0x-computed daemon), behind the port. Until then M4 is dormant: no x0x crate
# is a dependency.
#
# M6 EXTENDS the boundary to the x0x-symphony family. The Phase-2 async draft
# proposed a `fae-conductor-orchestrator` crate depending on x0x +
# x0x-symphony; that PREDATES and CONFLICTS with this boundary pattern.
# Treating x0x-symphony-core as "safe because types-only" is too loose: its
# types carry prompts, sessions, workspaces, handoffs, and it is unstable
# (v0.0.0, no tags). M6-Intel needs NONE of it. M6-Async (a future slice) will
# speak pure conductor types behind its own port, exactly like M4.
#
# This guard makes the boundary STRUCTURAL, matching the fae-metaopt boundary
# discipline (guard-metaopt-boundary.sh). It runs in ci-linux.yml alongside
# fmt/clippy/tests and is locally runnable via `just guard-mesh-boundary`.
#
# THE BOUNDARY (scoped to deps/imports, NOT comment tokens):
#
# Conductor prose comments mention "x0x" as architecture context (e.g. recipe.rs
# "OwnerFleet is x0x same-owner"). Those are intentionally ALLOWED. What is
# FORBIDDEN is an actual external-mesh DEPENDENCY or IMPORT across the whole
# x0x family (x0x, x0x-compute, x0x-symphony, x0x-symphony-core, and their
# underscore forms):
#   1. Cargo:        any `x0x`/`x0x-compute`/`x0x-symphony`/`x0x-symphony-core`
#                    (or underscore forms) dep line in any fae Cargo.toml.
#   2. Rust imports: `use x0x...` / `x0x::...` / `x0x_symphony::...` /
#                    `x0x-symphony-core::...` in crates/fae-daemon/src/conductor/**.
#
# Check 1 (Cargo) is repo-wide; check 2 (imports) is conductor-scoped because
# an adapter (when it exists) may legitimately live elsewhere under a feature
# flag — but the conductor CORE must stay external-mesh-free so the gate
# pipeline (mode/membrane/budget/approval) and telemetry can never be bypassed
# by an external type taking a shortcut.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0

# ── Check 1: no external-mesh Cargo dependency anywhere in fae ───────────────
# The x0x family: x0x, x0x-compute/_compute, x0x-symphony/_symphony,
# x0x-symphony-core/_symphony_core. The alternation `(-compute|_compute|...
# -symphony-core|_symphony_core)` is ordered longest-first so the regex engine
# can't short-match `x0x-symphony` and miss `-core`. The bare `x0x` arm is
# guarded by requiring an optional suffix that, if present, must be one of the
# known forms — so a hypothetical `x0x-foo` would also be caught.
echo "[guard-mesh-boundary] checking fae Cargo.toml files for x0x-family deps..."
cargo_violations=0
# Match an x0x-family crate as a Cargo dep in TWO forms (review 08dab3c4, MAJOR:
# a key-only regex missed renamed deps). Scan BOTH the workspace root
# (crates/Cargo.toml) and every member (crates/*/Cargo.toml) so a dep snuck in
# at the workspace level is caught.
#   Pattern 1 (key):   `x0x... =`           — a direct dep key.
#   Pattern 2 (value): `x0x..."`           — the crate name inside double quotes,
#                        which is how `package = "..."`, `path = "..."`, and
#                        `git = "..."` name a crate. Closes the renamed/aliased
#                        dep bypass: `mesh_symphony = { package = "x0x-..." }`.
# The closing `"` anchor keeps this from false-positive on prose comments
# (e.g. `// x0x-symphony is deferred` has no `"` right after the crate name).
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "[guard-mesh-boundary]   VIOLATION (Cargo): $line"
  cargo_violations=$((cargo_violations + 1))
done < <(grep -rEn -e '^[[:space:]]*x0x(-compute|_compute|-symphony|_symphony|-symphony-core|_symphony_core)?[[:space:]]*=' -e 'x0x(-compute|_compute|-symphony|_symphony|-symphony-core|_symphony_core)?"' crates/Cargo.toml crates/*/Cargo.toml || true)

if [ "$cargo_violations" -gt 0 ]; then
  echo "[guard-mesh-boundary] $cargo_violations forbidden x0x-family Cargo dependency/dependencies (direct key OR renamed package/path/git)."
  echo "[guard-mesh-boundary] M4/M6 are dormant: real transport (M4-E) is blocked on x0x-compute's"
  echo "[guard-mesh-boundary] real backend; M6-Async will speak pure conductor types behind its own port."
  echo "[guard-mesh-boundary] A future REST adapter must NOT be a crate dep in the conductor core."
  fail=1
else
  echo "[guard-mesh-boundary] Cargo: clean (no x0x-family deps, direct or renamed)."
fi

# ── Check 2: no external-mesh IMPORTS in the conductor core ──────────────────
echo "[guard-mesh-boundary] checking conductor core for x0x-family imports..."
import_violations=0
# `use x0x...` (any form) and path-qualified `x0x::` / `x0x_compute::` /
# `x0x_symphony::` / `x0x-symphony-core::`. Existing prose comments saying
# "x0x" (no `::` or `use`) are intentionally NOT matched.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "[guard-mesh-boundary]   VIOLATION (import): $line"
  import_violations=$((import_violations + 1))
done < <(grep -rEn '(use[[:space:]]+x0x|[^a-zA-Z0-9_]x0x(-compute|_compute|-symphony|_symphony|-symphony-core|_symphony_core)?::)' \
  crates/fae-daemon/src/conductor --include='*.rs' || true)

if [ "$import_violations" -gt 0 ]; then
  echo "[guard-mesh-boundary] $import_violations forbidden x0x-family import(s) in conductor core."
  echo "[guard-mesh-boundary] External-mesh types must stay behind their conductor ports"
  echo "[guard-mesh-boundary] (ConductorMeshDelegationPort for x0x; M6-Async port for symphony)."
  echo "[guard-mesh-boundary] Prose comments mentioning x0x as architecture context are ALLOWED;"
  echo "[guard-mesh-boundary] `use x0x::...` / `x0x::Type` imports are NOT."
  fail=1
else
  echo "[guard-mesh-boundary] conductor imports: clean (no x0x-family types; prose mentions allowed)."
fi

if [ "$fail" -ne 0 ]; then
  echo "[guard-mesh-boundary] FAILED — boundary breached."
  exit 1
fi

echo "[guard-mesh-boundary] PASSED — boundary intact."

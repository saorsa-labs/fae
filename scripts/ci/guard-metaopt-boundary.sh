#!/usr/bin/env bash
# guard-metaopt-boundary.sh — machine-enforce the fae-metaopt ↔ fae-daemon boundary.
#
# WHY THIS EXISTS (M3, 2026-06-26):
# Through M3-A/B/C1, "fae-metaopt is unwired from the daemon" held by MANUAL
# discipline — a grep someone remembers to run. That was acceptable while the
# invariant was "zero refs" (trivially checkable; the safe state was "don't wire
# it at all"). M3-C2 wires fae-metaopt into the daemon for the first time, which
# (a) makes the boundary reachable, and (b) replaces the simple "zero refs"
# invariant with a complex "refs only here, never there" rule. A complex manual
# check is exactly the kind of gate that rots silently — so the moment the
# invariant gets MORE consequential, it is promoted from convention to CI.
#
# This runs in ci-linux.yml alongside fmt/clippy/tests. It is also runnable
# locally via `just guard-metaopt-boundary`.
#
# THE BOUNDARY (two checks):
#
# 1. fae-daemon → fae_metaopt (ALLOWLIST — mutation must stay offline/CLI-only).
#    fae-daemon source may reference fae_metaopt ONLY from the allowlisted files
#    below (the recipe validator + the CLI command). The live turn loop
#    (executor.rs, session.rs, scheduler) is FORBIDDEN — this is what makes the
#    spec's "dormant / offline / CLI-only / human-approves-every-promotion"
#    posture STRUCTURAL rather than aspirational. The content-aware classifier
#    is a hard prerequisite for any LIVE mutation loop (owner directive
#    2026-06-25); until it lands, mutation must not be reachable from a live turn.
#
# 2. fae-metaopt → fae_daemon (ZERO REFS — hard).
#    fae-metaopt is a pure leaf primitive (the Rust port of the MetaOpt optimizer).
#    It must NEVER depend on the daemon — no imports, ever. This pins the spec's
#    "No fae-metaopt → fae-daemon dependency" architectural rule.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0

# ── Check 1: fae-daemon → fae_metaopt (allowlist) ─────────────────────────────
#
# Add a file here ONLY when it is part of the offline/CLI-only mutation path.
# Every addition must justify why it is NOT part of the live turn loop.

ALLOWED_FAEDAEMON_REFS=(
  "crates/fae-daemon/src/conductor/recipe_mutation.rs"
  # M3-C4 (CLI command) will add the metaopt-run subcommand's source file here,
  # e.g.: "crates/fae-daemon/src/cli/metaopt.rs"
)

is_allowed() {
  local target="$1"
  for allowed in "${ALLOWED_FAEDAEMON_REFS[@]}"; do
    if [ "$target" = "$allowed" ]; then return 0; fi
  done
  return 1
}

echo "[guard-metaopt-boundary] checking fae-daemon → fae_metaopt allowlist..."

daemon_violations=0
# `|| true` so a no-match grep doesn't trip `set -e`.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  file="${line%%:*}"
  if ! is_allowed "$file"; then
    echo "[guard-metaopt-boundary]   VIOLATION (fae-daemon): $line"
    daemon_violations=$((daemon_violations + 1))
  fi
done < <(grep -rn 'fae_metaopt' crates/fae-daemon/src --include='*.rs' || true)

if [ "$daemon_violations" -gt 0 ]; then
  echo "[guard-metaopt-boundary] $daemon_violations forbidden fae_metaopt reference(s) in fae-daemon."
  echo "[guard-metaopt-boundary] fae-metaopt is reachable ONLY from the offline/CLI mutation path:"
  for a in "${ALLOWED_FAEDAEMON_REFS[@]}"; do echo "[guard-metaopt-boundary]   allowed: $a"; done
  echo "[guard-metaopt-boundary] executor.rs / session.rs / scheduler / the live turn loop are FORBIDDEN."
  echo "[guard-metaopt-boundary] To wire a new caller: add it to ALLOWED_FAEDAEMON_REFS in this script"
  echo "[guard-metaopt-boundary] AND confirm it is not reachable from a live turn (classifier gate)."
  fail=1
else
  echo "[guard-metaopt-boundary] fae-daemon → fae_metaopt: clean (refs confined to allowlist)."
fi

# ── Check 2: fae-metaopt → fae_daemon (zero refs, hard) ───────────────────────

echo "[guard-metaopt-boundary] checking fae-metaopt → fae_daemon (must be zero)..."

reverse_violations=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "[guard-metaopt-boundary]   VIOLATION (fae-metaopt→daemon): $line"
  reverse_violations=$((reverse_violations + 1))
done < <(grep -rn 'fae_daemon' crates/fae-metaopt/src --include='*.rs' || true)

if [ "$reverse_violations" -gt 0 ]; then
  echo "[guard-metaopt-boundary] $reverse_violations forbidden fae_daemon reference(s) in fae-metaopt."
  echo "[guard-metaopt-boundary] fae-metaopt is a pure leaf primitive — it must NEVER import fae_daemon."
  echo "[guard-metaopt-boundary] This breaks the spec's 'No fae-metaopt → fae-daemon dependency' rule."
  fail=1
else
  echo "[guard-metaopt-boundary] fae-metaopt → fae_daemon: clean (zero refs)."
fi

if [ "$fail" -ne 0 ]; then
  echo "[guard-metaopt-boundary] FAILED — boundary violations above must be fixed before merge."
  exit 1
fi

echo "[guard-metaopt-boundary] PASSED — boundary intact."

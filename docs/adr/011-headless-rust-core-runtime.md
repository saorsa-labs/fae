# ADR-011: Headless Rust Core as Canonical Runtime

**Status:** Accepted
**Date:** 2026-06-22
**Owner:** David Irvine

## Decision

Fae's canonical runtime architecture is a **headless Rust core (daemon)**. The Swift
macOS app is a **migration / legacy / thin-client surface**, not the authoritative
runtime. New intelligence surfaces — conductor, routing, memory, scheduler, tools,
MetaOpt, the LLM/engine, and x0x integration — are built **in the Rust core**. The
Rust orb UI shell (`native/rust/fae-ui-shell`, ADR-009) remains the canonical UI.

Concretely:

- The headless Rust daemon is the brain. It owns the agent loop, pipeline, tools,
  memory, scheduler, MetaOpt, and (future) the conductor.
- The Swift app is being superseded as the runtime; it remains as a migration /
  thin-client surface until fully retired.
- No C ABI / `libfae` is required: the daemon/control-plane protocol
  (WebSocket + Unix socket, ADR-002 v2 protocol, loopback auth via
  `fae-control-plane`) is the integration boundary between the Rust core and any
  client (Swift, Rust orb shell, future Dioxus/Tauri, remote).
- **x0x may be integrated directly in the Rust core** as a crate dependency — no
  Swift↔x0xd REST/WS boundary is required for same-process orchestration.
- The active Rust workspace lives under `crates/`:
  `fae-daemon`, `fae-engine`, `fae-control-plane`, `fae-acp`, `fae-envelope-gate`,
  `fae-audio`. The migration is mid-flight (Phase 1 authorized; see
  `docs/architecture/headless-core-impl-plan-2026-06-01.md`).

## Context

Several prior documents asserted "pure Swift / no embedded Rust core in production":

- `AGENTS.md` "Current architecture (authoritative)" section.
- `docs/CURRENT_STATE.md` tech stack (2026-06-13).
- ADR-002 "Embedded Rust Core" — Status: Superseded "by pure Swift architecture".
- The ADR README note "ADR-002 is the only fully superseded decision".

These are **stale relative to the owner decision (2026-06-22)** and the active
`crates/` workspace. The Swift app remains the *currently-shipping* runtime, but
the daemon is already embedded in release builds (model-lock gate) and the
headless-core implementation plan is executing. This ADR makes the strategic
direction authoritative so that new work targets the Rust core and does not
proliferate Swift surfaces that will be migrated or deleted.

The `conductor-tier1-own-fleet-2026-06-05.md` design (Layer: headless Rust core)
is **reaffirmed** by this decision — it was written for the Rust core and is now
the authoritative conductor target, not a conflict.

## Consequences

- **New feature code targets Rust** (`crates/...`), not Swift
  (`native/macos/Fae/Sources/Fae/...`). Swift is touched only for migration,
  bridging, or legacy-maintenance.
- **The conductor** (D1–D7 learned-routing work) is built in the Rust core. Its
  types, telemetry, routing policy, and (once ported) MetaOpt surface live in
  `crates/fae-daemon/src/conductor/` or a new `crates/fae-conductor` crate.
- **MetaOpt is currently Swift** (`native/macos/Fae/Sources/Fae/Scheduler/`).
  Until it is ported (or bridged) to Rust, Rust-side conductor learning that
  depends on it is blocked. The port/adaptation is an explicit milestone
  dependency (see the learned-conductor execution plan).
- **x0x integration** uses the Rust crate directly in the daemon — no daemon
  REST/WS indirection required for same-process work. (The daemon's own
  control-plane API still serves external/remote clients.)
- **Validation commands** shift toward the Rust workspace:
  `cargo fmt --all`, `cargo clippy --all-features --all-targets -- -D warnings`,
  `cargo test --workspace`. Swift validation (`swift build`, `swift test`) remains
  for legacy/migration surfaces only.
- The `scripts/ci/guard-no-rust-reintro.sh` guard is **itself now stale** and must
  be retired or inverted — it guards *against* Rust reintroduction, which is the
  opposite of this decision.

## What this ADR does NOT decide

- It does not set a hard Swift-deprecation date (the migration is incremental).
- It does not mandate a single conductor crate vs a `fae-daemon/src/conductor/`
  module — that is an implementation choice per milestone.
- It does not authorize autonomous conductor learning by itself — that remains
  governed by ADR-008 (and requires its amendment for the `conductorRecipe`
  surface) and ADR-005 (protected-kernel boundaries).

## Supersedes / amends

- **Amends** ADR-002: its "Superseded by pure Swift" status is itself superseded.
  Rust-core is canonical; the *integration mode* (daemon/control-plane protocol,
  not in-process C ABI) is what this ADR fixes.
- **Invalidates** the Swift-only guardrail language in `AGENTS.md` and
  `CURRENT_STATE.md` (reconciled in the same change as this ADR).
- **Reaffirms** `conductor-tier1-own-fleet-2026-06-05.md` (Rust core).

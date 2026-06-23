# Conductor M2 — D2 + D7 Team Kickoff

> Status: **Team mega-prompt** · 2026-06-23 · Owner: David Irvine
> Plan: [`fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md`](fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md)
> M2 decisions: [`../research/fae-learned-conductor-m2-decisions-2026-06-22.md`](../research/fae-learned-conductor-m2-decisions-2026-06-22.md)
> Architecture: headless Rust core canonical ([ADR-011](../adr/011-headless-rust-core-runtime.md)).

## Mission

Build the two M2 work-packages that the conductor's cloud-routing path depends on, in
the **Rust core** (ADR-011), behind clean interfaces the M2 executor wiring will consume.
You are **not** wiring cloud egress into the executor — that is the M2 integration step,
gated on both of these WPs *and* the reviewed M2 spec. You are building the two primitives
that integration step needs.

## Where we are (do not re-litigate)

- **M0 + M1 done and hardened.** `direct` topology is byte-identical to the legacy path
  (proven by `conductor_routed_direct_is_byte_identical_to_legacy`). Telemetry lands in an
  isolated JSONL store; the F-4 fingerprint is an HMAC of the opaque `request_id` — **no
  user text is ever hashed or stored.**
- **PII egress membrane done** (`crates/fae-pii-membrane`, commit `aef83660`). This is the
  canonical egress authority — the hard floor under all cloud routing. It is **not** the
  budget/approval layer; that is what you build.
- **M2 impl is blocked on exactly these two WPs.** The membrane was the one M2 piece
  independent of you; it is finished. You are the rest of the independent surface.

## Locked owner decisions (build to these — do not re-open)

1. **D-M2-1 — ACP lane:** add a new **`PrivacyLane::CloudBacked`** variant, between
   `LocalOnly` and `OwnerFleet` (**Tier B, second-most-trusted**, per the ratified trust
   gradient in `../research/fae-learned-conductor-m2-decisions-2026-06-22.md`). Cloud-backed
   ACP workers (Codex/Claude/Gemini/Copilot) map to `CloudBacked`, **not** `LocalOnly`. Fix
   the known-incorrect `locality_to_lane(LocalAcp) → LocalOnly` placeholder (`recipe.rs:~386`,
   marked `FIXME(G-M2-spec)`) as part of D2. The PII membrane — not the lane label — is the
   actual egress gate; the lane drives **budget-tier routing**.
2. **D2 budget caps enforced in v1 (fail-closed):** **Cost** (micro-currency), **Wall-clock
   latency**, and **Per-day aggregate** spend. Token count is **telemetry-only** in v1 (record
   it, do not gate on it).
3. **D7 eval corpus:** **Hybrid** — a versioned synthetic core (in-repo, reproducible) plus a
   periodically-refreshed sample of real turns, **scrubbed through `fae-pii-membrane` before
   it touches disk**.
4. **Cloud-routing approval default:** **Provisioned = approved; default mode = all available.**
   The user selects a *model availability mode* — **pure-local** / **local + symphony** / **all
   available (cloud + local + ACP)** — with **all available as the default.** Within the
   selected mode, **approval is constituted by credential provisioning, not a runtime popup**:
   setting an API key for a cloud provider = standing approval for that provider; installing an
   ACP agent = standing approval for that agent. Routes run autonomously once they pass the
   **PII membrane** (floor) **and** stay within the **D2 budget caps** (ceiling). **This
   SUPERSEDES the earlier F-7 default ("defer Tier B/C standing autonomy to M2").** Autonomy is
   bounded by the D2 caps (decision 2) and floored by the membrane — *within a configured,
   credentialed, capped envelope*, never open-ended. **M1's static-direct (local-only) default
   is unchanged until M2 wiring flips the conductor to the selected mode.** Record this
   supersession in the M2 decisions doc so it is not later read as drift.

---

## WP-D2 — Budget governance

**Goal.** A `BudgetGovernor` that the conductor executor consults around every cloud-bound
role-call, enforcing the three v1 caps fail-closed, with per-day state that survives restarts.

**Location.** Rust core — `crates/fae-daemon/src/conductor/budget.rs` (or a `crates/fae-budget`
crate if it grows; your call, justify it).

**Interface contract (this is what the M2 executor wiring will call — design it as the seam):**
- `fn check(&self, route: &OwnedRouteDecision, estimate: &CostEstimate) -> BudgetVerdict`
  where `BudgetVerdict = Allow | Block { dimension, … }`. **Fail-closed:** if budget state is
  unavailable/corrupt, return `Block` (never spend on unknown state).
- `fn record(&self, route, actual: &ActualCost)` — updates per-turn + rolling per-day state.
- A `RouteFailure::BudgetExceeded { dimension, … }` variant carrying **structured fields only,
  never user text** (mirror the existing `PrivacyBlocked { level, labels }` discipline).
- Per-day state is a rolling window persisted in the **isolated conductor store** (never
  `fae.db`), same privacy posture as route telemetry.

**Acceptance criteria.**
- The three caps each have a test that proves a route is blocked when the cap is exceeded and
  allowed when under, plus a fail-closed test (unavailable state → block).
- Token usage is recorded in telemetry but never causes a block (decision 2).
- `cargo test -p <crate>` green; strict clippy clean
  (`-D warnings -D clippy::unwrap_used -D clippy::expect_used -D clippy::panic`); fmt clean.
- Zero behavior change to M1 (`StaticDirectPolicy` is local-only; the governor is dormant until
  the executor wires it — ship it staged with scoped, dated `#[allow(dead_code)]` + `TODO(M2)`).

**Out of scope.** Executor egress wiring; real provider cost APIs (use a `CostEstimate` the
caller supplies); the `CloudBacked` *execution* path (you define the lane variant + its
budget-tier routing, not the cloud call itself).

---

## WP-D7 — Eval corpus + routing scorer

**Goal.** A versioned hybrid corpus and a `RoutingScorer` that produces the reward signal the
M2 aggregator (and later M3 MetaOpt) consumes — with the statistical-significance gate baked in.

**Location.** Rust core — corpus under `crates/fae-daemon/` resources or a `crates/fae-conductor-eval`
crate; scorer in Rust.

**Interface contract.**
- Corpus format: versioned JSON — each entry carries non-content metadata
  (`task_class`, `feature_predicates`, an `ideal_route` label) and **must not embed raw user
  text** beyond what is needed; any real-sample text is membrane-scrubbed first.
- `fn score(corpus: &Corpus, policy: &dyn ConductorRoutingPolicy) -> RoutingScore`
  yielding `routing_accuracy` + per-dimension deltas.
- **F-12 gate, encoded as code, not prose:** "measured improvement" = statistically significant
  **AND** ≥5% relative improvement **AND** no regression on any measured dimension. The scorer
  exposes this as a single `is_improvement(baseline, candidate) -> bool` so the aggregator can't
  accidentally promote on a weak signal.
- **F-11:** document the single-annotator (David) limitation and corpus versioning in the crate
  docs.

**Acceptance criteria.**
- Synthetic core committed + versioned; a test that the scorer reproduces a known score on it.
- A test that `is_improvement` rejects: (a) sub-5% gains, (b) any single-dimension regression,
  (c) statistically-insignificant deltas.
- Real-sample ingestion path proves membrane-scrubbing happens **before** any disk write (a test
  feeding credential-shaped text and asserting it is redacted in the stored corpus entry).
- Strict clippy / fmt / tests green as above.

**Out of scope.** The reward aggregator itself (M2 spec integration); MetaOpt mutation (M3);
auto-deploy (explicitly deferred — candidates compare to baseline only).

---

## Shared engineering contract (both WPs)

- **ADR-011:** new code targets the Rust core, not Swift.
- **No `.unwrap()`/`.expect()`/`panic!` in production** (tests OK); `#![forbid(unsafe_code)]`.
- **Gate discipline — no pipe-masking.** Run gates with `set -euo pipefail` and explicit
  exit-code checks; never `… | tail -1 && echo "clean"` (a real fmt/test failure was masked
  this way on 2026-06-22). Commit `Cargo.lock`.
- **Privacy invariant:** nothing you build may write user text into telemetry, receipts, labels,
  budget state, or corpus entries except membrane-scrubbed real samples in D7. Structured tokens
  only, per F-4.
- **Staged dormant:** neither WP changes runtime behavior until the M2 executor wiring lands.
  Ship both behind scoped, dated `#[allow(dead_code)]` + `TODO(M2)`, removable as an M2-wiring
  acceptance criterion.
- **Review gates:** each WP gets a `reviewer` pass (zero BLOCKER/MAJOR) before it is called done.
  The combined M2 spec then goes through **G-M2-spec** (`plan-reviewer`) — your interface
  contracts above are the inputs that spec consumes, so keep them stable and documented.
- **Worktrees:** each WP runs in its own git worktree to avoid `.git/index.lock` races.

## Coordination

- **D2 and D7 are independent of each other** — run them in parallel.
- The **owner's track** drafts the M2 spec (the contract) and the MetaOpt port (M3 groundwork,
  faithful/behavior-preserving — not adapted to conductor yet) in parallel with you. The M2 spec
  consumes the `BudgetGovernor` and `RoutingScorer` interfaces above; if you need to change a
  signature, flag it so the spec stays in sync.
- **Do not** start executor egress wiring or any cloud-provider call — that is the gated M2
  integration step after both WPs + the spec pass review.

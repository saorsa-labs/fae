# M2 — Reward, Eval & Shadow Routing Spec (Learned Conductor)

- **Status:** DRAFT v1 — for G-M2-spec review (`plan-reviewer`, mandatory; `oracle` recommended for inherited privacy state). Not yet implementation-authorized.
- **Date:** 2026-06-23
- **Supersedes:** none. Builds on M1 (`docs/architecture/conductor-m1-static-recipes-spec-2026-06-22.md`, G-M1 PASSED) and consumes the two M2 primitives that just landed: WP-D2 budget governance (`crates/fae-daemon/src/conductor/budget.rs`) and WP-D7 eval corpus + scorer (`crates/fae-daemon/src/conductor/eval.rs`), plus the PII egress membrane (`crates/fae-pii-membrane/`, D-M2-4 RATIFIED port).
- **Parent plan:** `docs/plans/fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md`
- **Decisions locked upstream:** D-M2-4 (PII membrane = PORT, done; MetaOpt = PORT NOW, in flight). Owner ruling 2026-06-23 (approval = credential provisioning + mode selection; default = all available; PII floor + D2 ceiling). D-M2-1 items 1–3, 6 settled (membrane is egress authority; `PrivacyLane::CloudBacked` landed; tiering layers on top; genuinely-local ACP = LocalModel).
- **Open D-M2-1 items this spec resolves:** #4 (per-provider granularity → per-worker budget, one shared lane), #5 (`WorkerLocality::LocalAcp` rename → `CloudBackedAcp`).

---

## 1. Goal & scope

M2 is the milestone where the conductor **stops being local-only and becomes a real learned router**: it routes cloud-backed work *through* the PII membrane under budget governance, measures routing quality against a versioned corpus, and shadows candidate policies — all while the deployed policy stays byte-identical to M1 for the direct-local path.

**In scope (M2):**
- **Cloud-egress executor wiring** — the per-role-call gate pipeline (§5) that sends cloud-bound prompts through the PII membrane + `BudgetGovernor`, fail-closed to direct-local on any block.
- **Approval/mode model wiring** — the operator mode (pure-local / local+symphony / all-available) gates which lanes are even *eligible*; within an eligible lane, a provisioned credential constitutes the standing grant (owner ruling 2026-06-23). Tier C `PerTurn` for non-provisioned lanes.
- **Reward aggregator** (F-10) — combines the D7 `RoutingScore` (human-labeled corpus), `RouteReceipt.user_signal`, cost/latency/privacy metrics, and advisory-only model self-judgment into a per-candidate reward. **Positive reward never comes from self-judgment alone.**
- **Shadow router** — runs candidate policies *decision-only* alongside the deployed policy; scores both against the corpus; promotes a candidate only via `is_improvement()` (D7's F-12 gate, as code). Shadow never egresses, never spends, never crosses owners.
- **M2 wiring obligations** carried from the WP-D2 reviewer pass: `daily_window > 0` validation (§5.4) and `eprintln!` → `tracing` migration for activated paths (§9).

**Out of scope (deferred):**
- **MetaOpt mutation of recipes** (M3, gated on ADR-008 amendment). The M2 shadow router *identifies* improving candidates; it does NOT auto-deploy them or mutate the recipe set. Promotion is a human-in-the-loop decision in M2.
- **Mesh / x0x-symphony routing** (M4). `OwnerFleet`/`TrustedPeer` lanes are defined but not wired to real peers in M2.
- **Chain topology activation** (stays triple-gated off; D-M2-2 blockers). But the per-role-call PII membrane check (§5.3) is specified now so chain can land safely later.
- **Auto-deploy of shadow winners** (M3). M2 compares candidates against the deployed baseline only.

---

## 2. Primitives consumed (interfaces frozen)

M2 builds on three primitives whose interfaces are now stable on `main`:

### 2.1 `BudgetGovernor` (WP-D2, `conductor/budget.rs`)
```rust
pub struct BudgetGovernor { /* store + limits + clock */ }
impl BudgetGovernor {
    pub fn new(store: Arc<ConductorStore>, limits: BudgetLimits) -> Self;
    pub fn check(&self, route: &OwnedRouteDecision, estimate: &CostEstimate) -> BudgetVerdict;
    pub fn record(&self, route: &OwnedRouteDecision, actual: &ActualCost);
}
pub enum BudgetVerdict { Allow, Block { dimension, limit, attempted, used, window_ms } }
pub struct BudgetLimits { cost_micros_per_call, wall_clock_ms_per_call, daily_cost_micros, daily_window_ms }
pub struct CostEstimate { cost_micros, wall_clock_ms, input_tokens, output_tokens }  // tokens telemetry-only
```
Fail-closed on corrupt/unavailable per-day state (verified in WP-D2 review). `BudgetDimension` has **no token variant** — token count is recorded, never gates.

### 2.2 `RoutingScorer` (WP-D7, `conductor/eval.rs`)
```rust
pub fn score(corpus: &Corpus, policy: &dyn ConductorRoutingPolicy) -> RoutingScore;
pub fn is_improvement(baseline: &RoutingScore, candidate: &RoutingScore) -> bool;
```
`is_improvement` is **F-12 as code**: same `corpus_version` AND statistically significant (real McNemar exact test) AND ≥5% relative AND no per-dimension regression. The reward aggregator (§7) consumes `RoutingScore`; the shadow router (§8) consumes `is_improvement`.

### 2.3 `fae-pii-membrane` (D-M2-4 RATIFIED port, `crates/fae-pii-membrane/`)
```rust
pub fn scan(text: &str) -> ScanResult;
pub fn should_block_remote_egress(text: &str) -> bool;   // the egress authority
pub fn redact_for_storage(text: &str) -> String;
pub fn should_persist_proactive_observation(text: &str) -> bool;
```
This is the **canonical egress authority** (Rust, `#![forbid(unsafe_code)]`, ReDoS-resistant linear-time regex). It is the F-2 egress membrane landing point — the mirror of the already-Rust `fae-envelope-gate` ingress. The conductor calls `should_block_remote_egress` *before* constructing any cloud-bound request.

---

## 3. D-M2-1 resolutions (the two open items)

### 3.1 Per-provider granularity (item #4) → **per-worker budget, one shared lane**

Decision: **one shared `PrivacyLane::CloudBacked` lane** for all cloud-backed ACP workers, **per-worker budget buckets** keyed by `worker_id`.

Rationale:
- The **lane** drives the *trust tier* (all cloud-backed = Tier B) and the *egress gate* (the PII membrane is provider-agnostic — egress is egress). One lane is correct for both.
- The **budget** is where per-provider control matters (different providers have different pricing + data-retention). `BudgetGovernor` already takes `&OwnedRouteDecision` (which carries `worker_id`), so per-worker daily-cost buckets are a natural extension of the existing per-day aggregate. Each provisioned provider gets its own `daily_cost_micros` cap.

Concretely: `BudgetGovernor` grows a `per_worker_daily_cost_micros: HashMap<String, u64>` (or the operator configures a `BudgetLimits` per worker). The lane enum stays at one `CloudBacked`. This avoids a lane explosion while giving real per-provider cost control.

### 3.2 `WorkerLocality::LocalAcp` rename (item #5) → **`CloudBackedAcp`**

Decision: rename `WorkerLocality::LocalAcp` → `WorkerLocality::CloudBackedAcp`. `locality_to_lane(CloudBackedAcp) → PrivacyLane::CloudBacked` (unchanged from the WP-D2 fix).

Rationale: the name `LocalAcp` caused the original privacy-model confusion (local *process* ≠ local *data*). `CloudBackedAcp` is honest about where the data goes and parallels the lane name directly. Cheap now (nothing persists recipes in M1); expensive later. **This is a schema migration done in the M2 impl, before any recipe is ever persisted.**

Genuinely-local ACP runners (if they ever exist — a local-LLM ACP) map to `WorkerLocality::LocalModel` (item #6, already settled): the discriminator is *data egress*, not process locality.

---

## 4. Approval / mode model (owner ruling 2026-06-23)

The operator selects a **model availability mode** (read once at daemon startup from `FAE_MODEL_MODE`, default `all-available`):

| Mode | Permitted lanes | Effect |
|---|---|---|
| `pure-local` | `LocalOnly` only | M1 behavior exactly. Every non-local route fails closed to direct-local at the mode cap (§5.2). |
| `local-symphony` | `LocalOnly`, `OwnerFleet` | Local models + same-owner x0x peers (Symphony). Cloud-backed ACP + remote providers blocked at the mode cap. |
| `all-available` *(default)* | all lanes | Cloud-backed ACP (Tier B), OwnerFleet (Tier B/C), TrustedPeer/RemoteProvider (Tier C) all eligible, each gated by membrane + budget + approval. |

**Approval is constituted at provisioning time, not via a separate runtime step:**
- Setting an API key for a provider (OpenAI/Anthropic/Google) = **standing approval** (`ApprovalClass::StandingGrant`) for that provider's `CloudBackedAcp` worker, bounded by its D2 caps.
- Installing an ACP agent = **standing approval** for that agent.
- Non-provisioned lanes (`TrustedPeer`, `RemoteProvider`, un-credentialed providers) remain **Tier C `PerTurn`** — require per-turn approval.

This **supersedes** the earlier F-7 default ("defer Tier B/C standing autonomy to M2"). Autonomy in M2 is *within a configured, credentialed, capped envelope* — floored by the PII membrane, ceilinged by D2 caps. M1's local-only default is unchanged until the M2 wiring flips the conductor to the selected mode.

---

## 5. The per-role-call gate pipeline (the core M2 wiring)

This is the heart of M2. For **every** routed turn, the executor runs this pipeline. The order is load-bearing — each gate before egress is a hard stop.

```
policy.decide(ctx) ──▶ OwnedRouteDecision { worker_id, topology, lane, approval }
        │
        ▼
[5.1] recipe/worker resolution (M1 §5.4, unchanged) ──miss──▶ fail-closed direct-local
        │
        ▼
[5.2] MODE CAP: is decision.lane permitted by FAE_MODEL_MODE? ──no──▶ fail-closed direct-local
        │
        ▼
[5.3] PII MEMBRANE (only if lane != LocalOnly):
        should_block_remote_egress(prompt)? ──yes──▶ RouteFailure::PrivacyBlocked ──▶ fail-closed direct-local
        (chain topology: run per-role-call — a Thinker→Worker→Verifier chain to cloud egresses 3×)
        │
        ▼
[5.4] BUDGET CHECK: BudgetGovernor::check(route, estimate)
        ├── Allow ──▶ proceed
        └── Block  ──▶ RouteFailure::BudgetExceeded ──▶ fail-closed direct-local
        │
        ▼
[5.5] APPROVAL ASSERT: does decision.approval match the provisioned grant for this worker?
        ├── Tier A (None) for LocalOnly: always OK
        ├── Tier B (StandingGrant) for provisioned CloudBackedAcp/OwnerFleet: OK (credential = grant)
        └── Tier C (PerTurn) for non-provisioned: require per-turn approval surface (M2 adds) ──denied──▶ fail-closed
        │
        ▼
[5.6] WORKER CALL: execute the route (local model / cloud API / ACP / chain)
        │
        ▼
[5.7] BUDGET RECORD: BudgetGovernor::record(route, actual)
        │
        ▼
[5.8] TELEMETRY: emit_event + emit_receipt (spawn_blocking, isolated ConductorStore — never fae.db)
```

### 5.1 Resolution (M1, unchanged)
Recipe/worker lookup per M1 §5.4. Miss → `InvalidRecipe`/`WorkerUnavailable` → fail-closed direct-local.

### 5.2 Mode cap (NEW)
A pure check: `mode.permits(decision.lane)`. `pure-local` permits only `LocalOnly`; `local-symphony` permits `LocalOnly`+`OwnerFleet`; `all-available` permits all. A lane not permitted by the mode → fail-closed direct-local. This runs **before** the membrane so a pure-local operator never pays for a membrane scan of a route that can't run anyway.

### 5.3 PII membrane (NEW — the F-2 egress authority landing)
For any route whose `lane != LocalOnly`, call `fae_pii_membrane::should_block_remote_egress(&prompt)` **before constructing the outbound request**. Block → `RouteFailure::PrivacyBlocked { level, labels }` (structured labels only, never the matched text — the WP-D2 precedent) → fail-closed direct-local. The prompt never egresses.

For `chain` topology: the membrane runs **per role-call** (Thinker, Worker, Verifier each get scanned). A chain to a cloud model egresses three times; one outer scan is insufficient (D-M2-2). Any role-call block aborts the chain → fail-closed direct-local.

### 5.4 Budget check (NEW — consumes WP-D2)
`BudgetGovernor::check(route, estimate)`. Block → `RouteFailure::BudgetExceeded` → fail-closed direct-local. The `estimate` is a pre-flight cost/wall-clock estimate (provider-specific); tokens are carried but never gate.

**M2 wiring obligation (carried from WP-D2 reviewer MINOR):** add `BudgetLimits` validation that `daily_window_ms > 0` (a zero window is degenerate — per-call isolation, more restrictive but not intended). Fail-closed is NOT weakened by this; it's a correctness fix.

### 5.5 Approval assertion (NEW — owner ruling)
Map `decision.lane` + worker provisioning state to the required `ApprovalClass`:
- `LocalOnly` → `None` (Tier A). Always asserted.
- `CloudBackedAcp`/`OwnerFleet` with a provisioned credential → `StandingGrant` (Tier B). The credential IS the grant.
- `TrustedPeer`/`RemoteProvider`/un-credentialed → `PerTurn` (Tier C). M2 adds the per-turn approval surface (an event the control plane must acknowledge before egress).

A mismatch (e.g. Tier C lane with no per-turn approval) → fail-closed direct-local. Defense-in-depth: the executor treats a `None` approval on a non-`LocalOnly` lane as a `RouteFailure` (unreachable if the policy is correct, but enforced).

### 5.6 Worker call
Execute. For cloud-backed workers this constructs the provider request *after* gates 5.2–5.5 pass. For chain, iterate roles with per-role membrane checks (5.3).

### 5.7 Budget record + 5.8 Telemetry
`BudgetGovernor::record(route, actual)` writes the actual cost to the isolated per-worker/per-day state. Telemetry emits the event + receipt (M1 §9, unchanged — spawn_blocking, best-effort, never `fae.db`).

---

## 6. The M2 safety contract: no egress without all gates green; byte-identity only for direct-local

The single most important M2 property: **a prompt never reaches a cloud provider unless the mode cap, the PII membrane, the budget check, AND the approval assertion all pass.** Any failure at §5.2–5.5 produces **zero egress** and degrades to direct-local (the M1 path) or a safe refusal.

**Byte-identity is preserved ONLY for the direct-local route.** When `decision.lane == LocalOnly` (the M1 default under `pure-local` mode, or any turn the policy routes local), the executor calls `inject_text_core` verbatim — identical to M1, including the `assistant.generating` event pair and NaN-retry (the M1 §8 contract holds unchanged).

For non-local routes, byte-identity is **not claimed and not tested** — those routes have their own contract: the gate pipeline (§5) defines their safety, and the receipt records their outcome. The M1 golden test (conductor-routed-direct == legacy inject_text) must still pass in M2 for the direct path.

**Required test (G-M2 impl):**
1. The M1 byte-identity test still passes (direct-local through the M2 pipeline == legacy `inject_text`).
2. A cloud-bound prompt containing a credential (`sk-...`) is **blocked** by the membrane and **never reaches** a mock provider (assert the mock received zero calls); the turn degrades to direct-local and the receipt records `PrivacyBlocked`.
3. A cloud-bound prompt that passes the membrane but exceeds the budget cap is blocked at §5.4; the mock provider receives zero calls.
4. A `pure-local` mode operator never triggers a membrane scan or budget check for any turn (all routes are direct-local).

---

## 7. Reward aggregator (F-10 — reject self-judgment-only)

F-10 forbids a reward signal that is *only* the model judging its own output. The M2 reward aggregator combines **four** signal sources, and **model self-judgment is advisory-only — it can never be the sole source of positive reward**.

```rust
pub struct RewardSignals {
    routing_score: RoutingScore,      // (1) human-labeled corpus accuracy (WP-D7 ground truth)
    user_signal: Option<UserSignal>,  // (2) explicit accept/reject/correction (RouteReceipt capture, M2)
    outcome_metrics: OutcomeMetrics,  // (3) cost + latency + privacy from RouteReceipt
    self_judgment: Option<SelfJudgment>, // (4) ADVISORY ONLY — can negative-weight, never sole positive
}
pub fn aggregate_reward(signals: &RewardSignals) -> Reward;
```

1. **Routing accuracy** (primary positive signal) — the D7 `RoutingScore` from the versioned, human-labeled corpus. This is ground truth, not model output.
2. **User signal** — explicit feedback captured in `RouteReceipt.user_signal` (M2 adds the capture seam): accept / reject / edit / rating. A user rejection is a strong *negative* signal.
3. **Outcome metrics** — cost (micros), wall-clock latency, and privacy outcomes (was the route blocked? did it degrade?) from `RouteReceipt`. Lower cost + lower latency + clean privacy = higher reward; a `PrivacyBlocked` degradation is a negative signal.
4. **Self-judgment** (advisory only) — a model's own assessment of output quality. **May contribute a negative weight** ("this output looks wrong") but **may never be the sole source of positive reward.** Enforced in `aggregate_reward`: if signals 1–3 are all absent/neutral, `self_judgment` alone cannot produce a positive reward.

The aggregator produces a scalar `Reward` per candidate policy over a scoring window. The shadow router (§8) uses `is_improvement()` on the resulting `RoutingScore`s to decide promotion eligibility — reward alone does not auto-promote.

---

## 8. Shadow router (decision-only by default; never egresses)

The shadow router runs **candidate policies alongside the deployed policy**, scoring both — without the candidates ever causing egress, spend, or cross-owner traffic.

```
For each turn:
  deployed_decision = deployed_policy.decide(ctx)        # executed (through the §5 pipeline)
  for candidate in shadow_candidates:
      candidate_decision = candidate.decide(ctx)          # NOT executed — decision only
      # both scored against the corpus's ideal_route for this turn's features
  record both decisions + corpus match into the shadow log (isolated ConductorStore)
```

**Hard constraints:**
- **Decision-only by default.** Candidate decisions are computed and scored; they are **not executed**. No provider call, no ACP call, no egress, no spend.
- **If shadow execution is ever enabled** (a future flag, NOT in M2's default): local-only + strictly budgeted + never remote/paid/cross-owner. M2 does not ship shadow execution.
- **Never remote/paid/cross-owner in shadow.** Even with shadow execution enabled later, shadow execution is confined to `LocalOnly` workers.
- **Promotion is not automatic.** A candidate that beats the deployed policy per `is_improvement()` (D7's F-12 gate: significant + ≥5% + no regression) becomes a *promotion candidate* — flagged for human review, NOT auto-deployed. Auto-deploy is M3 (MetaOpt, ADR-008-gated).

The shadow log is part of the reward aggregator's input (§7) — it's how the deployed policy's live routing accuracy gets measured against the corpus over time, alongside the human-labeled baseline.

---

## 9. Telemetry + tracing migration (M2 wiring obligation)

Telemetry isolation is unchanged from M1 §9 (isolated `ConductorStore` JSONL, 0700, spawn_blocking, best-effort, never `fae.db`). M2 adds:
- `RouteReceipt.user_signal` capture (§7) — the explicit-feedback seam.
- `RouteReceipt.eval_delta` populated from the shadow router's per-turn corpus match (when a corpus entry matches the turn's features).
- `RouteFailure::PrivacyBlocked { level, labels }` and `BudgetExceeded { ... }` in the receipt's `fallback_reason` (structured-only, never the matched secret).

**M2 wiring obligation (carried from WP-D2 reviewer NOTE):** migrate `eprintln!` → `tracing::warn!`/`tracing::info!` for all paths activated in M2 (the §5 pipeline gates, the budget governor, the shadow router). Dormant paths (chain, M3 surfaces) may keep `eprintln!` until activated. This requires adding the `tracing` dep + a subscriber in `main.rs`.

---

## 10. Files touched (M2 implementation, post-spec-approval)

- `crates/fae-daemon/src/conductor/recipe.rs` — rename `WorkerLocality::LocalAcp` → `CloudBackedAcp` (§3.2); no lane-enum change (`CloudBacked` already landed in WP-D2).
- `crates/fae-daemon/src/conductor/executor.rs` — **the §5 gate pipeline**: mode cap, PII membrane call (per-role for chain), budget check/record, approval assertion. Direct arm unchanged (still `inject_text_core` verbatim). Remove the `route_failure_display` arms' `eprintln!` → `tracing`.
- `crates/fae-daemon/src/conductor/budget.rs` — add `BudgetLimits::validate()` (`daily_window_ms > 0`); wire per-worker daily buckets (§3.1); `eprintln!` → `tracing`.
- `crates/fae-daemon/src/conductor/policy.rs` — `StaticDirectPolicy` stays M1 behavior; add the mode-aware lane eligibility used by §5.2 (pure function over mode + lane).
- `crates/fae-daemon/src/conductor/shadow.rs` — **NEW**: the shadow router (§8). Decision-only; isolated shadow log; promotion-candidate flagging via `is_improvement`.
- `crates/fae-daemon/src/conductor/reward.rs` — **NEW**: the reward aggregator (§7). Four-signal; self-judgment advisory-only enforced in code.
- `crates/fae-daemon/src/conductor/workers.rs` — `WorkerRegistry` grows provisioned cloud-backed workers (keyed by credential presence); `local-model` remains always-present.
- `crates/fae-daemon/src/main.rs` — read `FAE_MODEL_MODE` at startup; construct `BudgetGovernor` (per-worker limits), wire `fae-pii-membrane`, initialize `tracing` subscriber.
- `crates/fae-daemon/Cargo.toml` — add `fae-pii-membrane` (workspace path) + `tracing` + `tracing-subscriber`.

No Swift changes. No `fae.db` writes. No M3 recipe mutation.

---

## 11. Progressive-disclosure copy (extends M1 §11)

M1 is invisible (L0) because direct-local is the only route. M2 adds visible surfaces **only when behavior differs from direct-local**:

- **L1** ("I'm asking Claude/Gemini/Codex") — emitted when a cloud-backed route is *selected and executed* (gates all green). One line, plain, no jargon. Consistent with SOUL.md "head butler."
- **L2** ("I kept this on your Mac — it looked private") — emitted when a route the policy *would have* sent cloud is blocked by the PII membrane and degrades to direct-local. Reassuring, not alarming.
- **L3** ("That would have cost $X / hit the daily cap") — emitted on budget block. Optional; behind a verbosity setting.
- **L4** (opt-in team view) — future settings surface; not built in M2.

Copy is never emitted for the shadow router (it's invisible by design — decision-only). Copy templates live in `conductor/prompts.rs` alongside the chain role prompts.

---

## 12. G-M2-spec acceptance criteria (for `plan-reviewer`)

The spec review passes when:
1. **D-M2-1 fully resolved.** Items 1–6 all have a decision; the two open ones (#4 per-provider, #5 rename) are decided here with rationale.
2. **The gate pipeline is unambiguous.** §5's order is total and each gate has a defined failure → no-egress → degrade behavior. No gate can be bypassed.
3. **F-10 is enforced in code shape.** §7's `aggregate_reward` makes self-judgment advisory-only by construction (cannot be sole positive reward).
4. **Shadow router is provably non-egressing.** §8's decision-only contract + never-remote constraint are explicit and testable.
5. **Byte-identity scoped honestly.** §6 claims byte-identity for direct-local only, and does not claim it for non-local routes.
6. **Frozen interfaces consumed correctly.** §2's signatures match what landed in WP-D2/WP-D7/PII-membrane.
7. **M2 wiring obligations captured.** The two carried WP-D2 MINORs (daily_window validation, eprintln→tracing) are §5.4/§9 items.

## 13. G-M2 impl acceptance criteria (for `reviewer`, post-impl)

The impl review passes when:
1. **No-egress-on-failure:** tests prove a blocked membrane/budget/approval/mode route sends zero calls to any mock provider and degrades to direct-local (§6 tests).
2. **Byte-identity for direct-local:** the M1 golden test still passes through the M2 pipeline.
3. **Per-role membrane (chain):** a chain to a cloud mock is blocked if any of Thinker/Worker/Verifier prompts fail the membrane (chain stays off, but the test exercises the gate).
4. **F-10 enforced:** a unit test proves `aggregate_reward` with only `self_judgment` (signals 1–3 absent) yields non-positive reward.
5. **Shadow is decision-only:** a test proves a shadow candidate's decision is computed and scored but zero provider calls occur; the shadow log lands in the isolated store.
6. **Mode cap:** `pure-local` mode blocks all non-local routes at §5.2 before any membrane scan.
7. **Per-worker budget:** two provisioned providers have independent daily caps; exhausting one does not block the other.
8. **Panic-free + gates:** `cargo clippy -p fae-daemon -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used` clean; fmt + `cargo check --workspace --all-targets` + `cargo test -p fae-daemon` all green.

---

## 14. Open questions for G-M2-spec review

- **Q1 (per-worker budget shape):** is `per_worker_daily_cost_micros: HashMap<worker_id, u64>` on `BudgetGovernor` the right home, or a separate `BudgetLimits` map passed at construction? Lean: map on the governor, keyed by worker_id; default cap for un-listed workers. Reviewer to confirm.
- **Q2 (Tier C approval surface):** the per-turn approval event for `TrustedPeer`/`RemoteProvider` — is an async control-plane event the right shape, or does M2 defer Tier C entirely (wire only Tier A/B, leave Tier C as fail-closed-unimplemented)? Lean: defer Tier C to a point after first cloud-backed ACP route is shipping; M2 wires A/B + leaves C fail-closed. Reviewer to confirm.
- **Q3 (reward window):** over what window does the aggregator score (per-N-turns? time-bounded? on-demand)? Lean: on-demand at promotion-check time, over a fixed-N-turn rolling window in the shadow log. Reviewer to confirm.

# M2 — Reward, Eval & Shadow Routing Spec (Learned Conductor)

- **Status:** DRAFT v2 — G-M2-spec **PASSED** (re-review run 860ab950, 2026-06-23: all 5 MAJORs + 6 MINORs + 2 NOTEs resolved, zero unresolved BLOCKER/MAJOR). v2.1 patch folds 2 substantive re-review NOTEs (wall-clock-per-call honestly advisory; chars/3 conservative heuristic) so the impl inherits correct expectations. Not yet implementation-authorized (M2 wiring starts after this gate).
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
- **Reward aggregator** (F-10) — combines the D7 `RoutingScore` (human-labeled corpus), user-feedback signals (joined from a late-arriving feedback log, §7/MAJOR-4), cost/latency/privacy metrics, and advisory-only model self-judgment into a per-candidate reward. **Positive reward never comes from self-judgment alone.**
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
    pub fn new(store: ConductorStore, limits: BudgetLimits) -> Self;
    pub fn check(&self, _route: &OwnedRouteDecision, estimate: &CostEstimate) -> BudgetVerdict;
    pub fn record(&self, route: &OwnedRouteDecision, actual: &ActualCost);
}
pub enum BudgetVerdict { Allow, Block { dimension, limit, attempted, used, window_ms } }
pub struct BudgetLimits {
    pub max_cost_micros_per_call: u64,
    pub max_wall_clock_ms_per_call: u64,
    pub max_daily_cost_micros: u64,
    pub daily_window: Duration,   // exposes daily_window_ms() -> u64
}
pub struct CostEstimate { cost_micros, wall_clock_ms, input_tokens, output_tokens }  // tokens telemetry-only
```
**Signatures verified against `budget.rs` as-landed (WP-D2).** `new(store: ConductorStore, limits: BudgetLimits)` takes the store **by value** (not `Arc`); the `max_*` field prefixes and `daily_window: Duration` match the frozen code. `check()` currently takes `_route: &OwnedRouteDecision` (the leading `_` marks it ignored in M1/WP-D2 — `rolling_cost_micros` sums across *all* workers). **§3.1's per-worker feature is real new code** (filter `rolling_cost_micros` by `route.worker_id`), not a trivial extension — the signature stays the same, the implementation gains a worker filter. Fail-closed on corrupt/unavailable per-day state (verified in WP-D2 review). `BudgetDimension` has **no token variant** — token count is recorded, never gates.

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
pub fn should_persist_proactive_observation(task_id: &str, text: &str) -> bool;
```
This is the **canonical egress authority** (Rust, `#![forbid(unsafe_code)]`, ReDoS-resistant linear-time regex). It is the F-2 egress membrane landing point — the mirror of the already-Rust `fae-envelope-gate` ingress. The conductor calls `should_block_remote_egress` *before* constructing any cloud-bound request.

---

## 3. D-M2-1 resolutions (the two open items)

### 3.1 Per-provider granularity (item #4) → **per-worker budget, one shared lane**

Decision: **one shared `PrivacyLane::CloudBacked` lane** for all cloud-backed ACP workers, **per-worker budget buckets** keyed by `worker_id`.

Rationale:
- The **lane** drives the *trust tier* (all cloud-backed = Tier B) and the *egress gate* (the PII membrane is provider-agnostic — egress is egress). One lane is correct for both.
- The **budget** is where per-provider cost control matters (different providers have different pricing). `BudgetGovernor::check()` already receives `&OwnedRouteDecision` (which carries `worker_id`), so per-worker daily-cost buckets are a *feasible* extension — but note this is **real new code**, not a trivial change: today `check(_route: …)` ignores the route entirely and `rolling_cost_micros` sums across *all* workers (NOTE-2 fix). M2 adds a `worker_id` filter to `rolling_cost_micros` + a `HashMap<worker_id, u64>` per-worker daily cap. The lane enum stays at one `CloudBacked`.

Concretely: `BudgetGovernor` grows `per_worker_limits: HashMap<String, BudgetLimits>` (construction in §10). The lane enum stays at one `CloudBacked`. This avoids a lane explosion while giving real per-provider cost control.

**Per-provider *data-retention* differentiation — EXPLICITLY DEFERRED (MAJOR-5).** The rationale above addresses *pricing*. Data retention is a distinct privacy axis: a "trains-on-your-data" provider vs a "zero-retention" provider are both mapped to one `CloudBacked` lane + Tier B `StandingGrant` in M2, even though non-credential context that passes the PII membrane can be retained differently per provider. The membrane mitigates *content* risk (strips credentials/PII); it does not model provider retention/training policies. **M2 deliberately models all `CloudBacked` providers at the same trust tier.** Per-provider retention differentiation is deferred to a provider-metadata ADR / M4 — it requires a provider-metadata registry (retention policies, training-on-data flags, DPA status) that is itself a data-gathering exercise beyond M2's scope. The membrane + Tier B budget + credential-provisioning-is-consent model is a sound floor for M2; it is not the final word on per-provider privacy.

### 3.2 `WorkerLocality::LocalAcp` rename (item #5) → **`CloudBackedAcp`**

Decision: rename `WorkerLocality::LocalAcp` → `WorkerLocality::CloudBackedAcp`. `locality_to_lane(CloudBackedAcp) → PrivacyLane::CloudBacked` (unchanged from the WP-D2 fix).

Rationale: the name `LocalAcp` caused the original privacy-model confusion (local *process* ≠ local *data*). `CloudBackedAcp` is honest about where the data goes and parallels the lane name directly. Cheap now (nothing persists recipes in M1); expensive later. **This is a schema migration done in the M2 impl, before any recipe is ever persisted.**

Genuinely-local ACP runners (if they ever exist — a local-LLM ACP) map to `WorkerLocality::LocalModel` (item #6, already settled): the discriminator is *data egress*, not process locality.

---

## 4. Approval / mode model (owner ruling 2026-06-23)

The operator selects a **model availability mode** (read once at daemon startup from `FAE_MODEL_MODE`):

| Mode | Permitted lanes | Effect |
|---|---|---|
| `pure-local` | `LocalOnly` only | M1 behavior exactly. Every non-local route fails closed to direct-local at the mode cap (§5.2). |
| `local-symphony` | `LocalOnly`, `OwnerFleet` | Local models + same-owner x0x peers (Symphony). Cloud-backed ACP + remote providers blocked at the mode cap. |
| `all-available` | all lanes | Cloud-backed ACP (Tier B), OwnerFleet (Tier B/C), TrustedPeer/RemoteProvider (Tier C) all *eligible*. Tier A/B are wired in M2; **Tier C lanes are eligible-but-fail-closed-unimplemented** in M2 (Q2) — a route the policy assigns to a Tier C lane degrades to direct-local at §5.5 rather than egressing without an approval surface. |

**Destination default = `all-available`** (the owner ruling's intended state once the egress path is proven and security-reviewed). **BUT the landing default is `pure-local`** — see §15 (Staged landing). The M2 wiring lands behind `FAE_MODEL_MODE` defaulting to `pure-local`, so cloud egress is *reachable only by explicit operator opt-in* until a separate gated cutover (§15 Stage 3) flips the default to `all-available`. "Wiring works" and "cloud egress on by default" are deliberately different commits. This §4 table describes the eventual destination; §15 governs the path there.

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
For `lane == LocalOnly`, this gate is a **no-op** (MAJOR-2 fix): Tier A local turns have no cloud cost, so no `CostEstimate` is computed and `check()` is never called — preserving byte-identity on the direct-local hot path under any mode (including `all-available`).

For non-local lanes: `BudgetGovernor::check(route, estimate)`. Block → `RouteFailure::BudgetExceeded` → fail-closed direct-local. Tokens are carried in the estimate but never gate.

**CostEstimate provenance (MAJOR-3 fix — without this the per-call cap is meaningless).** The estimate is produced by a new `conductor/pricing.rs` module (§10):
- A per-provider pricing table `ProviderPricing { input_micros_per_token, output_micros_per_token }`, keyed by `worker_id`, loaded at daemon startup from operator config.
- `estimate_cost(worker_id, prompt, max_output_tokens) -> CostEstimate`: input tokens estimated by a conservative heuristic (≈ chars/**3**, deliberately over-counting so the cap errs toward blocking — G-M2-spec NOTE: chars/4 is roughly neutral for English, not reliably conservative); output tokens estimated from `max_output_tokens` (worst case).
- **Wall-clock-per-call is advisory/telemetry-only in M2 (G-M2-spec NOTE).** The estimate sets `wall_clock_ms = 0` (no reliable pre-flight latency estimate), so `max_wall_clock_ms_per_call` cannot fire from the estimate. M2 does NOT implement a mid-call timeout/abort (§5.6). Per-call wall-clock is therefore enforced only indirectly — via the per-call **cost** cap and the daily aggregate — and the `max_wall_clock_ms_per_call` field is effectively advisory until a mid-call cancellation feature lands. Stated plainly here so the impl does not imply enforcement that §5 does not provide.
- **Uncostable ⇒ fail-closed.** If a route targets a `worker_id` with no pricing entry, the estimate cannot be bounded → `RouteFailure::BudgetExceeded { dimension: CostMicros, … }` → fail-closed direct-local. A provider cannot egress until it has a pricing entry; this prevents unbounded spend on a misconfigured provider.

**M2 wiring obligation (carried from WP-D2 reviewer MINOR):** add `BudgetLimits::validate()` that `daily_window > Duration::ZERO` (a zero window is degenerate — per-call isolation, more restrictive but not intended). Fail-closed is NOT weakened by this; it's a correctness fix.

### 5.5 Approval assertion (NEW — owner ruling)
For `lane == LocalOnly`, this gate is a **no-op** (MAJOR-2 fix): `ApprovalClass::None` (Tier A) is always asserted for local turns, with no provisioning lookup — preserving byte-identity on the direct-local hot path under any mode.

For non-local lanes, map `decision.lane` + worker provisioning state to the required `ApprovalClass`:
- `LocalOnly` → `None` (Tier A). Always asserted.
- `CloudBackedAcp`/`OwnerFleet` with a provisioned credential → `StandingGrant` (Tier B). The credential IS the grant.
- `TrustedPeer`/`RemoteProvider`/un-credentialed → `PerTurn` (Tier C). M2 adds the per-turn approval surface (an event the control plane must acknowledge before egress).

A mismatch (e.g. Tier C lane with no per-turn approval) → fail-closed direct-local. Defense-in-depth: the executor treats a `None` approval on a non-`LocalOnly` lane as a `RouteFailure` (unreachable if the policy is correct, but enforced).

### 5.6 Worker call
Execute. For cloud-backed workers this constructs the provider request *after* gates 5.2–5.5 pass. For chain, iterate roles with per-role membrane checks (5.3).

### 5.7 Budget record + 5.8 Telemetry
`BudgetGovernor::record(route, actual)` writes the actual cost to the isolated per-worker/per-day state — **only after a successful (or partially-successful) worker call** (MINOR-3: a blocked route at §5.2–§5.5 writes no phantom spend). **Error-path cost (MINOR-6):** a cloud call that incurs billed tokens then returns a network/provider error *does* record its `ActualCost` (the spend is real even if the turn failed) — but the receipt records `success: false` so the reward aggregator (§7) can penalize the failure. Telemetry emits the event + receipt (M1 §9, unchanged — spawn_blocking, best-effort, never `fae.db`).

---

## 6. The M2 safety contract: no egress without all gates green; byte-identity only for direct-local

The single most important M2 property: **a prompt never reaches a cloud provider unless the mode cap, the PII membrane, the budget check, AND the approval assertion all pass.** Any failure at §5.2–5.5 produces **zero egress** and degrades to direct-local (the M1 path) or a safe refusal.

**Byte-identity is preserved ONLY for the direct-local route.** When `decision.lane == LocalOnly` (the M1 default under `pure-local` mode, or any turn the policy routes local), the executor calls `inject_text_core` verbatim — identical to M1, including the `assistant.generating` event pair and NaN-retry (the M1 §8 contract holds unchanged).

For non-local routes, byte-identity is **not claimed and not tested** — those routes have their own contract: the gate pipeline (§5) defines their safety, and the receipt records their outcome. The M1 golden test (conductor-routed-direct == legacy inject_text) must still pass in M2 for the direct path.

**Required test (G-M2 impl):**
1. The M1 byte-identity test still passes (direct-local through the M2 pipeline == legacy `inject_text`).
2. **Byte-identity for a local turn under `all-available` mode** (MAJOR-2 fix): a turn the policy routes local while the operator is in `all-available` mode must NOT trigger a membrane scan, a budget `check()` store read, or a provisioning lookup — the §5.4/§5.5 no-ops hold, so output + events == M1. (Test 4 covers `pure-local` mode; this test covers the local *route* under the permissive mode, which is the byte-identity hole the review caught.)
3. A cloud-bound prompt containing a credential (`sk-...`) is **blocked** by the membrane and **never reaches** a mock provider (assert the mock received zero calls); the turn degrades to direct-local and the receipt records `PrivacyBlocked`.
4. A cloud-bound prompt that passes the membrane but exceeds the budget cap is blocked at §5.4; the mock provider receives zero calls.
5. A `pure-local` mode operator never triggers a membrane scan or budget check for any turn (all routes are direct-local).
6. **No phantom spend (MINOR-3):** a route blocked at any of §5.2–§5.5 writes no `BudgetUsageRecord` — `record()` is never called on a blocked route.

---

## 7. Reward aggregator (F-10 — reject self-judgment-only)

F-10 forbids a reward signal that is *only* the model judging its own output. The M2 reward aggregator combines **four** signal sources, and **model self-judgment is advisory-only — it can never be the sole source of positive reward**.

```rust
pub struct RewardSignals<'a> {
    routing_score: RoutingScore,          // (1) human-labeled corpus accuracy (WP-D7 ground truth)
    user_signal: Vec<UserSignal>,         // (2) explicit feedback joined from the feedback log (§MAJOR-4)
    outcome_metrics: OutcomeMetrics,      // (3) cost + latency + privacy from RouteReceipt
    self_judgment: Option<SelfJudgment>,  // (4) ADVISORY ONLY — can negative-weight, never sole positive
}
/// Per-candidate reward. f64 scalar in [-1.0, +1.0]; >0 only if a non-self-judgment
/// signal contributes positively. Composition is logged for auditability.
pub fn aggregate_reward(signals: &RewardSignals<'_>) -> Reward;  // Reward is a typed struct { score: f64, components: … } (NOTE-1 fix)
```

1. **Routing accuracy** (primary positive signal) — the D7 `RoutingScore` from the versioned, human-labeled corpus. This is ground truth, not model output.
2. **User signal** — explicit feedback (accept / reject / edit / rating). **Late-arriving** (MAJOR-4 fix): feedback is NOT in the `RouteReceipt` (which is written at turn-end, before feedback exists). It is appended to a separate **feedback log** in the isolated `ConductorStore` (`append_feedback(request_fingerprint, UserSignal)` — a new JSONL `conductor_feedback.jsonl`, keyed by `request_fingerprint`), and `aggregate_reward` **joins** receipts ↔ feedback on fingerprint at scoring time. A user rejection is a strong *negative* signal. *(The UI capture surface — how a tap becomes an `append_feedback` call — is itself M2 wiring but may follow the core plumbing; the store/join side lands first.)*
3. **Outcome metrics** — cost (micros), wall-clock latency, and privacy outcomes (was the route blocked? did it degrade? did it fail mid-call?) from `RouteReceipt`. Lower cost + lower latency + clean privacy = higher reward; a `PrivacyBlocked` degradation or a `success: false` (MINOR-6) is a negative signal.
4. **Self-judgment** (advisory only) — a model's own assessment of output quality. **May contribute a negative weight** ("this output looks wrong") but **may never be the sole source of positive reward.** Enforced in `aggregate_reward`: if signals 1–3 are all absent/neutral, `self_judgment` alone cannot produce a positive reward.

**Two distinct scoring surfaces (MINOR-4 fix):** the **corpus score** (§8) is `RoutingScorer::score` over the fixed, human-labeled corpus — a static, versioned ground-truth measurement. The **reward window** (Q3) is `aggregate_reward` over a rolling N-turn slice of the live shadow log — a live-performance measurement. Promotion uses `is_improvement()` on **corpus scores** (the F-12 gate), not on raw reward; reward is advisory input to a human reviewer deciding whether to promote a flagged candidate. The rolling reward window must be corpus-version-homogeneous with the corpus score it's compared against, or `is_improvement` returns `false` on the version mismatch (inherited from D7).

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
- **Feedback log** (MAJOR-4): a new `conductor_feedback.jsonl` in the isolated store, appended via `ConductorStore::append_feedback(request_fingerprint, UserSignal)`. Joined to receipts on `request_fingerprint` at reward-scoring time (§7). This is the late-arriving-feedback path the append-only store design requires (the receipt itself is written at turn-end, before feedback exists).
- `RouteReceipt.eval_delta` populated from the shadow router's per-turn corpus match (when a corpus entry matches the turn's features).
- `RouteFailure::PrivacyBlocked { level, labels }` and `BudgetExceeded { ... }` in the receipt's `fallback_reason` (structured-only, never the matched secret).

**M2 wiring obligation (carried from WP-D2 reviewer NOTE):** migrate `eprintln!` → `tracing::warn!`/`tracing::info!` for all paths activated in M2 (the §5 pipeline gates, the budget governor, the shadow router). Dormant paths (chain, M3 surfaces) may keep `eprintln!` until activated. This requires adding the `tracing` dep + a subscriber in `main.rs`.

---

## 10. Files touched (M2 implementation, post-spec-approval)

- `crates/fae-daemon/src/conductor/recipe.rs` — rename `WorkerLocality::LocalAcp` → `CloudBackedAcp` (§3.2); no lane-enum change (`CloudBacked` already landed in WP-D2).
- `crates/fae-daemon/src/conductor/executor.rs` — **the §5 gate pipeline**: mode cap, PII membrane call (per-role for chain), budget check/record (with LocalOnly no-ops), approval assertion. Direct arm unchanged (still `inject_text_core` verbatim). Remove the `route_failure_display` arms' `eprintln!` → `tracing`. **MINOR-5 — modify the M1 defense-in-depth gate** (`executor.rs:143 RouteFailure::UnexpectedApproval`): M1 rejects *any* non-`None` approval; M2 must permit `StandingGrant` for provisioned cloud-backed workers while still rejecting `StandingGrant`/`PerTurn` that fail the §5.5 provisioning check. The reject-`None`-on-non-`LocalOnly`-lane defense-in-depth stays.
- `crates/fae-daemon/src/conductor/budget.rs` — add `BudgetLimits::validate()` (`daily_window > Duration::ZERO`); **wire per-worker daily buckets** (§3.1): filter `rolling_cost_micros` by `route.worker_id` + a `HashMap<worker_id, BudgetLimits>` on the governor; `eprintln!` → `tracing`. *(NOTE: real new code — `check()` currently ignores `_route`.)*
- `crates/fae-daemon/src/conductor/pricing.rs` — **NEW** (MAJOR-3): `ProviderPricing { input_micros_per_token, output_micros_per_token }` table + `estimate_cost(worker_id, prompt, max_output_tokens) -> CostEstimate`. Conservative char/4 input heuristic; uncostable worker ⇒ fail-closed. Loaded from operator config at startup.
- `crates/fae-daemon/src/conductor/policy.rs` — `StaticDirectPolicy` stays M1 behavior; add the mode-aware lane eligibility used by §5.2 (pure function over mode + lane).
- `crates/fae-daemon/src/conductor/shadow.rs` — **NEW**: the shadow router (§8). Decision-only; isolated shadow log; promotion-candidate flagging via `is_improvement`.
- `crates/fae-daemon/src/conductor/reward.rs` — **NEW**: the reward aggregator (§7). Four-signal; self-judgment advisory-only enforced in code; feedback-log join on fingerprint.
- `crates/fae-daemon/src/conductor/store.rs` — add `append_feedback(request_fingerprint, UserSignal)` writing `conductor_feedback.jsonl` (MAJOR-4).
- `crates/fae-daemon/src/conductor/workers.rs` — `WorkerRegistry` grows provisioned cloud-backed workers (keyed by credential presence); `local-model` remains always-present.
- `crates/fae-daemon/src/main.rs` — read `FAE_MODEL_MODE` at startup; construct `BudgetGovernor` with the **per-worker limits map** (traced: operator per-worker env/config → `HashMap<worker_id, BudgetLimits>` → `BudgetGovernor::new`); load the `ProviderPricing` table; wire `fae-pii-membrane`; initialize `tracing` subscriber.
- `crates/fae-daemon/Cargo.toml` — add `fae-pii-membrane` (workspace path) + `tracing` + `tracing-subscriber`.

No Swift changes. No `fae.db` writes. No M3 recipe mutation.

---

## 11. Progressive-disclosure copy (extends M1 §11)

M1 is invisible (L0) because direct-local is the only route. M2 adds visible surfaces **only when behavior differs from direct-local**:

- **L1** ("I'm asking Claude/Gemini/Codex") — emitted when a cloud-backed route is *selected and executed* (gates all green). One line, plain, no jargon. Consistent with SOUL.md "head butler."
- **L2** ("I kept this on your Mac — it looked private") — emitted when a route the policy *would have* sent cloud is blocked by the PII membrane and degrades to direct-local. Reassuring, not alarming.
- **L2.5** ("I'd need your go-ahead for that one") — emitted when a Tier C per-turn approval is denied/absent and the route degrades to direct-local (MINOR-2 fix: a user who requested cloud and is silently routed local on a denied approval gets a surface). Reassuring, surfaces the opt-in.
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
6. **Frozen interfaces consumed correctly.** §2's signatures match what landed in WP-D2/WP-D7/PII-membrane (verified as-landed: by-value store, `max_*` fields, `daily_window: Duration`, two-arg `should_persist_proactive_observation`).
7. **M2 wiring obligations captured.** The two carried WP-D2 MINORs (daily_window validation, eprintln→tracing) are §5.4/§9 items.
8. **CostEstimate provenance specified** (MAJOR-3): §5.4 names the pricing source + the uncostable⇒fail-closed rule; §10 lists the pricing module.
9. **user_signal temporal-write resolved** (MAJOR-4): §7/§9 specify the late-arriving feedback append + the aggregator join (not a structurally-None field).
10. **LocalOnly hot-path no-op guaranteed** (MAJOR-2): §5.4/§5.5 are no-ops for `lane == LocalOnly` under any mode; §6 test 2 covers the all-available-local hole.

## 13. G-M2 impl acceptance criteria (for `reviewer`, post-impl)

The impl review passes when:
1. **No-egress-on-failure:** tests prove a blocked membrane/budget/approval/mode route sends zero calls to any mock provider and degrades to direct-local (§6 tests).
2. **Byte-identity for direct-local:** the M1 golden test still passes through the M2 pipeline — under both `pure-local` mode AND a local route under `all-available` mode (§6 test 2, MAJOR-2).
3. **Per-role membrane (chain):** a chain to a cloud mock is blocked if any of Thinker/Worker/Verifier prompts fail the membrane (chain stays off, but the test exercises the gate).
4. **F-10 enforced:** a unit test proves `aggregate_reward` with only `self_judgment` (signals 1–3 absent) yields non-positive reward.
5. **Shadow is decision-only:** a test proves a shadow candidate's decision is computed and scored but zero provider calls occur; the shadow log lands in the isolated store.
6. **Mode cap:** `pure-local` mode blocks all non-local routes at §5.2 before any membrane scan.
7. **Per-worker budget:** two provisioned providers have independent daily caps; exhausting one does not block the other.
8. **Uncostable ⇒ fail-closed (MAJOR-3):** a route targeting a `worker_id` with no pricing entry is blocked at §5.4 (no egress) — the cap cannot be bypassed by misconfiguration.
9. **Feedback-join (MAJOR-4):** a late `append_feedback` row joins to its receipt on `request_fingerprint` inside `aggregate_reward`; a user-rejection signal lowers the reward.
10. **No phantom spend (MINOR-3):** a route blocked at §5.2–§5.5 writes no `BudgetUsageRecord`; a partially-billed failed call DOES record `ActualCost` with `success: false` (MINOR-6).
11. **M1 executor gate updated (MINOR-5):** `StandingGrant` for a provisioned cloud-backed worker is permitted (not `UnexpectedApproval`); `StandingGrant`/`PerTurn` without provisioning still rejects; `None`-on-non-`LocalOnly` still rejects.
12. **Panic-free + gates:** `cargo clippy -p fae-daemon -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used` clean; fmt + `cargo check --workspace --all-targets` + `cargo test -p fae-daemon` all green.

---

## 14. Open questions for G-M2-spec re-review

- **Q1 (per-worker budget shape):** is `per_worker_limits: HashMap<worker_id, BudgetLimits>` on `BudgetGovernor` the right home, or a separate map passed at construction? Lean: map on the governor, keyed by worker_id; default `BudgetLimits` for un-listed workers (so adding a provider without explicit caps still has a ceiling). The config→map→governor data flow is traced in §10. Reviewer to confirm.
- **Q2 (Tier C approval surface) — refined:** §4 now states Tier C lanes are eligible-but-fail-closed-unimplemented in M2 (MINOR-1). The question reduces to: does M2 need *any* Tier C path (the per-turn approval event), or is fail-closed-to-direct-local sufficient until a provider-metadata ADR (MAJOR-5) lands? Lean: fail-closed suffices for M2; the first real Tier C user (a trusted peer, M4) is the trigger to wire the approval surface. Reviewer to confirm.
- **Q3 (reward window):** over what window does `aggregate_reward` score (per-N-turns? time-bounded? on-demand)? Lean: on-demand at promotion-check time, over a fixed-N-turn rolling window in the shadow log, corpus-version-homogeneous with the corpus score (MINOR-4). Reviewer to confirm.
- **Q4 (per-provider retention) — deferred, not open:** M2 models all `CloudBacked` providers at one trust tier (§3.1, MAJOR-5). Per-provider retention/training differentiation is deferred to a provider-metadata ADR / M4. Recorded here so the re-review can confirm the deferral is acceptable, not to decide it in M2.

---

## 15. Staged landing / cutover discipline (M2 wiring)

**This is the first change in the conductor track that makes cloud egress *reachable* from the executor.** Before it, a gate-ordering bug is harmless (the executor cannot reach a cloud provider); after it, the same bug silently exfiltrates user data. That risk asymmetry is why the wiring lands staged, not as a land-and-flip-default — exactly like a daemon-playback cutover.

**The hard rule:** "the egress wiring works" and "cloud egress is on by default for every user" MUST be different commits, separated by a security review gate.

### Stage 1 — Wiring behind a flag, `pure-local` runtime default
Land the §5 egress pipeline end-to-end, with `FAE_MODEL_MODE` **defaulting to `pure-local`** (so cloud egress is reachable only by explicit operator opt-in). Stage 1 scope is deliberately **narrow** — only what proves the egress path is safe:
- `FAE_MODEL_MODE` parsing (default `pure-local`).
- `WorkerLocality::LocalAcp` → `CloudBackedAcp` rename (§3.2).
- Mode cap (§5.2), PII membrane **before any cloud-bound request is constructed** (§5.3, per-role for chain), budget check/record around each cloud call (§5.4/§5.7), Tier B approval assertion for provisioned workers (§5.5).
- The `pricing.rs` `CostEstimate` module (§5.4) — required, the budget gate depends on it.
- `PrivacyBlocked` / `BudgetExceeded` → fail-closed-to-direct (§5.3/§5.4).
- The M1 executor `UnexpectedApproval` gate modified to permit provisioned `StandingGrant` (§10 MINOR-5).

**Deferred out of Stage 1** (to keep the security-review surface minimal): the reward aggregator (§7) and the shadow router (§8). They do not touch the egress path and are not needed to prove egress safety; they land in a later M2 substage after Stage 2 clears.

**Stage 1 acceptance (must land before Stage 2):**
1. **The membrane-before-construction invariant, as a test that fails on reordering.** Cloud-request construction MUST be a separable, spy-able boundary (e.g. a `CloudRequestBuilder` trait or dedicated function — NOT inlined). The test uses a **credential-bearing prompt**, the **real `fae-pii-membrane`**, a spy request-builder, and a mock provider; it asserts the spy request-builder is invoked **zero times** AND the mock provider is invoked **zero times**. If a future change reorders the gates to build-the-request-then-check, this test fails (builder call count ≥ 1). This is stronger than asserting "provider not called" — it catches construction-before-check, which is the dangerous ordering even if the provider call is later skipped.
2. Per-role membrane test for chain (§13.3): a chain to a cloud mock is blocked if any of Thinker/Worker/Verifier fails the membrane.
3. Byte-identity for direct-local holds under `pure-local` default (§6 test 1) AND for a local route (§6 test 2).
4. The default is verifiably `pure-local`: a fresh process with `FAE_MODEL_MODE` unset routes every turn direct-local and constructs zero cloud requests.
5. Standard gates: fmt + `cargo check --workspace --all-targets` + strict clippy + `cargo test -p fae-daemon` green.

### Stage 2 — Egress-security review (gate)
Fresh-context **`red-team`** review focused exclusively on the egress-critical path: membrane-before-construction, `pure-local` default, no bypass around mode/budget/approval, per-role chain egress, no telemetry/user-text leakage, the spy-test genuinely fails-on-reorder. **Required: zero BLOCKER / zero MAJOR before merge to main and before any default-cutover discussion.** A normal `reviewer` pass may follow but `red-team` is the required gate for the egress surface.

### Stage 3 — Separate gated cutover to `all-available` default
Only after Stage 1 is merged AND Stage 2 clears: a **separate** change flips the `FAE_MODEL_MODE` default from `pure-local` to `all-available`, gated by the **release-validation contract** (`docs/checklists/app-release-validation.md` + `docs/checklists/main-and-cowork-live-test-scenarios.md`). This is its own commit, its own review, its own gate — never bundled with the wiring landing. Until Stage 3, cloud egress is opt-in (`FAE_MODEL_MODE=all-available` or `local-symphony`), not default.

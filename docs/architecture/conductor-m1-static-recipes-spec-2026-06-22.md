# M1 — Static Recipes Spec (Learned Conductor)

- **Status:** DRAFT v2 — for G-M1-spec re-review. v1 FAILED (1 BLOCKER B1, 3 MAJOR M1/M2/M3); all four folded in here plus 4 MINORs.
- **Date:** 2026-06-22
- **Supersedes:** none. Builds on ADR-011 and the M0b scaffolding (`crates/fae-daemon/src/conductor/`).
- **Parent plan:** `docs/plans/fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md`
- **Decisions locked upstream:** F-3 (`direct` default, `chain` opt-in), F-4 (fingerprint = HMAC of `request_id`), F-7 (tiered autonomy; Tier A only in M1), F-15 (topology enum: Direct/Chain only, serde fail-closed).
- **v1 review findings addressed:** B1 (byte-identical must be "same code path," not "same ChatRequest"); M1 (classify is content-blind — no chain signal read); M2 (fingerprint computed in executor, not policy); M3 (`FAE_CONDUCTOR_CHAIN` env var, not a nonexistent config file); m1 (`RecipeSet` home + resolution); m2 (telemetry spawn_blocking); m3 (`MeshDeferred` is M4, unreachable in M1); m4 (§5.1 resolved: fail-closed-to-direct + startup warning).

---

## 1. Goal & scope

M1 makes the conductor **present** in the turn loop with **zero behavior change** for the default path, plus passive route telemetry. It ships the routing/execution seams that M2 (reward + shadow) and M3 (MetaOpt mutation) build on.

**In scope (M1):**
- A synchronous, side-effect-free `ConductorRoutingPolicy` trait with one impl: `StaticDirectPolicy`.
- An async `ConductorExecutor` that runs the chosen route.
- `direct` topology: **runs `inject_text`'s existing body verbatim** (same code path — events, NaN-retry, `run_turn`).
- `chain` topology: Thinker → Worker → Verifier, **opt-in only** (`FAE_CONDUCTOR_CHAIN`), role-conditioned system prompts.
- Passive telemetry: one `ConductorRouteEvent` at decision time, one `RouteReceipt` after execution, written to the isolated `ConductorStore` (never `fae.db`).
- Progressive-disclosure copy (L0/L1/L4) — *non-requirement in M1* (no non-direct route is active).

**Out of scope (deferred):**
- Remote API / x0x peers (M2 Tier B/C, M4).
- Reward aggregation, `routing_accuracy` eval, shadow routing (M2).
- MetaOpt mutation / candidate recipes (M3).
- Mesh delegation (M4). `MeshDeferred` is **unreachable in M1** — the M1 policy never emits it.

---

## 2. Injection seam — `inject_text` only

The conductor hooks into **exactly one** place: `inject_text` (`session.rs:1231`), dispatched via `"conversation.inject_text"` (`session.rs:331`). This is the single primary path where a user text prompt becomes a model turn.

**The conductor must NOT wrap `run_turn` itself.** `run_turn` is a shared engine primitive also used by:
- ASR transcription fallback (`session.rs:1342`)
- The NaN-logits retry loop (`session.rs:1286`) — *inside* `inject_text`
- Offline turn harness (`offline_turn.rs:164/192/216`)

Wrapping `run_turn` would route ASR/transcription/retry turns through the conductor — wrong, and would pollute telemetry with non-conversational turns.

**Concrete wiring:** `inject_text` gains an optional `&ConductorRoutingPolicy` + `&ConductorExecutor` + `&ConductorStore` (passed via `SessionBackends`). The flow becomes:

```
inject_text(cmd)
  → build ConductorTurnContext (owned; request_id from cmd)
  → policy.decide(&ctx)  → OwnedRouteDecision            [sync, pure, infallible]
  → executor.emit_event(decision)                         [telemetry: spawn_blocking]
  → executor.run(decision, backends) → TurnResult          [async]
  → executor.emit_receipt(decision, turn_result)           [telemetry: spawn_blocking]
```

**ACP path note:** `agent_prompt_inner` (the local-ACP path) is a *separate* command (`agent.prompt`) and is **not** wrapped in M1. M1's `direct` route always uses the local model via `inject_text`'s body. ACP workers are only selected by an explicit static recipe (§6.2), never by default.

---

## 3. Type refactor: owned route decision (M0b → M1)

The M0b `ConductorRouteDecision<'a>` borrows `&'a FaeConductorRecipe` and `&'a WorkerSelector`. That fights the async executor (the decision would have to outlive an `.await`). **M1 makes the decision owned**, carrying lightweight identifiers the executor resolves at execution time (fixes v1 M2 — the policy stays pure and infallible, and the fingerprint is computed in the executor, not the policy):

```rust
/// The conductor's decision for one turn. OWNED — safe to move across `.await`.
/// The executor resolves `recipe_id`/`worker_id` against the loaded recipe set
/// and worker registry, and computes the request fingerprint (HMAC of
/// `request_id` under the install key — F-4) during execution.
#[derive(Debug, Clone)]
pub struct OwnedRouteDecision {
    pub request_id: String,             // opaque; executor HMACs it into the fingerprint
    pub recipe_id: String,
    pub topology: ConductorTopology,    // Direct | Chain only (F-15)
    pub worker_id: String,              // resolves to a WorkerSelector
    pub task_class: ConductorTaskClass,
    pub approval: ApprovalClass,        // ApprovalClass::None in all of M1 (F-7 Tier A)
    pub reason: String,                 // short, static, audit-safe ("static-direct-local")
}

/// Failure to route — executor fails closed to direct-local and logs.
pub enum RouteFailure {
    RecipeDisabled { recipe_id: String, reason: String },   // chain flag off, etc.
    WorkerUnavailable { worker_id: String },
    InvalidRecipe { recipe_id: String },
}
```

The legacy borrowed `ConductorRouteDecision<'a>` enum is **removed** (it was never wired; M0b only). `FallbackLocal` becomes an executor `TurnResult` variant (§5), not a decision.

---

## 4. `ConductorRoutingPolicy` trait

```rust
/// Pure, synchronous, side-effect-free, INFALLIBLE. Decides a route from
/// context alone. Computes nothing that can fail (no I/O, no HMAC) and touches
/// no install key. Async, I/O, and fingerprinting live in the executor.
pub trait ConductorRoutingPolicy: Send + Sync {
    fn decide(&self, ctx: &ConductorTurnContext) -> OwnedRouteDecision;
}
```

- **Sync and infallible on purpose.** The decision is pure logic over context. Keeping it sync + infallible means it cannot touch the network, the engine, the store, or a CSPRNG, and it cannot hold a borrow across `.await`. (v1 M2 fix: the policy no longer computes the fingerprint, so `decide()` can be infallible without a panic-safety violation.)
- `ConductorTurnContext` is built **owned** from `cmd` (no borrows into the command) so it can be moved freely. The M0b `&'a str` fields become `String`.

### 4.1 `StaticDirectPolicy` — M1's only impl

```rust
pub struct StaticDirectPolicy {
    recipe: StaticRecipeConfig,   // the single M1 recipe (direct, local-model)
    // NOTE: no install_key here (v1 M2 fix). Fingerprinting is the executor's job.
}
```

M1 behavior of `decide()`:
1. `task_class = classify(metadata)` — coarse classifier over **non-content metadata only** (e.g. presence of tools, session flags). **The policy is content-blind: it does not read prompt text at all.** (v1 M1 fix: the "chain opt-in signal" clause is deleted; chain is purely config-gated per §7, never read from the prompt.)
2. Always returns `direct` + the local-model worker + `ApprovalClass::None`.
3. `reason = "static-direct-local"`.

There is no per-turn variation in M1. The policy exists so M3 can swap impls without touching the wiring.

---

## 5. `ConductorExecutor` (async)

```rust
pub struct ConductorExecutor<'a> {
    engine: &'a dyn ProviderAdapter,
    recipes: &'a RecipeSet,        // id → FaeConductorRecipe
    workers: &'a WorkerRegistry,   // id → WorkerSelector (vetted; §6.2)
    store: &'a ConductorStore,
    install_key: &'a InstallKey,   // computes the request fingerprint (F-4)
    chain_enabled: bool,           // FAE_CONDUCTOR_CHAIN, read once at startup (§7)
}
```

Execution rules:

### 5.1 `direct` — runs `inject_text`'s existing body (B1 fix)

The `direct` arm does **not** build a `ChatRequest` and call `run_turn`. That would drop the `assistant.generating` event pair and the NaN-logits retry loop that `inject_text` performs today — a real behavior regression.

Instead, M1 **extracts `inject_text`'s ENTIRE current body into a reusable `inject_text_core(backends, cmd) -> Result<Value, &'static str>`** — including the leading `FAE_DUMP_REQUESTS` block, the parse, the `assistant.generating {active:true}` publish, the NaN-retry pad loop, the retry loop's internal `run_turn` calls, and the exactly-once `assistant.generating {active:false}` publish on all return paths. The conductor's `direct` arm calls `inject_text_core` **verbatim**. Byte-identical is then *truly* by construction: one implementation, called from two entry points.

`inject_text` itself becomes:
```rust
async fn inject_text(backends, cmd) -> Result<Value, &'static str> {
    let ctx = build_turn_context(&cmd);
    let decision = backends.conductor_policy.decide(&ctx);
    backends.conductor_executor.emit_event(&decision).await;   // spawn_blocking, isolated JSONL
    let result = backends.conductor_executor.run(&decision, backends, &cmd).await;
    backends.conductor_executor.emit_receipt(&decision, &result).await;  // spawn_blocking
    result
}
```

**Wire type (N2 clarification — protects the B1 fix):** `inject_text`'s return type is fixed by the dispatch contract (`"conversation.inject_text" => inject_text(backends, cmd).await` at session.rs:331) as `Result<Value, &'static str>`. For the `direct` arm, `run()` returns `inject_text_core`'s `Result<Value, &'static str>` **verbatim**. `TurnResult` (§5.4) is the executor's **internal bookkeeping** for the receipt (`fallback`, `latency_ms`, verifier-overrides) — it is never round-tripped through `Value → TurnResult → Value`, which would re-serialize the payload and break byte-identity. In M1 the direct path is literally `run() = inject_text_core(...)`; `TurnResult` only materializes for `chain`/`fallback`.

### 5.2 `chain` — opt-in, three-role

Only if `decision.topology == Chain && self.chain_enabled`. Otherwise fail-closed to direct (§5.3). Three `run_turn` calls with role-conditioned prompts (§6.1), fed Thinker→Worker→Verifier. On `FAIL`, emit the corrected answer if present, else Worker's answer; log the verifier override in the receipt.

### 5.3 Failure recovery (RouteFailure) — always fail closed to direct

If recipe/worker resolution fails, or `chain` is requested but `chain_enabled` is false: **never abort the turn.** Recover by calling `inject_text_core` (direct-local), emit a `RouteReceipt` with `fallback = true` and the failure reason, and continue. The user is never blocked by the conductor.

**§5.1 chain-gate failure mode — DECIDED (v1 §5.1 resolved, reviewer judgment accepted):** fail-closed-to-direct. Chain is off-by-default and purely additive (F-3); rejecting a user turn over a not-even-enabled feature's config mismatch is worse UX than silent fallback; the receipt's `fallback=true` flag preserves auditability. **Addition:** emit a **startup-time `eprintln` warning** if any loaded recipe specifies `Chain` while `chain_enabled` is false, so misconfiguration is visible without blocking any turn.

### 5.4 Recipe/worker resolution

```rust
pub enum TurnResult {
    Direct { text: String, tool_calls: Vec<Value>, finish_reason: String },
    Chain { thinker: RoleResult, worker: RoleResult, verifier: RoleResult, final_text: String },
    FallbackLocal { reason: String, text: String },   // RouteFailure recovered
}
```

Resolution order in `run()`:
1. Look up `decision.recipe_id` in `recipes` (`RecipeSet`, §12). Miss → `RouteFailure::InvalidRecipe` → fail-closed direct (§5.3).
2. Look up `decision.worker_id` in `workers` (`WorkerRegistry`, §6.2). Miss → `RouteFailure::WorkerUnavailable` → fail-closed direct.
3. If `recipe.topology == Chain` and `!chain_enabled` → `RouteFailure::RecipeDisabled { reason: "chain-disabled" }` → fail-closed direct.

---

## 6. Prompts & workers

### 6.1 Role-conditioned prompts (chain only)

A new `conductor::prompts` module with three `&'static str` system-prompt constants:

- `THINKER_SYSTEM` — "Decompose the user's request into 1–3 concrete sub-tasks. Output only the decomposition."
- `WORKER_SYSTEM` — "Solve the following sub-task. Output only the answer."
- `VERIFIER_SYSTEM` — "Check the answer against the original request. Output `PASS` or `FAIL: <one-line reason>`; if FAIL, the corrected answer."

Chain execution feeds Thinker's output into Worker's input, Worker's into Verifier's. **Chain is opt-in and off by default** — these prompts ship but are dormant until `FAE_CONDUCTOR_CHAIN` is set.

### 6.2 Worker registry — vetted, never arbitrary

The `WorkerRegistry` is an explicit, hard-coded-at-compile-time list for M1. The static policy may **only** select workers from this list. It must never auto-discover or route to arbitrary ACP sessions.

M1 registry:
- `local-model` → the daemon's loaded `ProviderAdapter` (mistral.rs / llama.cpp). Always present.
- (No ACP workers in the M1 registry by default. Adding a vetted local ACP worker is an explicit code change, not a runtime discovery.)

If `decision.worker_id` is not in the registry → `RouteFailure::WorkerUnavailable` → fail closed to `direct`-local.

---

## 7. Chain feature flag — `FAE_CONDUCTOR_CHAIN` (F-3 enforcement, v1 M3 fix)

The daemon has **no config-file system** — every runtime knob is a `FAE_*` env var (`env_parsed`/`std::env::var` in `main.rs`, verified). So chain gating uses an env var, not a config key:

- **Recipe-level:** `FaeConductorRecipe.topology == ConductorTopology::Chain`.
- **Runtime flag:** env var `FAE_CONDUCTOR_CHAIN` (any of `1`/`true`/`yes` → enabled; **unset or anything else → false, the default**), read **once at daemon startup** via the existing `env_parsed` pattern.

Both required for `chain` to execute (belt-and-suspenders, F-3). Changing the flag requires a restart — simple, auditable, no hot-reload footgun in M1.

---

## 8. The M1 safety contract: `direct` is the same code path

The single most important M1 property: **with `FAE_CONDUCTOR_CHAIN` unset (the default), the conductor changes no user-visible behavior.** A turn routed through the conductor produces the same model output, the same `assistant.generating` event pair, and the same NaN-retry behavior as today's `inject_text`.

Provable by construction (v1 B1 fix):
- `StaticDirectPolicy` always returns `direct` + `local-model` + `ApprovalClass::None`.
- The executor's `direct` arm calls **`inject_text_core`** — the *same extracted body* `inject_text` runs today (events + NaN-retry + `run_turn`). Not a re-implementation.
- Telemetry writes are best-effort (§9) and never fail the turn.

**Test (required for G-M1 impl review):** a golden test that captures `inject_text` output (text + the `assistant.generating` event sequence) pre-conductor and post-conductor (conductor wired, `FAE_CONDUCTOR_CHAIN` unset) and asserts equality — including that a NaN-triggering request still recovers via the retry loop in both paths. Plus a property test that `StaticDirectPolicy::decide()` always returns `direct` + `local-model` + `ApprovalClass::None` for any context.

---

## 9. Telemetry (passive, isolated, non-blocking-on-turn)

Per turn, two records to the `ConductorStore` (JSONL, 0700, separate from `fae.db`):

1. **`ConductorRouteEvent`** — at decision time (before execution). Fields: `request_fingerprint` (computed in the executor = HMAC of `cmd.request_id` under the install key — F-4), `recipe_id`, `topology`, `task_class`, `worker_id`, `approval`, `decided_at_ms`. **No prompt text, no model output.**
2. **`RouteReceipt`** — after execution. Fields: `request_fingerprint`, `latency_ms`, `success`, `fallback`, `fallback_reason`, `payload_hash` (SHA-256 of the outbound payload — not the user's input), `eval_delta = None` (M2), `user_signal = None` (M2). **No prompt text, no model output.**

**Non-blocking guarantee (v1 m2 fix):** `ConductorStore::append_*` is synchronous std::fs. The executor wraps each telemetry write in **`tokio::task::spawn_blocking`** and makes the receipt write best-effort (a write error is logged to stderr and swallowed — a broken telemetry store must never break a user turn). If the M1 executor turns out to be single-turn-per-process in practice, a tracked `// TODO(M2)` to relax `spawn_blocking` may be added, but the default is non-blocking.

**Fingerprint-failure handling (N4 clarification):** `emit_event` computes `install_key.fingerprint(&request_id)`. That call is typed `Result<RequestFingerprint, ConductorError>` (unreachable for a 32-byte key + SHA-256, but typed fallible to stay panic-free). On the `Err` arm, `emit_event` logs the error to stderr and **skips the event** (no receipt either) — consistent with the best-effort contract. The turn itself is unaffected; only the telemetry row is dropped.

The M0b doc invariant on `eval_delta`/`user_signal` (no query content) carries forward to M2.

---

## 10. Approval assertion (F-7 Tier A)

M1 emits `ApprovalClass::None` for **every** route. No approval surface exists. Enforced by:
- `StaticDirectPolicy` hard-codes `approval: ApprovalClass::None`.
- A unit test asserting `decide(ctx).approval == ApprovalClass::None` for all M1 contexts.
- The executor treats a non-`None` approval in M1 as a `RouteFailure` (defense-in-depth; should be unreachable) rather than executing it.

Tier B (`StandingGrant`) and Tier C (`PerTurn`) are M2.

---

## 11. Progressive-disclosure copy

When the route is `direct`-local (the M1 default), the conductor is **invisible** (L0) — no UI copy, no announcement. This preserves SOUL.md's "head butler" identity.

Copy is only surfaced when behavior *differs* from direct-local:
- **L1** ("I'm asking your Mac") — reserved; not emitted in M1 since chain is off by default.
- **L4** (opt-in team view) — a future settings surface; not built in M1.

For M1 this section is effectively a **non-requirement**: because `direct`-local is the only active route, no copy is emitted. The copy templates are specified here so M2 (chain-on) and M4 (mesh) don't redesign them. *No new UI surfaces in M1.*

---

## 12. Files touched (M1 implementation, post-spec-approval)

- `crates/fae-daemon/src/conductor/mod.rs` — add policy/executor re-exports; **remove `#![allow(dead_code)]`** (N3: the conductor is now wired, so dead-code is a real signal again; removal is an M1 acceptance item, §13.7)
- `crates/fae-daemon/src/conductor/recipe.rs` — remove borrowed `ConductorRouteDecision<'a>`; add `OwnedRouteDecision`, `RouteFailure`, `ConductorTurnContext` (owned); add `RecipeSet` (id → `FaeConductorRecipe`, v1 m1 fix)
- `crates/fae-daemon/src/conductor/policy.rs` — **NEW**: `ConductorRoutingPolicy` trait + `StaticDirectPolicy` (no `install_key`)
- `crates/fae-daemon/src/conductor/executor.rs` — **NEW**: `ConductorExecutor`, direct arm = `inject_text_core` call, chain arm, telemetry emission (spawn_blocking), recipe/worker resolution
- `crates/fae-daemon/src/conductor/prompts.rs` — **NEW**: role system-prompt constants (dormant)
- `crates/fae-daemon/src/conductor/workers.rs` — **NEW**: `WorkerRegistry` (vetted, `local-model` only in M1)
- `crates/fae-daemon/src/session.rs` — **extract `inject_text_core` from `inject_text`**; wire conductor into `inject_text` via `SessionBackends`; build `ConductorTurnContext` from `cmd`
- `crates/fae-daemon/src/main.rs` — read `FAE_CONDUCTOR_CHAIN` at startup; construct `StaticDirectPolicy` + `ConductorStore` + `InstallKey` + **`RecipeSet` (the one direct-local recipe)** + **`WorkerRegistry` (the `local-model` entry)** that `ConductorExecutor` borrows; emit startup warning if a chain recipe is loaded while `chain_enabled` is false
- `crates/fae-daemon/Cargo.toml` — no new deps expected (M0b added what's needed)

No Swift changes. No `fae.db` writes (the daemon has no `fae.db` today; the guard is a forward-looking invariant). No remote/network code.

---

## 13. G-M1 (impl) acceptance criteria

The impl review (`reviewer`) passes when:
1. **Byte-identical direct:** golden test proves `direct` output + `assistant.generating` event sequence + NaN-retry recovery all equal pre-conductor behavior (v1 B1 fix — tests the whole code path, not just `run_turn`).
2. **`direct` is default:** `FAE_CONDUCTOR_CHAIN` defaults to unset/false; without it, no chain turn ever runs.
3. **Local/ACP-only:** no code path can select a non-local worker (registry is compile-time `local-model`-only).
4. **Approval Tier A:** every decision is `ApprovalClass::None`; test asserts it.
5. **Telemetry isolation:** events/receipts land in `ConductorStore` JSONL, never `fae.db`; store failures don't break turns (best-effort + spawn_blocking).
6. **F-4:** fingerprint is HMAC of `request_id`, computed in the executor; grep-proven no prompt text is hashed/logged.
7. **Panic-free:** `cargo clippy -p fae-daemon -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used` clean.
8. **Gate:** fmt + `cargo check --workspace --all-targets` + clippy + `cargo test -p fae-daemon` all green.

---

## 14. Open questions for G-M1-spec re-review

- **None.** v1's only flagged open question (§5.1 chain-gate failure mode) is resolved: fail-closed-to-direct + startup warning (reviewer judgment accepted). If the re-review raises new ones, address before impl.

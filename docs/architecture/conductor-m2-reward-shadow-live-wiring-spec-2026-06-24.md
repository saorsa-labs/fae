# M2 Reward/Shadow Live Wiring — Spec

- **Status:** v3 — oracle re-review PASS (zero BLOCKER/MAJOR); **owner-approved 2026-06-24 (Stage A green-lit)**; §8 questions locked as decisions; §2.6 classifier-critical-path note added.
- **Date:** 2026-06-24
- **Owner:** David Irvine
- **Author:** orchestrator
- **Predecessors:** [M2 reward/eval/shadow spec](conductor-m2-reward-eval-shadow-routing-spec-2026-06-23.md) (§7 reward aggregator, §8 shadow router — both COMMITTED DORMANT); [execution plan M3 Sequencing](../plans/fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md#sequencing); [egress-scope §0](egress-scope-and-stage3-hold-2026-06-23.md); [ADR-012](../adr/012-local-first-coordinator-of-external-ais.md); [ADR-008a](../adr/008a-conductor-recipe-surface-amendment.md).
- **What this is:** The prerequisite that unblocks M3 — wire the dormant M2 reward aggregator (§7) and shadow router (§8) into the **live local turn loop**, so the conductor accrues a real reward signal on actual turns. **Local turns only.** Not the Stage-3 cloud-egress cutover.

> **Process rule:** spec → oracle review → implement → oracle + reviewer review. This is the spec; nothing is implemented yet.

> **v3 changelog (oracle review `dc9d3065`, CONDITIONAL FAIL → fix):** **MAJOR-1** (§2.5 factual error, source-verified): routing matches **zero** entries, not one — `match_corpus_entry` requires the entry's `feature_predicates ⊆ ctx.feature_predicates`; the `unknown` entry carries 3 predicates, `ctx` carries `[]`, so `.all()` is false for every entry ⇒ `corpus_match = None` always. (The v2 "matches one degenerate entry" was wrong — subset direction reversed.) V4b updated. **MAJOR-2** (missing impl step): `fae-control-plane/src/lib.rs::required_scopes()` denies any unknown command as `UnknownCommand` *before* dispatch; both new commands must be registered there (§3.2, §4.3, §7). **MINOR-1** (§2.2a): `ShadowRouter.deployed` changed to `Arc<dyn ConductorRoutingPolicy>` (no `Arc→Box` blanket impl). **MINOR-2** (§4.2): synthesized `RoutingScore` is for `aggregate_reward` only — never `is_improvement()` (empty `case_outcomes`). Q4 closed (`StatusRead` confirmed).
>
> **v2 changelog (advisor pressure-test):** (1) feedback command is **payload-based** (`target_request_id`) — `cmd.request_id` is the feedback RPC's own id, not the prior turn. (2) "Rejects user text" narrowed to the *persisted record* + strict payload validation (`deny_unknown_fields`); the raw frame still enters the audit log by design. (3) Reward snapshot routing component derives from the **live shadow window**, not a static corpus re-score; static corpus score returned as baseline metadata only. (4) Honest limitation: routing-accuracy is **degenerate this milestone** (F-4 content-blindness ⇒ `task_class::Unknown`); outcome + user signals are the real accruals. (5) Shadow capture uses a pure `evaluate_record` + `spawn_telemetry` append — **no synchronous file I/O on the hot path**. (6) Deployed policy shared as `Arc<dyn ConductorRoutingPolicy>` between live routing and shadow baseline — no divergence. (7) Commands are **authenticated control-plane**, not diagnostic-only; explicit scope mapping. (8) Tests prefer join-correctness over brittle HMAC-counting; grep gates concrete.

---

## §0. Why this, why now

M3 (self-mutation of routing recipes) optimizes against a **reward signal**. That signal is produced by the M2 reward aggregator (§7) over the shadow router's live window (§8). Both are **committed but dormant** — `#[allow(dead_code)]`, zero call sites from the live turn loop (verified: `grep aggregate_reward|ShadowRouter crates/fae-daemon/src/` returns only re-exports + store seams). Building self-mutation on a conductor producing no reward data is "building the roof before the walls" (M3 Sequencing decision).

This spec makes the conductor **observable**: every local turn accrues outcome metrics (from the existing receipt stream) and, via a new feedback command, explicit user signal. The shadow/reward **plumbing** is put in place so that when a content-aware task classifier later lands, routing-accuracy ground truth accrues with no further wiring (see §2.5 for why it is degenerate today). None of this is auto-promotion; all of it is the signal M3 will later learn from. It is **lower-risk than M3** (no mutation surface, no config writes) and **independent of the Stage-3 cloud decision** (pure-local stays the default; cloud egress stays opt-in).

---

## §1. Scope

### In scope

1. **Per-turn shadow capture** in the live turn loop (the core prerequisite).
2. A **`read_receipts` store seam** so outcome metrics derive from the existing receipt stream.
3. A **`conversation.feedback` control-plane command** so explicit user signal (accept/reject/edit/rating) can enter the reward.
4. An **advisory reward snapshot read** (`conductor.reward_snapshot`) on the authenticated control-plane, so a human/team can consume the accrued signal.
5. Lifting the **F-4 fingerprint** to compute once per turn and thread to event/receipt/shadow/feedback (today each emitter computes it privately).

### Hard constraints (carry over from M2 + ADRs)

- **Local turns only.** No Stage-3 cloud-egress cutover. `pure-local` remains the default; cloud egress stays opt-in (`FAE_MODEL_MODE`). Reward collection is *observation*, not a new egress surface.
- **The M2 §5 gate pipeline keeps authority.** Shadow capture is a side-channel observation; it does **not** run on the execution path and does **not** touch the mode-cap → membrane → budget → approval → worker → record order. Execution still goes through `route_turn → run()` unchanged.
- **Storage isolation.** Everything written — shadow records, feedback, receipts — lives in the **isolated conductor JSONL store** (`conductor/`), never in `fae.db` / personal memory.
- **F-4 fingerprint authority stays with the executor's `InstallKey`.** Shadow records and feedback join receipts on `request_fingerprint`. No emitter derives its own correlation key.
- **Content-blindness of the routing policy is a load-bearing invariant** (`policy.rs`: "no prompt text is read"). This milestone does **not** introduce a content classifier. Consequence stated honestly in §2.5.
- **F-10 (self-judgment advisory-only)** is already enforced structurally + mutation-tested in `aggregate_reward`; this wiring must not weaken it. `SelfJudgment` is passed `None` this milestone.
- **No new egress seam.** Adding a `ShadowRouter` field to `ConductorRuntime` introduces only a shared `Arc<dyn ConductorRoutingPolicy>` + a `ConductorStore` — no `CloudProvider`/`AcpAgentRunner`/request-builder.

### Out of scope (deferred)

- **Any candidate recipes / M3 mutation.** The shadow router ships with **zero candidates**. Candidates + promotion land in M3 (ADR-008a-gated).
- **Auto-promotion.** The reward snapshot is advisory; promotion is a human act.
- **A content-aware task classifier** (the prerequisite for *meaningful* routing accuracy — see §2.5). Separate future milestone; touches the content-blind boundary.
- **`SelfJudgment` capture** (advisory-only by F-10; needs a model self-assessment call).
- **Implicit user signal** (praise/correction/abandonment heuristics). Explicit feedback only.
- **A team-view UI / dashboard.** The reward snapshot returns JSON; rendering is a client concern.
- **Wiring `fae-metaopt` into the daemon.** Forbidden until the BLOCKER-1 denylist exists. This spec does not touch `fae-metaopt`.

---

## §2. Stage A — Per-turn shadow capture + fingerprint lift + `read_receipts`

This is the hard M3 prerequisite.

### §2.1 Fingerprint lift (mechanical, behavior-preserving)

Today `emit_event` and `emit_receipt` each compute `install_key.fingerprint(&decision.request_id)` privately (executor.rs:816–880). Two emitters ⇒ two HMACs for the same request_id.

**Change:** `route_turn` computes the fingerprint **once** and threads it to `emit_event` / `emit_receipt` / shadow. Concretely, add `emit_*_with_fp(...)` internals taking a pre-computed `RequestFingerprint`; on fingerprint failure, log + skip telemetry exactly as today. Byte-identity of the user-visible result is unchanged — telemetry is fire-and-forget.

### §2.2 Per-turn shadow evaluation (no synchronous I/O on the hot path)

Two changes to keep the hot path non-blocking and policy-consistent:

**(a) Shared deployed policy (no divergence).** Refactor `ConductorRuntime` to hold its routing policy as a single `Arc<dyn ConductorRoutingPolicy>` (today `policy: StaticDirectPolicy`; the change is `Arc<StaticDirectPolicy>` coerced to the trait). The same `Arc` is used for **both** the live `route_turn` decision and the shadow router's deployed baseline. This structurally guarantees the shadow "deployed decision" equals the actually-executed decision for a given `ctx` — there is one policy object, not two copies that could drift. **Field-type fix:** change `ShadowRouter.deployed` from `Box<dyn ConductorRoutingPolicy>` to `Arc<dyn ConductorRoutingPolicy>` (and the constructor signature accordingly), so the shared `Arc` clones cleanly into it. (Rust does not coerce `Arc<dyn T>` → `Box<dyn T>`; an `Arc` field is the clean path — no blanket impl, explicit `Arc` semantics end-to-end.) *In-tree this is currently moot (`StaticDirectPolicy` is stateless), but the invariant becomes load-bearing the moment M3 swaps policies — so we pin it now.*

**(b) Pure decision + fire-and-forget append.** Today `ShadowRouter::evaluate` does the pure `decide()` **and** a synchronous `store.append_shadow_record`. To match the M1 telemetry pattern (fire-and-forget via `spawn_telemetry`/`spawn_blocking`), split it:

- `ShadowRouter::evaluate_record(ctx, fp, corpus, ts) -> ShadowTurnRecord` — **pure**: computes deployed + candidate decisions, scores the corpus match, returns the record. No I/O. (Mirrors `score_policies` which is already pure.)
- `ShadowRouter::evaluate(...)` — keeps the existing signature for tests; = `evaluate_record` + synchronous append (test-only; not on the hot path).
- `ConductorRuntime` adds a `spawn_shadow(record)` that clones the store + spawns the append via `spawn_blocking`, mirroring `spawn_telemetry`. The shadow record is built pure (cheap) on the hot path; the file write is off-path.

In `route_turn`, after `emit_event` and `run()`, **if a shadow router is present**: `let rec = shadow.evaluate_record(&ctx, fp, Some(&corpus), now_ms()); runtime.spawn_shadow(rec);` — best-effort; a store failure logs + continues, never aborts the turn. The corpus is parsed **once** at startup (`Corpus::synthetic_core()`; embedded via `include_str!`); parse failure is non-fatal — log + shadow records get `corpus_match = None` (no ground truth), the turn still accrues an outcome receipt.

**Why zero candidates is still useful:** it accrues (a) the deployed-policy corpus-match baseline on real traffic, and (b) — via the receipt join — production outcome metrics (latency, failures, fallbacks) for static-direct. That real-world baseline is exactly what M3 candidates will be measured against. (Caveat on routing accuracy specifically: §2.5.)

### §2.3 `read_receipts` store seam

`OutcomeMetrics::from_receipts` (reward.rs) needs the receipt stream. The store has `read_feedback`, `read_shadow_records`, `read_budget_usage_lines` — but **no `read_receipts`** (receipts are append-only today). Add `pub(crate) fn read_receipts(&self) -> Result<Vec<RouteReceipt>, ConductorError>` mirroring `read_shadow_records` (same `read_jsonl` helper; missing file ⇒ empty; corrupt line ⇒ error, fail-closed). Targeted `#[allow(dead_code)] // TODO(M2-live): used when reward snapshot reads the window` until Stage C.

### §2.4 Deployed-policy-divergence invariant (test)

Pinned by V2 (§6): for any `ctx`, the shadow router's deployed decision is byte-equal to the decision `route_turn` actually executed (same `Arc`, so structurally true; the test guards against a future refactor that re-introduces two policy objects).

### §2.5 Honest limitation: routing accuracy is degenerate this milestone

The shadow corpus-match path (`match_corpus_entry`, shadow.rs:96) requires **two** conditions: `entry.task_class == ctx.task_class` **and** `entry.feature_predicates.iter().all(|p| ctx.feature_predicates.iter().any(|c| c == p))` — i.e. **the entry's predicates must be a subset of the context's** (`entry.preds ⊆ ctx.preds`). `build_turn_context` (session.rs) sets `task_class: ConductorTaskClass::Unknown` with `feature_predicates: Vec::new()` (empty), because the routing policy is **content-blind by invariant** (F-4 / `policy.rs`): it does not read the prompt, so it cannot classify the turn.

The synthetic corpus *does* contain an `unknown` entry — but it carries three non-empty predicates: `["classifier_low_confidence", "safe_fallback", "local_ok"]`. With `ctx.feature_predicates = []`, the subset test `.all(|p| [].iter().any(...))` is **false for every `p`** — so `.all()` is false for every corpus entry, the `unknown` entry included. **Therefore every `inject_text` turn produces `corpus_match = None`** — zero matches, not one. (The earlier draft reversed the subset direction and wrongly claimed one degenerate match; source-verified and corrected.)

**Therefore, this milestone's honest accruals are:**
- **Outcome metrics** (latency / failures / fallbacks / cost) — fully real, derived from receipts.
- **User signal** (accept/reject/edit/rating) — fully real, via `conversation.feedback`.
- **Routing accuracy** — *plumbing in place, signal absent this milestone.* `corpus_match` is `None` for every turn (no classifier populates `feature_predicates`). The reward snapshot therefore reports the routing component as **neutral, with an explicit "no live routing ground truth" flag** (§4). It will not become meaningful until a content-aware task classifier lands (a separate milestone that deliberately touches the content-blind boundary) and starts populating `feature_predicates`.

This is not a defect to hide; it is the truthful state. M3 needs the plumbing + the outcome/user signals now; the classifier is separable. The acceptance test (§6 V4b) pins exactly this: a real `inject_text` turn yields a shadow record with `corpus_match.is_none()`, and the snapshot reports neutral.

### §2.6 Honest consequence for M3 — the classifier is on M3's critical path (not "someday")

The degenerate dimension (routing accuracy) is **precisely M3's core optimization target**: M3 mutates routing recipes, and the dimension that *directly* measures "did we route well" is the one that's neutral this milestone. So this milestone unblocks M3 with **proxy signal** — outcome (latency/cost/failures) and user (accept/reject) *do* discriminate routing choices indirectly, which is genuinely useful — but **not** the direct, labeled routing-accuracy ground truth that supervised routing optimization wants.

**The consequence:** the content-aware task classifier (currently scoped here as "a separate future milestone") is the **real unlock** for M3's central job. It is effectively **on M3's critical path for the routing dimension** — without it, M3 optimizes routing against proxies and plateaus. Therefore: **the classifier should be elevated from "someday" to "sequenced near/with M3"**, so M3 does not get built and then plateau optimizing routing against proxies. This sequencing is recorded in the execution plan (`docs/plans/fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md`, M3 section). The spec is honest that routing is absent this milestone; this subsection draws the line to "therefore the classifier is an M3 dependency, not a nice-to-have."

---

## §3. Stage B — `conversation.feedback` command

Explicit user signal is the only way `user_signal` ever enters the reward (otherwise permanently empty). A small, self-contained **authenticated control-plane** command.

### §3.1 Command shape (payload-based — `cmd.request_id` is THIS RPC's id)

In this protocol, `cmd.request_id` is the **current RPC's** correlation/audit id (the value used for the response frame and the audit log), **not** the prior turn's id. So feedback must reference the prior turn via a payload field:

```jsonc
// conversation.feedback
{
  "command": "conversation.feedback",
  "request_id": "<this feedback RPC's own id>",          // → response + audit
  "payload": {
    "target_request_id": "<opaque id of a PRIOR inject_text turn>",
    "signal": "accept" | "reject" | "edit" | "rating",
    "rating": <0..5>                                      // required iff signal == "rating"
  }
}
```

- `target_request_id` is fingerprinted with the runtime's `InstallKey` to produce the `request_fingerprint` that joins the prior turn's receipt/event/shadow records (F-4 continuity).
- Strict payload validation: parse into a struct with `#[serde(deny_unknown_fields)]` accepting **only** `target_request_id`, `signal`, `rating`. Unknown keys ⇒ `unknown_field` error. This does **not** mean user text "cannot enter the daemon" — the raw frame is still written to the **audit log** by the transport's fail-closed audit contract (every frame is). The honest, narrower claim: **the persisted `FeedbackRecord` is enum-only and contains no user text** (no free-text field exists in the validated struct).
- `signal` ∈ {accept, reject, edit, rating}; `rating` required iff `signal == "rating"`, `0..=5` (u8). Malformed ⇒ `CpResponse::error` (`unknown_signal` / `rating_out_of_range` / `rating_missing` / `unknown_field`).

### §3.2 Handler routing + scope (TWO registration points)

A command is reachable in **two** places — both must be updated, or the command is silently denied as `unknown_command`:

1. **`required_scopes()` in `crates/fae-control-plane/src/lib.rs`** (lib.rs:260–305) — this runs *first*, inside `authorize()` (lib.rs:416–417): `let Some(required) = required_scopes(&cmd.command) else { return Deny(UnknownCommand); };`. A command absent from this match table is denied **before** dispatch, regardless of scopes held. Register:
   ```rust
   "conversation.feedback" => &[Scope::ConversationWrite],
   ```
2. **`dispatch()` in `session.rs`** (the handler arm): `"conversation.feedback" => record_feedback(backends, cmd)`.

**Scope:** `ConversationWrite` (it is a write *about* a conversation; same scope family as `inject_text`). `record_feedback` requires `backends.conductor` (for `InstallKey` + `ConductorStore`); absent (legacy/test) ⇒ `"feedback requires conductor"`.

1. Validate payload (§3.1) → `UserSignal` (fail-closed on invalid).
2. `runtime.record_feedback(&target_request_id, signal, now_ms())?` — new method: fingerprint `target_request_id` with the `InstallKey`, build `FeedbackRecord { request_fingerprint, signal, timestamp_ms }`, `store.append_feedback`.
3. Best-effort? **No.** Unlike passive telemetry, feedback is an explicit user action; a store write failure surfaces as an error so the client can retry (mirrors the `read_jsonl` fail-closed philosophy — never silently drop a negative signal).
4. Response: `{ "recorded": true }`.

Late-arriving by design: the turn need not be open; unmatched feedback is simply not joined at scoring time. No validation that `target_request_id` refers to a known turn (avoids a receipt read + a TOCTOU-ish join on every feedback). See §8.1 for the bloat guardrail note.

---

## §4. Stage C — Advisory reward snapshot read

Make the accrued signal consumable. **Advisory only; no promotion; read-only.**

### §4.1 Command shape

```jsonc
// conductor.reward_snapshot  (authenticated control-plane)
{ "command": "conductor.reward_snapshot", "request_id": "<rpc id>",
  "payload": { "window_turns": <optional, default 100> } }
```

Response (auditable breakdown):

```jsonc
{
  "score": -0.12,
  "self_judgment_was_capped": false,
  "components": { "routing": 0.0, "user": -0.3, "outcome": -0.4, "self_judgment": 0.0 },
  "routing_source": "live_shadow",        // or "neutral_no_ground_truth"
  "window": { "turns": 87, "feedback_count": 12, "shadow_records": 87, "corpus_matches": 0,
              "corpus_version": "synthetic-core-v1" },
  "baseline": { "static_corpus_routing_accuracy": 0.55 }   // metadata, not the live reward input
}
```

### §4.2 Computation (live shadow window drives the routing component)

New `ConductorRuntime::reward_snapshot(window_turns) -> Result<Reward, ConductorError>`:

1. `read_receipts()` → trailing-N by `timestamp_ms` (the window).
2. `OutcomeMetrics::from_receipts(&window)` — the **outcome** component (fully real).
3. `read_feedback()` → filter to the window's fingerprints (join on `request_fingerprint`) → **user** component (fully real).
4. **Routing component — live, not static.** Read `read_shadow_records()`; join to the window on `request_fingerprint`. Let `matched` = records with `corpus_match.is_some()`, `correct` = those with `deployed_matched_ideal`. Synthesize a `RoutingScore`:
   - If `matched >= 1`: `routing_accuracy = correct / matched`; routing component = `(routing_accuracy − 0.5) * 2` clamped (same mapping as `routing_accuracy_component`).
   - If `matched == 0`: routing component = `0.0` and `routing_source = "neutral_no_ground_truth"` (the honest default — and, given §2.5, the common case until a classifier lands).
5. `routing_score` fed to `aggregate_reward` is this **live** synthesized score. The **static** corpus score (`RoutingScorer::score(&corpus, &*deployed)`, cached at startup) is returned separately as `baseline.static_corpus_routing_accuracy` — metadata for context, **not** the live reward input. (This corrects v1, which used the static re-score as the reward input — a constant that misrepresented a live window.)
6. `aggregate_reward(&RewardSignals { routing_score: &live, user_signal, outcome_metrics, self_judgment: None })`.
7. Return `Reward` + window summary + `routing_source` + baseline.

> **Scope of the synthesized `RoutingScore` (MINOR-2 guardrail):** it is constructed with **empty `case_outcomes`** (shadow records don't carry per-case McNemar data). It is valid **only** as input to `aggregate_reward`'s routing component, which reads `routing_accuracy` alone. **Never pass it to `is_improvement()`** — F-12's McNemar exact test requires a real corpus-scored `RoutingScore` with populated `case_outcomes`; the synthesized score would always fail significance (N=0), silently corrupting promotion decisions. Promotion decisions stay corpus-scored (M3).

### §4.3 Surface + authority (authenticated control-plane, not diagnostic-only)

`dispatch()` is shared by the Unix-socket transport **and** the opt-in loopback diagnostic TCP (`ws_message_loop`). So `conductor.reward_snapshot` is reachable from **any authenticated client**, not only the diagnostic surface. This is acceptable because the output is aggregates + fingerprints + enum tokens (no user text), but it must be stated honestly and **must be registered + scoped in two places** (same as §3.2):

1. **`required_scopes()` in `crates/fae-control-plane/src/lib.rs`** (register before dispatch, else `Deny(UnknownCommand)`):
   ```rust
   "conductor.reward_snapshot" => &[Scope::StatusRead],
   ```
2. **`dispatch()` arm** in `session.rs`: `"conductor.reward_snapshot" => conductor_reward_snapshot(backends, cmd)`.

**Scope:** `StatusRead` — *closed (Q4, oracle-confirmed).* `StatusRead` is the existing pattern for aggregate operator surfaces with no conversation content (`runtime.status`, `agent.list`, `audio.devices`, `info.push`). `conductor.reward_snapshot` fits exactly: aggregates + fingerprints + enum tokens. No new scope type needed.

- `conversation.feedback` → `ConversationWrite` (write about a conversation).
- The scope mapping is an explicit acceptance item (§6 V5b); a client lacking the scope is denied with `missing_scope` (existing `authed_command_missing_scope_is_denied` test pattern). A command missing from `required_scopes()` is denied with `unknown_command` — the registration is therefore a hard prerequisite, not a nicety.

The snapshot is **read-only**: it constructs no provider request, spawns no agent, writes nothing. It joins three isolated-store reads. It is observation, not egress.

---

## §5. Security & isolation analysis (the load-bearing claims)

Stated precisely, with what is **proven** vs **structural** vs **convention**.

### §5.1 No new conductor egress seam (structural)

`ConductorRuntime` gains a `ShadowRouter` field + a shared `Arc<dyn ConductorRoutingPolicy>`. `ShadowRouter` is `pub struct ShadowRouter { deployed: Arc<dyn ConductorRoutingPolicy>, candidates: Vec<NamedPolicy> }` (the `deployed` field is `Arc`, not `Box`, so the shared runtime `Arc` clones cleanly into it — §2.2a MINOR-1). It holds **no** `CloudProvider`/`AcpAgentRunner`/request-builder — those types are not in its scope. `evaluate_record` calls only `policy.decide(ctx)` (pure) + corpus matching; the append is off-path via `spawn_telemetry`. Wiring shadow into the runtime **cannot** cause egress.

- **Honest scope (carried from shadow.rs):** Rust cannot prove an arbitrary `ConductorRoutingPolicy::decide()` impl is pure. The load-bearing statement: **no conductor egress seam is reachable from the shadow path.** The in-tree policy (`StaticDirectPolicy`) is data-only; the M3 candidate surface must keep this (candidates are interpreted recipes, not executable code) — carried into the M3 spec.
- **Pinned by:** the existing `shadow_router_holds_no_egress_handle` test + a new wiring test (V1) asserting the same over the live `route_turn` path (zero provider calls; shadow append off-path).

### §5.2 Storage isolation (proven by code path)

All writes (`append_event`, `append_receipt`, `append_shadow_record`, `append_feedback`) target files under the isolated `ConductorStore` dir (`conductor/{events,receipts,shadow,feedback}.jsonl`). None constructs a `MemoryOrchestrator` write or touches `fae.db`.

- **Acceptance test (V5a):** run `conversation.feedback` + a turn + `conductor.reward_snapshot` against an instrumented store; assert the feedback record landed in `conductor/conductor_feedback.jsonl`, **zero** memory-store writes (spy), and the conductor dir contains only the four telemetry files + `recipes/`.
- **Grep gate (concrete paths):** `rg -n 'MemoryOrchestrator|fae\.db|memory_store' crates/fae-daemon/src/conductor/{reward.rs,shadow.rs,store.rs,executor.rs}` empty in touched code.

### §5.3 F-4 fingerprint continuity (structural)

`request_fingerprint` = HMAC-SHA-256(opaque request_id, per-install key). Shadow records and feedback are fingerprinted with the **same** `InstallKey` the executor uses (held by `ConductorRuntime`). A feedback row joins its prior receipt on the identical key. The fingerprint lift (§2.1) **reduces** computations (2 → 1 per turn), tightening the model.

### §5.4 The §5 gate pipeline is untouched (proven by call graph)

Execution still flows `route_turn → run()` with the full M2 §5 pipeline. Shadow capture happens **outside** `run()` (records the decision, not execution) and is best-effort off-path. A shadow failure cannot degrade a turn. Gate: existing fails-on-reorder test + byte-identity tests still pass; no §5 code is edited.

### §5.5 Reward capture is observation, not authority (by construction)

The snapshot reads three isolated-store files and computes a scalar. It writes nothing, constructs no provider request, spawns nothing. Not consulted by any execution path. (The M2 §5 gates own *permission*; the reward owns *measurement*.)

---

## §6. Verification & test matrix

Load-bearing claims get a **mutation-tested** test where feasible.

| # | Claim | Test | Mutation |
|---|---|---|---|
| V1 | Shadow adds no egress seam | `route_turn` with shadow on ⇒ zero provider calls; shadow record present | Spy provider; assert `calls == 0`; disable shadow guard ⇒ record absent |
| V2 | Shadow deployed == executed decision | For a `ctx`, `shadow.evaluate_record` deployed decision byte-equals the decision `route_turn` executed | (shared `Arc`; refactor test) — re-introduce a 2nd policy object ⇒ fail |
| V3 | Join-correctness of the fingerprint | event, receipt, shadow record, feedback for one turn share an **identical** `request_fingerprint` | Make an emitter re-derive ⇒ mismatch ⇒ fail |
| V4a | F-10 holds post-wiring | snapshot with neutral outcomes + no feedback ⇒ self_judgment term 0, score tracks inputs only | (pinned in reward.rs; re-assert over snapshot path) |
| V4b | Routing signal honesty | a real `inject_text` turn ⇒ shadow `corpus_match.is_none()` (zero matches: `ctx.feature_predicates = []` cannot satisfy any entry's non-empty predicates); snapshot reports `routing_source == "neutral_no_ground_truth"` | — |
| V5a | Isolation: feedback never reaches memory | `conversation.feedback` ⇒ record in conductor log, **zero** memory-store writes | Spy memory store |
| V5b | Scope mapping (two gates) | (a) command in `required_scopes()` ⇒ denied w/o its scope as `missing_scope`; (b) command removed from `required_scopes()` ⇒ denied as `unknown_command` regardless of scopes | Add/remove the table entry; assert the deny reason changes |
| V6 | Strict feedback payload | `deny_unknown_fields` ⇒ unknown key rejected; persisted `FeedbackRecord` is enum-only (no text field) | Add a free-text field to the validated struct ⇒ serde accepts ⇒ fail |
| V7 | Read seams fail closed | corrupt a line in each JSONL ⇒ `read_*` errors, snapshot surfaces error, never silently drops rows | Inject a bad line |
| V8 | No sync I/O on hot path | shadow append goes through `spawn_blocking`; `route_turn` does not block on the store | Make `spawn_shadow` synchronous ⇒ hot-path timing/structure changes ⇒ fail |
| V9 | Byte-identity of `inject_text` result unchanged | existing byte-identity tests (text + `assistant.generating` event pair) still pass | — |
| V10 | §5 gate ordering intact | existing fails-on-reorder test (membrane-before-construction ⇒ zero provider calls) still passes | — |
| V11 | Snapshot is read-only | snapshot ⇒ no store write, no provider call, no spawn | Spy all three |

**Isolation grep gates (release-validation, concrete):**
- `rg -n 'fae-metaopt' crates/fae-daemon/` empty (BLOCKER-1 precondition preserved).
- `rg -n 'MemoryOrchestrator|fae\.db|memory_store' crates/fae-daemon/src/conductor/{reward.rs,shadow.rs,store.rs,executor.rs}` empty in touched code.

---

## §7. Implementation staging & acceptance

Each stage is independently testable + committable. **Process per stage: implement → `cargo fmt` → `cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used` → `cargo check --workspace --all-targets` → `cargo test -p fae-daemon` → commit.**

- **Stage A** (§2): fingerprint lift + shared-policy refactor (`ShadowRouter.deployed` → `Arc<dyn …>`) + `evaluate_record`/`spawn_shadow` + `read_receipts`. Acceptance: V1, V2, V3, V4b, V7, V8, V9, V10; shadow records accrue on local turns (`corpus_match` honestly `None`); byte-identity intact.
- **Stage B** (§3): **register `conversation.feedback` → `ConversationWrite` in `required_scopes()` (`fae-control-plane/src/lib.rs`)** + `dispatch()` arm + `record_feedback`. Acceptance: V5a, V5b, V6; feedback lands in isolated log; fail-closed on bad payload.
- **Stage C** (§4): **register `conductor.reward_snapshot` → `StatusRead` in `required_scopes()`** + `dispatch()` arm + `reward_snapshot`. Acceptance: V4a, V11; snapshot returns the auditable breakdown with live routing source (or honest neutral); read-only.

**Whole-milestone gate (after all three):** V1–V11 green; full `cargo test --workspace` passes; both grep gates clean. Then **oracle + reviewer review** (oracle: security/isolation/§5 claims; reviewer: implementation correctness, panic-free, test quality).

**`#[allow(dead_code)]` discipline:** each staged-future item keeps a targeted, dated `#[allow(dead_code)] // TODO(M3, …)`. No blanket allows. Removing the module-level `reward`/`shadow` allows is an acceptance item once they have live call sites.

---

## §8. Decisions (locked by David, 2026-06-24)

1. **Shadow `evaluate_record` timing + timestamp alignment — DECIDED: post-`run()`, shared `now_ms()`.** Shadow capture happens **after** `run()` (a crashed turn accrues neither shadow nor receipt — consistent), using the **same `now_ms()` snapshot** as the receipt so the shadow record and receipt `timestamp_ms` align for the window join (oracle NOTE-2; V3 join-correctness depends on this).
2. **Corpus parse-failure policy — DECIDED: start with shadow scoring disabled + warning.** If `synthetic_core()` fails at startup (shouldn't — embedded + tested), the daemon starts with shadow scoring disabled + a `tracing::warn!`. Reward capture is observation; a tested embedded corpus shouldn't gate the daemon. (Routing source reads `neutral_no_ground_truth` until/unless restored.)
3. **Feedback for unknown `target_request_id` — DECIDED: accept + store.** No existence check; unmatched feedback is simply not joined at scoring time (avoids a receipt read + a TOCTOU-ish join on every feedback).
4. **`conductor.reward_snapshot` scope — DECIDED (oracle NOTE-1): `StatusRead`.** Matches the existing pattern for aggregate operator surfaces (`runtime.status`, `agent.list`, `audio.devices`, `info.push`); no conversation content in the output. No new scope type needed.

### §8.1 Bounded feedback append (low-severity guardrail)

Decision 3 accepts feedback for any `target_request_id` with no existence check, so orphan/spam feedback records can bloat the isolated store over time. **Mitigation (one-line, this milestone):** the `reward_snapshot` window join naturally ignores feedback whose fingerprint isn't in the trailing-N receipts — so orphan rows are *inert* at scoring time, not harmful. **Noted risk, deferred:** if the feedback log grows unbounded in practice, a future GC (drop feedback older than the oldest receipt, or a hard row cap) is a small follow-up. *Not added this milestone* — the surface is an authenticated owner-client (low abuse surface), and the rows are small enum-only records. Builder does not improvise a cap; if one is wanted, it is a separate, deliberate change.

---

## §9. Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| Routing accuracy degenerate (F-4) ⇒ overclaiming "observable routing" | **High (honesty)** | §2.5 states it plainly; snapshot reports `routing_source`/neutral; classifier is a separate milestone. |
| Shadow capture adds latency to the hot path | Medium | `evaluate_record` is pure + cheap; append is off-path via `spawn_blocking` (V8). Measure. |
| Fingerprint lift changes byte-identity | Medium | Telemetry is fire-and-forget; refactor only dedups the HMAC. Byte-identity tests gate. |
| Deployed-policy divergence (future stateful policy) | Low now / High at M3 | Shared `Arc<dyn ConductorRoutingPolicy>` + V2 invariant test. |
| A future change moves a §5 gate after request construction | High (carried from ADR-008a) | Existing fails-on-reorder test is a standing precondition; this spec does not touch §5. |
| `fae-metaopt` accidentally wired before denylist | **Blocker** (carried) | Grep gate in acceptance; this spec does not touch `fae-metaopt`. |

---

## §10. What "done" looks like

- The conductor accrues shadow records + receipts + (via feedback) user signals on real local turns — with routing accuracy **honestly flagged as absent** (`corpus_match = None`) until a classifier lands, and outcome/user signals fully real.
- A human can read a reward snapshot (advisory breakdown, live shadow window + honest neutral) on the authenticated control-plane.
- Zero new egress seams; isolation grep gates clean; F-10 intact; §5 gate ordering intact; byte-identity intact; no sync I/O on the hot path.
- `fae-metaopt` remains unwired (BLOCKER-1 precondition preserved).
- Oracle + reviewer reviews pass with zero BLOCKER/MAJOR.
- M3 is unblocked: there is now real outcome + user reward signal (and the plumbing for routing accuracy) for MetaOpt to optimize against, with the denylist as a hard precondition before `fae-metaopt` is ever wired.

# Fae Learned Conductor — M0→M3 Rust Execution Plan

> Status: **Execution tracker** · 2026-06-22 · Owner: David Irvine
> Plan: [`../research/fae-learned-conductor-d1-d7-plan-2026-06-22.md`](../research/fae-learned-conductor-d1-d7-plan-2026-06-22.md) (v3, Rust-core, post-ADR-011).
> Architecture: headless Rust core canonical ([ADR-011](../adr/011-headless-rust-core-runtime.md)).
> Process rule: **every milestone has a review gate before the next begins.** Do not start a milestone's implementation until the prior milestone's review passes.

## Review-gate discipline

| Gate | When | Reviewer | Focus | Pass criteria |
|---|---|---|---|---|
| G-M0a | after M0a docs | `reviewer` | stale-Swift-reference sweep, ADR consistency, Rust architecture coherence | zero BLOCKER/MAJOR |
| G-M0b | after M0b scaffold | `reviewer` + `oracle` | type design, telemetry privacy (F-4 fingerprint), store isolation, zero behavior change | zero BLOCKER/MAJOR |
| G-M1-spec | before M1 impl | `plan-reviewer` | static-recipe spec, direct-default (F-3), approval matrix (F-7 resolved) | spec approved |
| G-M1 | after M1 impl | `reviewer` | local/ACP-only enforcement, telemetry correctness, no mesh/peer/remote leakage | zero BLOCKER/MAJOR |
| G-M2-spec | before M2 impl | `plan-reviewer` | reward design, eval methodology (F-11/12), shadow-router deps (F-8) | spec approved |
| G-M2 | after M2 impl | `reviewer` | reward-signal weakness, privacy leakage in shadow path, threshold enforcement | zero BLOCKER/MAJOR |
| G-M3-spec | before M3 impl | `oracle` | ADR-008 amendment (F-5), MetaOpt Rust-port vs bridge decision, protected-kernel boundaries | ADR accepted + spec approved |
| G-M3 | after M3 impl | `oracle` + `reviewer` | autonomous-mutation rollback, runtime asserts (F-15), SOUL-drift metric (F-16) | zero BLOCKER/MAJOR |

---

## M0a — Architecture doc reconciliation  ✅ DONE 2026-06-22

- [x] Create [ADR-011](../adr/011-headless-rust-core-runtime.md) — headless Rust core canonical
- [x] Update `docs/adr/README.md` — add row 011, fix "ADR-002 only superseded" note
- [x] Update `AGENTS.md` "Current architecture" section — Rust-headless canonical, Swift = migration/legacy
- [x] Update `docs/CURRENT_STATE.md` tech stack — Rust daemon canonical, Swift = migration/legacy
- [x] Reaffirm `docs/architecture/conductor-tier1-own-fleet-2026-06-05.md` (Rust core, ADR-011)
- [x] Update `docs/research/sakana-fugu-vs-fae-conductor-2026-06-22.md` ADR triggers (Rust core → ADR-011)
- [x] Rewrite plan to v3 Rust-core: `docs/research/fae-learned-conductor-d1-d7-plan-2026-06-22.md`
- [x] **G-M0a review: `reviewer` on the doc reconciliation** — PASSED after 1 BLOCKER fix (CI guard contradiction)
- [x] Retire stale Rust guard: `scripts/ci/guard-no-rust-reintro.sh` removed from `.github/workflows/ci.yml` (preflight → no-op echo); `justfile guard-no-rust` recipe → no-op echo. *(Script file itself left in place as inert; delete in a later cleanup.)*
- [x] Fix MAJOR: misleading "default Swift-only bundle" justfile comment → "Swift-legacy migration bundle"
- [x] Fix MINOR: AGENTS.md memory touchpoints now scoped "Swift migration/legacy surface"

---

## M0b — Rust conductor scaffolding (behavior-free)  ✅ DONE 2026-06-22

*G-M0a passed; M0b implemented; G-M0b review PASSED (zero BLOCKER/MAJOR); 4 MINORs addressed.*

**Orientation (done):**
- [x] Confirmed Rust storage convention — JSONL + serde JSON files (mirrors the daemon audit log); no sqlite dep in the workspace yet. Conductor store lives under the daemon run dir (path wired in M1).
- [x] Crate location: `crates/fae-daemon/src/conductor/` (promotable to `crates/fae-conductor` later).

**Types (`crates/fae-daemon/src/conductor/`):**
- [x] `FaeConductorRecipe`, `ConductorRole` (Thinker/Worker/Verifier), `ConductorTopology` (Direct/Chain only — F-15 compile-time + serde fail-closed), `WorkerSelector`, `PrivacyLane` (+ monotone `permits`), `BudgetPolicy`, `EscalationPolicy`, `AggregationPolicy`, `StopPolicy`
- [x] `ConductorTurnContext`, `ConductorRouteDecision`
- [x] `recipe.validate()` — chain role ordering, non-positive budget, v1-safe locality+lane

**Telemetry + storage (Rust-side, isolated):**
- [x] `ConductorRouteEvent` + `RouteReceipt` types (no raw prompt/memory/secrets)
- [x] `ConductorStore`: append-only JSONL (`conductor_route_events.jsonl`, `conductor_receipts.jsonl`) + recipe JSON files (`recipes/<id>.v<ver>.json`, temp+rename atomic)
- [x] **F-4:** `RequestFingerprint` = HMAC-SHA-256 of opaque `request_id` with per-install `InstallKey` (0600, idempotent, corrupt-file recovery logged); **no user text is ever hashed**
- [x] `sanitize_id` blocks path escape + reserved names (`.`/`..`)

**Review fixes applied (G-M0b MINORs):**
- [x] F-4b: corrupt-key regeneration now logs (telemetry-discontinuity warning)
- [x] S-1: `sanitize_id` rejects bare `.`/`..`
- [x] S-3: JSONL append single-`write_all` (smaller truncation window)
- [x] FC-3: doc invariant on `eval_delta`/`user_signal` (M2 must not encode query content)

**Validation gate (all clean):**
- [x] `cargo fmt --all`
- [x] `cargo check --workspace --all-targets`
- [x] `cargo clippy -p fae-daemon --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used` (strict, panic-free)
- [x] `cargo test -p fae-daemon conductor::` — 18/18 pass
- [x] **G-M0b review PASSED** (zero BLOCKER/MAJOR; 4 MINORs addressed)

**Did NOT do (correct):** any runtime routing change, any memory-store write, any Swift surface, any wiring into `offline_turn`/`session`/main flow.

---

## M1 — Static recipes (local + ACP only; `direct` DEFAULT, `chain` opt-in)  ✅ DONE 2026-06-22

**Prereq (RESOLVED 2026-06-22):**
- [x] F-7 standing-autonomy policy decided — **tiered model, Tier A only in M1:**
  - **Tier A — Autonomous (`ApprovalClass::None`):** **on-device models only** (mistral.rs / llama.cpp) — genuinely zero egress. *All of M1* — no approval surface needed. (ACP agents are NOT Tier A — they are cloud-backed; their lane + tier is a **G-M2-spec decision**, D-M2-1. "Local process ≠ local data.")
  - **Tier B — Standing-grantable:** remote API / x0x peers; per-class grant + budget cap, revocable. *M2 spec* (budget-governance WP lives there).
  - **Tier C — Always per-turn:** sensitive-data / cross-owner / PII / outside-a-grant. *M2 spec.*
  - **Seam added in M0b:** `ApprovalClass` enum + `approval` field on `AgentRun` variant of `ConductorRouteDecision`. M1 always emits `None`; M2 wires Tier B/C into the existing seam (no routing-call-site retrofit).

**Spec — G-M1-spec PASSED 2026-06-22:**
- [x] Spec file: `docs/architecture/conductor-m1-static-recipes-spec-2026-06-22.md` (v2 + 4 MINOR clarifications N1-N4)
- [x] G-M1-spec review (v1 FAILED: 1 BLOCKER B1 + 3 MAJOR M1/M2/M3, all folded into v2; v2 PASS: zero BLOCKER/MAJOR)
- Key design locks: injection seam = `inject_text` only; **direct arm runs `inject_text_core` verbatim** (B1 byte-identity fix); `OwnedRouteDecision` carries `request_id` (fingerprint in executor, M2 panic-safety fix); `FAE_CONDUCTOR_CHAIN` env var gates chain (M3 fix); telemetry via `spawn_blocking`, best-effort, isolated JSONL

**Impl:**
- [x] Extract `inject_text_core` from `inject_text` (step A, behavior-preserving — `e4da1bf2`)
- [x] Steps B/C/D: owned types + policy/executor/telemetry modules (behavior-free)
- [x] Step E: wire conductor into `inject_text` via `SessionBackends`; `main.rs` constructs `ConductorRuntime` + reads `FAE_CONDUCTOR_CHAIN`; conductor-routed `direct` is byte-identical to legacy path
- [x] Step F: removed blanket `#![allow(dead_code)]` (G-M1 BLOCKER fix); every staged M2/M3 item carries a scoped `#[allow(dead_code)]` + TODO(<milestone>)
- [x] Passive route telemetry capture per role (fire-and-forget `spawn_blocking`, isolated JSONL store, F-4 fingerprint)
- [x] **G-M1 review: PASSED** (v1 FAIL on self-referential §13.7 BLOCKER + 3 MINORs; v2 PASS — all fixed). Byte-identity proven (text + `assistant.generating` event pair + telemetry-written + no-prompt-leak), static-direct recipe resolves (not fail-closed), 85/85 tests.

---

## M2 — Reward & eval + shadow routing  ⏳ D2+D7 DONE; **G-M2-spec PASSED** (spec v2.1 `ffa0819e`); M2 wiring UNBLOCKED

**Spec:**
- [x] `routing_accuracy` eval dimension + reward aggregator (reject self-judgment-only — F-10) — **M4 classifier (`acdd04af`) unblocked this**: `corpus_match` flips `None→Some` now that turns carry real `task_class`+`feature_predicates`. The reward aggregator (M2) accrues outcome signal; the classifier populates the routing-accuracy dimension. F-8 budget-governance + audit-logging WPs landed in M0b/M1.
- [ ] **F-8:** shadow router depends on budget-governance + audit-logging WPs from M0b/M1
- [ ] Shadow router: route-decision-only by default; local-only execution under strict budget; **never** remote/paid/cross-owner
- [x] **F-11:** eval corpus methodology documented (single-annotator = David, versioned, known limitation) — *landed in `eval.rs` module docs (WP-D7)*
- [x] **F-12:** "measured improvement" = statistical significance + ≥5% relative + no regression on any measured dimension — *landed as `is_improvement()` code, not prose (WP-D7)*
- [ ] **G-M2-spec review: `plan-reviewer`** — **PASSED** (run 860ab950, 2026-06-23). v1 CONDITIONAL FAIL (5 MAJORs) → v2 resolved all → v2.1 folded 2 substantive NOTEs. Spec at `docs/architecture/conductor-m2-reward-eval-shadow-routing-spec-2026-06-23.md`.

**Impl:**
- [x] **WP-D2 — Budget governance primitive** (commits `251ae1dc`, merged to main): `BudgetGovernor` (Cost + Wall-clock + Per-day, fail-closed; token telemetry-only), `RouteFailure::BudgetExceeded` structured-only, per-day state in isolated store, `PrivacyLane::CloudBacked` + `locality_to_lane(LocalAcp)` fix. Dormant — no executor wiring. Independently gate-verified (95 tests, fmt/check/clippy clean).
- [x] **WP-D7 — Eval corpus + routing scorer** (commits `3ac27ffe`, merged to main): versioned hybrid corpus (synthetic core + membrane-scrubbed real samples), `RoutingScorer` + `score()` + `is_improvement()` (F-12 as code), scrub-before-disk test (genuine: reads file back, asserts credential absent). Dormant — no executor wiring, no aggregator, no MetaOpt. Independently gate-verified (92 tests standalone, 101 combined).
- [x] **Reward aggregator (§7) — COMMITTED + REVIEWED** (`d1b4d79d`; review run `5b172df5`, zero BLOCKER/MAJOR): `crates/fae-daemon/src/conductor/reward.rs`. Four-signal aggregator (routing accuracy / user signal / outcome metrics / self-judgment); **F-10 enforced structurally** — self-judgment may never be the sole positive source (mutation-tested: `self_judgment_alone_cannot_produce_positive_reward`; **reviewer-confirmed production-real, not theater**). Late-arriving feedback log (`conductor_feedback.jsonl`) + `FeedbackRecord`/`UserSignal` types + `append_feedback`/`read_feedback` store seam. 12 reward tests.
- [x] **Shadow router (§8) — COMMITTED + REVIEWED** (`d1b4d79d`; review run `5b172df5`, zero BLOCKER/MAJOR): `crates/fae-daemon/src/conductor/shadow.rs`. **Structural no-egress** (**reviewer-confirmed compile-time**: `ShadowRouter` holds only `Box<dyn ConductorRoutingPolicy>` + `Vec<NamedPolicy>` — no `CloudProvider`/`AcpAgentRunner` field exists; the type is out-of-scope, stronger than a runtime spy). Decision-only candidate scoring; promotion flagging via `is_improvement` (NOT auto-deploy); `ShadowTurnRecord` persisted to isolated store. 4 shadow tests.
- [ ] **No auto-deploy yet** — candidates compare against deployed baseline only (correct: promotion is human-act until M3 MetaOpt)
- [ ] **M2 executor wiring** — connects BudgetGovernor + RoutingScorer + PII membrane into the conductor routing path. GATED on G-M2-spec + both WP reviewer passes + D-M2-1 resolution.
  - **Spec §15 staging added** (commit `e66e6ad2`): 3-stage cutover. Stage 1 = egress pipeline behind `FAE_MODEL_MODE=pure-local` default (reward/shadow DEFERRED; pricing included). Stage 2 = `red-team` egress-security review (zero BLOCKER/MAJOR gate). Stage 3 = SEPARATE gated default-flip to `all-available` behind the release-validation contract. "Wiring works" ≠ "cloud on by default" — different commits.
  - **Stage 1 MERGED to main** (merge `367524cb`; builder commit `c366b6f1` + security fix `9248f72d`): the §5 pipeline (mode cap → membrane-before-construction → budget → approval [incl. worker-locality match] → worker → record), `pricing.rs`, per-worker budget buckets, `LocalAcp`→`CloudBackedAcp` rename, tracing migration. Default stays `pure-local` (no Stage 3 flip).
  - **Review trail (both fresh-context red-team, zero BLOCKER/MAJOR):** Stage 1 (`c366b6f1`, run `a2792fb6`) — all 7 load-bearing invariants verified; fails-on-reorder test is the strong form (builder spy 0× + provider 0×, real membrane + real credential). Security follow-up (`9248f72d`, run `a178db65`) — fixed approval-gate locality MINOR (mutation-proven: disabled ⇒ `builder_calls==1` silent egress; restored ⇒ 0) + NOTE-3 audit-trail. **118 fae-daemon tests on main.**
  - **Stage 3 (all-available default flip) — DECIDED: not proceeding (owner 2026-06-23):** the security architecture is **Fae-as-local-coordinator** — Gemma is local, private, the boss; she coordinates ACP harnesses + cloud API models as tools; cloud coordination is **Fae-mediated delegated work** (scoped tasks), not a data firehose; the membrane is **defense-in-depth for credentials**, not the trust boundary. The architecture is sound. The Stage 3 question is therefore *not* "is cloud safe" — it is *"what default coordination reach fits a privacy-first companion?"* Answer: **`pure-local` default; `all-available` explicit opt-in.** Matches ADR-001/003/007's local-first identity. Full analysis + security model: `docs/architecture/egress-scope-and-stage3-hold-2026-06-23.md`. NOTE-2 (egress-completeness) is CLOSED; cloud egress stays opt-in (`FAE_MODEL_MODE=all-available` or `local-symphony`).
  - **NOTE-2 (agent-command egress gating) CLOSED — MERGED to main** (merge `69b5d063`; impl `36210c51` + security fix `f9cd2922`): `agent.run`, `agent.prompt`, `agent.session_start` now gate at entry via shared `assert_agent_egress_gates` (resolve → mode cap → PII membrane if prompt → provisioning+locality). New `AcpAgentRunner` trait makes the `fae_acp` spawn/start/submit boundary a spy-able seam. Budget skipped (owner decision); fail-closed = hard refusal (delegation is explicit). **Review trail:** spec v2.1 PASSED (re-review `b32b86c2`); impl red-team `251dfbf0` zero BLOCKER/MAJOR (all 8 adversarial surfaces verified; 4 load-bearing tests structurally fail-on-bypass, mutation-proven); security follow-up folded red-team NOTE-1 (normalize agent payload for gate+runner). **126 fae-daemon tests on main.**
  - **NOTE-1 (conductor pricing) RETIRED by owner decision 2026-06-23:** provider-side spend caps (OpenAI/Anthropic/etc.) are the authoritative cost control — stricter and more correct than a conductor-maintained heuristic, and offloading spend there removes the staleness/miscalculation risk of a local pricing table. Conductor cost gating is therefore OPTIONAL/non-authoritative: `FAE_PROVIDER_PRICING` + `budget.rs` cost dimensions stay available for operators who want conductor-level cost governance, but **no conductor spend guarantee is made and real pricing is NOT a Stage 3 prerequisite**. (Recorded gap: provider caps are per-provider and don't aggregate conductor chain spend across calls/providers — accepted as a smaller, revisitable risk.)
- [ ] **Reward aggregator (§7) + shadow router (§8) — COMMITTED DORMANT** (`d1b4d79d`): test-covered, structurally no-egress, F-10 enforced. **Awaiting G-M2 review (standard pass, non-egress) + executor wiring.**
- [x] **G-M2 review: `reviewer`** — **PASSED** (run `5b172df5`, 2026-06-24). Standard pass (non-egress). Zero BLOCKER / zero MAJOR. **Both load-bearing claims confirmed in production code:** F-10 (self-judgment structurally capped — `min(0.0)` path is real, test exercises it directly) and structural no-egress (compile-time: `ShadowRouter` holds only `Box<dyn ConductorRoutingPolicy>` + `Vec<NamedPolicy>`, no egress handle exists; the type is out-of-scope — stronger than a runtime spy). Findings: 2 MINOR (OutcomeMetrics window provenance check — low risk, isolated executor is caller; non-auto-promotion is convention not compile-time) + 1 NOTE (compile-time proof is stronger than the spec's runtime-spy suggestion). **M2 is REVIEW-COMPLETE** — remaining M2 work is executor wiring (connect dormant reward/shadow into the live loop), which is a separate gated step.

**Reviewer pass (run 7b311b14, 2026-06-23):** Both WPs passed fresh-context adversarial review with **zero BLOCKER / zero MAJOR**. D2: 8 constraint surfaces verified (fail-closed, token-not-gated, BudgetExceeded structured-only, no executor wiring, CloudBacked placement, per-day privacy, engineering contract, test quality). D7: F-12 `is_improvement` confirmed as real code (4 conditions incl. real McNemar exact test), scrub-before-disk confirmed genuine (round-trip test reads file back), no aggregator/MetaOpt/auto-deploy, F-11 documented. **MINOR findings deferred:** D2 `daily_window>0` validation → M2 wiring (fail-closed not weakened); D2 `eprintln!`→`tracing` → M2 wiring; D7 `#![forbid(unsafe_code)]` parity → **fixed** (`b4e33ab4`). D2 `unwrap_or(0)` and D7 `Default` derive / O(n) `log_factorial`: non-issues, no action.

---

## M3 — MetaOpt learning  ⏳ **G-M3-spec PASSED v5** (spec implementation-ready); **M3 impl HELD — premature until the conductor is alive** (see Sequencing below)

### Sequencing (decision 2026-06-24, advisor-directed)

M3 is Fae learning to mutate her own routing recipes — that layer optimizes against a **reward signal**. The reward aggregator (§7) and shadow router (§8) that produce that signal are **dormant** (`#[allow(dead_code)]`, no calls from the live turn loop — verified zero refs from `executor.rs`/`session.rs`). Building self-mutation on a conductor producing no reward data is **building the roof before the walls**: M3 would optimize against nothing.

**Dependency chain (the correct order):**
1. **Wire M2 reward/shadow signal collection into the live loop** (local turns only — routing accuracy + user signals). This does NOT require the Stage-3 cloud-egress cutover (which stays gated). Lower-risk, makes the conductor observable, accrues real signal.
2. **Real reward signal accrues** on actual turns.
3. **Then M3**, with the BLOCKER-1 denylist as a **hard precondition** for ever wiring `fae-metaopt` into the daemon (wire it first → ship the live config-write hole).
4. **The content-aware task classifier is on M3's critical path for the routing dimension** (owner insight 2026-06-24, recorded in [`conductor-m2-reward-shadow-live-wiring-spec-2026-06-24.md`](../architecture/conductor-m2-reward-shadow-live-wiring-spec-2026-06-24.md) §2.6). The M2-live-wiring milestone accrues **proxy** signal (outcome: latency/cost/failures; user: accept/reject) which discriminates routing choices indirectly — but routing *accuracy* is neutral until a classifier populates `feature_predicates` (F-4 content-blindness forbids reading the prompt today, so every turn is `task_class::Unknown` ⇒ `corpus_match = None`). M3's core job is mutating routing recipes; the dimension that *directly* measures "did we route well" is the one that's absent. **Therefore the classifier is elevated from "someday" to "sequenced near/with M3"** — without it, M3 optimizes routing against proxies and plateaus. It touches the content-blind boundary deliberately and is its own small milestone, but it is a **dependency for the routing dimension of M3**, not a nice-to-have.

   > **HARD GATE — classifier before any LIVE mutation (owner directive 2026-06-25):**
   > The content-aware task classifier is a **hard prerequisite for any live mutation loop**.
   > M3 ships **dormant / offline / CLI-only / human-approves-every-promotion** (spec §0)
   > precisely to keep mutation OFF the live path until the classifier lands. Without
   > it, a live optimizer would mutate routing recipes against proxy signal only and
   > plateau — routing accuracy stays neutral because F-4 forbids reading the prompt.
   > **Therefore: NO live auto-deploy, NO scheduler task, NO default route mutation
   > until the classifier exists.** The classifier is its own content-boundary
   > milestone (touches the content-blind line deliberately). M3-A/B/C ship as
   > dormant plumbing under this gate; the live loop is a post-M3 gated step.

> **F-16 (SOUL drift) scope resolution (M3-C4, decision 2026-06-26):**
> The single-prompt identity/SOUL guard is **already** M3-C1's
> `check_soul_framing_dropped` (its doc: "the actual F-16 threat — a mutation
> that rewrites identity"). The F-16 **SOUL-drift metric** (proxy metric +
> periodic review trigger) is **deferred**: it is temporal/measurement work
> needing a reward signal or a scheduler task (both blocked — a periodic
> trigger would drift toward scheduler/live behavior, gated by the classifier
> hard gate above). M3-C4 ships the offline CLI driver only; the F-16 metric is
> post-M3 measurement work, not a prompt-lint extension.

This ordering also respects the sequencing rule the BLOCKER created. The M3 spec remains a durable, well-earned milestone (5 adversarial rounds; dormant/offline/CLI-only/human-approves-every-promotion is exactly the right posture for autonomous self-mutation) — it is simply not the right thing to *build* next.

**Prereqs (open Qs for David):**
- [x] F-5: **ADR-008 amendment ACCEPTED + MERGED** (`ec856463`, owner-accepted 2026-06-23): `docs/adr/008a-conductor-recipe-surface-amendment.md` — Accepted (Amendment). Authorizes Rust-side `conductorRecipe` surface under **four** enforceable constraints (keep-or-narrow lane, budget-within-provisioned-cap, no gated locality/topology, **no `ModelMode` override**). Two-layer enforcement: Layer 1 proposal-structural (fae-metaopt), Layer 2 runtime-authoritative (M2 §5 gates). Cross-ADR dependency on the M2 §5.6 membrane-before-construction invariant (test-enforced). **M3 is no longer blocked on the ADR** — remaining M3 gate is G-M2 impl completion (reward/shadow §7/§8).
- [x] MetaOpt-split decision: **Rust-native port** (D-M2-4 RATIFIED: PORT NOW, no bridge)
- [x] **MetaOpt primitive ported** (commit `5b9275a3`, merged `750a4a4a`): `crates/fae-metaopt/` (~1500 lines). 4 existing surfaces (Directive/ConfigKnob/Skill/MemorySeed), hill-climbing loop, 6 trait seams, 3 intentional hardening points. Reviewer pass MERGE-READY (0 BLOCKER/MAJOR). Dormant + unwired. **NO ConductorRecipe variant** (now ADR-008a-authorized; lands in M3).

**Spec:**
- [x] **M3 spec — v5 PASSED** (`f3a1ed70`; G-M3-spec review run `d89f3738`, 2026-06-24). Five review rounds (v1→v5) folded 1 BLOCKER + 7 MAJOR + 1 NEW-MAJOR.
  - **BLOCKER-1, honest framing (corrected post-review):** G-M3-spec found a *real* config-write weakness in `fae-metaopt::optimizer.rs` ConfigAdjustment — unlisted keys bypass `ConfigBound` validation and are written unconditionally at `write_config` (verified `optimizer.rs:309-323`). **It is NOT reachable in the running product** — `fae-metaopt` is dormant/unwired (zero refs from `fae-daemon`; not in its Cargo.toml). **It is NOT yet fixed in code** — no denylist exists; the M3 spec *mandates* `is_protected_config_key()` with separator canonicalization, and the fix ships with M3 implementation. **Hard sequencing constraint:** `fae-metaopt` must not be wired into the daemon until the denylist exists — wire it first and you ship the live hole.
  - Design: dormant/offline/CLI-only; recipe-is-data-not-code; two-layer enforcement (Layer 1 validator + Layer 2 M2 §5 gates); `ConductorRecipePatch` (5 operators, `SwitchTopology` carries `chain_slots` for direct→chain construction) in `fae-metaopt`; `DaemonConductorRecipePort` adapter in `fae-daemon`; CAS apply/rollback (no TOCTOU); §5 prompt lint (incl. `no_tool_authority_expansion`); F-16 SOUL-drift (local-only held-out corpus + deterministic lint, model advisory-only). Spec at `docs/architecture/conductor-m3-metaopt-recipe-mutation-spec-2026-06-24.md`.
- [ ] `MetaOptSurface::ConductorRecipe` + mutation operators (per v5 spec §1.1, §2)
- [ ] Apply/rollback transactional with CAS (v5 spec §2.2, §4); narrator copy (no router jargon)
- [x] **F-15:** `FaeConductorRecipe` `#[serde(deny_unknown_fields)]` + recipe-level star/debate/unknown-field rejection tests (M5-C, `conductor-m5-...-spec`). Star/Debate remain compile-time-unreachable (enum = Direct/Chain only); the struct-level deny is defense-in-depth against crafted-JSON metadata smuggling. Existing enum-level test retained.
- [ ] **F-16:** SOUL-drift proxy metric + periodic review trigger (v5 spec §6)
- [x] **G-M3-spec review: `oracle`** — **PASSED v5** (run `d89f3738`). 5 rounds: v1 FAIL (1 BLOCKER + 7 MAJOR), v2 FAIL (5 closed, 2 open + 1 new), v3 FAIL (MAJOR-3 closed, MAJOR-2 too-broad + TOCTOU), v4 FAIL (MAJOR-2 closed via fold, §4 contradiction), v5 PASS. All 9 findings closed.

**Impl:**
- [ ] MetaOpt recipe mutation (Rust-native or bridged per decision)
- [ ] Deploy only on measured improvement + zero regression across quality/cost/latency/privacy/personality-drift
- [ ] "Undo last change" works
- [ ] **G-M3 review: `oracle` + `reviewer`** — autonomous-mutation rollback, asserts, SOUL-drift metric

---

## After M3 — remaining work (captured, ADR-gated)

- [x] **M4** Tier-1 same-owner x0x sync (`delegate_to_mesh`). **COMPLETE (dormant)** — spec `docs/architecture/conductor-m4-ownerfleet-x0x-sync-spec-2026-06-27.md`; F-14 snapshot `docs/architecture/conductor-m4-f14-x0x-api-snapshot.md`:
  - **F-2** closed: `ConductorEgressMembrane` (renamed from `RealPiiMembrane`) is the named F-2 authority; OwnerFleet + credential prompt ⇒ blocked at §5.3 + mesh port call-count 0 (proven).
  - **F-14** confirmed: read the actual crates — `x0x@a6fce96` (v0.26.0) is transport-only (no LLM); `x0x-compute@c9f765b` is the OpenAI-compatible chat-completion contract (`RuntimeAdapter::chat_completion`, `POST /v1/openai/chat/completions`), Phase 2a skeleton runtime.
  - **F-13** closed: async-ready `ConductorMeshDelegationPort` (pure conductor types; x0x stays out — `guard-mesh-boundary.sh`, mutation-tested). `UnavailableMeshDelegationPort` is the production fail-closed default; `MockMeshDelegationPort` is `#[cfg(test)]`-only. Executor dispatch splits by lane: OwnerFleet → `run_mesh_direct` (§5 membrane→budget→approval→port); mesh_request_id is fresh HMAC of composite input (never the raw request_id).
  - **M4 ships dormant:** zero new network egress, no x0x dep. Real transport (REST to localhost `x0x-computed`) is M4-E, blocked on x0x-compute's real model backend.
- [x] **M5** Hardening + enforced release-validation CI gate (F-6); doc-drift fix (F-9). **COMPLETE** — spec `docs/architecture/conductor-m5-release-validation-hardening-spec-2026-06-27.md`:
  - **F-9**: removed AGENTS.md ref to nonexistent `main-and-cowork-live-test-scenarios.md`; checklist notes itself as the single canonical artifact; conductor surfaces added to the mandatory-when trigger list.
  - **F-6**: enforced PR attestation gate (`.github/PULL_REQUEST_TEMPLATE.md` + `scripts/ci/guard-release-validation-pr.py` exactly-one-of N/A|done|blocker, self-tested) + `.github/workflows/release-validation.yml` (every PR, no path filter). Branch-protection "required check" is an owner-configured GitHub setting (not a code artifact) — called out honestly in the spec.
  - **F-15**: `deny_unknown_fields` + 3 recipe-level tests.
  - **M5-D**: CI now runs `cargo check --workspace --all-targets` + fae-metaopt clippy/tests (previously only fae-daemon+fae-engine).
  - F-16 (SOUL-drift metric) remains **deferred**: the classifier prerequisite is now satisfied, but F-16 still needs an explicit SOUL-drift metric + periodic-review-trigger milestone (and possibly a scheduler task). It is NOT implied that live mutation or scheduler behavior is now open — that remains a separate owner-gated decision.
- **M6** Async own-fleet (x0x-symphony) + shared intelligence (signed candidate priors; never raw memory).
- **ADR-gated:** cross-owner grants; MLS group sharing; trained coordinator model; peer-memory ingestion; auto-paid providers; async beyond same-owner spike.

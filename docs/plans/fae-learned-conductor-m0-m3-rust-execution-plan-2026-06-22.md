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
- [x] Fix MINOR: `docs/plans/retire-legacy-swift-ui-mega-prompt-2026-06-18.md` stale "you shouldn't touch crates" note → annotated with ADR-011

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
- [ ] `routing_accuracy` eval dimension + reward aggregator (reject self-judgment-only — F-10)
- [ ] **F-8:** shadow router depends on budget-governance + audit-logging WPs from M0b/M1
- [ ] Shadow router: route-decision-only by default; local-only execution under strict budget; **never** remote/paid/cross-owner
- [x] **F-11:** eval corpus methodology documented (single-annotator = David, versioned, known limitation) — *landed in `eval.rs` module docs (WP-D7)*
- [x] **F-12:** "measured improvement" = statistical significance + ≥5% relative + no regression on any measured dimension — *landed as `is_improvement()` code, not prose (WP-D7)*
- [ ] **G-M2-spec review: `plan-reviewer`** — **PASSED** (run 860ab950, 2026-06-23). v1 CONDITIONAL FAIL (5 MAJORs) → v2 resolved all → v2.1 folded 2 substantive NOTEs. Spec at `docs/architecture/conductor-m2-reward-eval-shadow-routing-spec-2026-06-23.md`.

**Impl:**
- [x] **WP-D2 — Budget governance primitive** (commits `251ae1dc`, merged to main): `BudgetGovernor` (Cost + Wall-clock + Per-day, fail-closed; token telemetry-only), `RouteFailure::BudgetExceeded` structured-only, per-day state in isolated store, `PrivacyLane::CloudBacked` + `locality_to_lane(LocalAcp)` fix. Dormant — no executor wiring. Independently gate-verified (95 tests, fmt/check/clippy clean).
- [x] **WP-D7 — Eval corpus + routing scorer** (commits `3ac27ffe`, merged to main): versioned hybrid corpus (synthetic core + membrane-scrubbed real samples), `RoutingScorer` + `score()` + `is_improvement()` (F-12 as code), scrub-before-disk test (genuine: reads file back, asserts credential absent). Dormant — no executor wiring, no aggregator, no MetaOpt. Independently gate-verified (92 tests standalone, 101 combined).
- [ ] Reward aggregator (M2 spec integration — consumes the D7 `RoutingScore` interface)
- [ ] Shadow router
- [ ] **No auto-deploy yet** — candidates compare against deployed baseline only
- [ ] **M2 executor wiring** — connects BudgetGovernor + RoutingScorer + PII membrane into the conductor routing path. GATED on G-M2-spec + both WP reviewer passes + D-M2-1 resolution.
  - **Spec §15 staging added** (commit `e66e6ad2`): 3-stage cutover. Stage 1 = egress pipeline behind `FAE_MODEL_MODE=pure-local` default (reward/shadow DEFERRED; pricing included). Stage 2 = `red-team` egress-security review (zero BLOCKER/MAJOR gate). Stage 3 = SEPARATE gated default-flip to `all-available` behind the release-validation contract. "Wiring works" ≠ "cloud on by default" — different commits.
  - **Stage 1 IN FLIGHT** (worktree-isolated builder, run `3018449f`, branch `m2/egress-wiring-stage1-pure-local`): the §5 pipeline (mode cap → membrane-before-construction → budget → approval → worker → record), pricing.rs, per-worker budget buckets, LocalAcp→CloudBackedAcp rename, tracing migration. Load-bearing acceptance: the membrane-before-construction test that FAILS ON REORDER (CloudRequestBuilder spy; credential prompt → builder invoked 0× + provider 0×). Hard constraints: default stays pure-local; reward/shadow NOT implemented.
- [ ] **G-M2 review: `reviewer`** — reward weakness, shadow-path privacy, threshold enforcement

**Reviewer pass (run 7b311b14, 2026-06-23):** Both WPs passed fresh-context adversarial review with **zero BLOCKER / zero MAJOR**. D2: 8 constraint surfaces verified (fail-closed, token-not-gated, BudgetExceeded structured-only, no executor wiring, CloudBacked placement, per-day privacy, engineering contract, test quality). D7: F-12 `is_improvement` confirmed as real code (4 conditions incl. real McNemar exact test), scrub-before-disk confirmed genuine (round-trip test reads file back), no aggregator/MetaOpt/auto-deploy, F-11 documented. **MINOR findings deferred:** D2 `daily_window>0` validation → M2 wiring (fail-closed not weakened); D2 `eprintln!`→`tracing` → M2 wiring; D7 `#![forbid(unsafe_code)]` parity → **fixed** (`b4e33ab4`). D2 `unwrap_or(0)` and D7 `Default` derive / O(n) `log_factorial`: non-issues, no action.

---

## M3 — MetaOpt learning  ⏳ MetaOpt Rust port DONE (merged `750a4a4a`); blocked on G-M2 impl + ADR-008 amendment for ConductorRecipe surface

**Prereqs (open Qs for David):**
- [ ] F-5: file **ADR-008 amendment** authorizing Rust-side `conductorRecipe` surface (enforceable constraints: no privacy-lane widening, no budget-cap override w/o approval, no trustedPeer/remoteProvider/star/debate) — **DRAFTED** (`docs/adr/008a-conductor-recipe-surface-amendment.md`, branch `m3/adr-008-conductor-recipe-amendment`, Proposed, awaits David's acceptance). Two-layer enforcement: Layer 1 proposal-structural (fae-metaopt), Layer 2 runtime-authoritative (M2 §5 gates). Cross-ADR dependency on the M2 §5.6 membrane-before-construction invariant.
- [x] MetaOpt-split decision: **Rust-native port** (D-M2-4 RATIFIED: PORT NOW, no bridge)
- [x] **MetaOpt primitive ported** (commit `5b9275a3`, merged `750a4a4a`): `crates/fae-metaopt/` (~1500 lines). 4 existing surfaces (Directive/ConfigKnob/Skill/MemorySeed), hill-climbing loop, 6 trait seams, 3 intentional hardening points. Reviewer pass MERGE-READY (0 BLOCKER/MAJOR). Dormant + unwired. **NO ConductorRecipe variant** (ADR-008-gated).

**Spec:**
- [ ] `MetaOptSurface::ConductorRecipe` + mutation operators (swap worker, direct↔chain, add/remove Verifier, mutate role prompt, adjust budget)
- [ ] Apply/rollback transactional; narrator copy (no router jargon)
- [ ] **F-15:** `FaeConductorRecipe` runtime-asserts against `star`/`debate`
- [ ] **F-16:** SOUL-drift proxy metric + periodic review trigger
- [ ] **G-M3-spec review: `oracle`** — ADR-008 amendment, rollback, protected-kernel

**Impl:**
- [ ] MetaOpt recipe mutation (Rust-native or bridged per decision)
- [ ] Deploy only on measured improvement + zero regression across quality/cost/latency/privacy/personality-drift
- [ ] "Undo last change" works
- [ ] **G-M3 review: `oracle` + `reviewer`** — autonomous-mutation rollback, asserts, SOUL-drift metric

---

## After M3 — remaining work (captured, ADR-gated)

- **M4** Tier-1 same-owner x0x sync (`delegate_to_mesh`) — Rust x0x crate; **F-2 egress membrane (named WP `ConductorEgressMembrane`) must close first**; **F-13** server↔pipeline contract; **F-14** x0x crate API confirmed.
- **M5** Hardening + enforced release-validation CI gate (F-6); doc-drift fix (F-9).
- **M6** Async own-fleet (x0x-symphony) + shared intelligence (signed candidate priors; never raw memory).
- **ADR-gated:** cross-owner grants; MLS group sharing; trained coordinator model; peer-memory ingestion; auto-paid providers; async beyond same-owner spike.

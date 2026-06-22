# Fae Learned Conductor — D1–D7 Staged Plan

> Status: **Plan (v3 — Rust-core, post-ADR-011)** · 2026-06-22 · Owner: David Irvine
> Architecture: **headless Rust core is canonical** ([ADR-011](../adr/011-headless-rust-core-runtime.md), owner decision 2026-06-22). All conductor code targets the Rust core (`crates/`); the Swift app is migration/legacy only.
> Synthesizes three cluster work-packages + one adversarial review + the ADR-011 architecture correction.
> Cluster detail: [`plan-cluster-core-D1-D4-D5-D6.md`](./plan-cluster-core-D1-D4-D5-D6.md), [`plan-cluster-x0x-D2-D7.md`](./plan-cluster-x0x-D2-D7.md), [`plan-cluster-guardrails-D3-crosscutting.md`](./plan-cluster-guardrails-D3-crosscutting.md).
> Anchor: [`sakana-fugu-vs-fae-conductor-2026-06-22.md`](./sakana-fugu-vs-fae-conductor-2026-06-22.md).
> Execution tracker: [`../plans/fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md`](../plans/fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md).

## v3 changes (vs v2)

**ADR-011 (2026-06-22) re-establishes the headless Rust daemon as canonical.** This dissolves v2's F-1 blocker entirely — the `conductor-tier1-own-fleet` Rust-core design was *right*; the stale Swift-only guardrails were wrong. Concrete shifts:

- **All conductor code targets Rust** (`crates/fae-daemon/src/conductor/` for M0, promotable to a `crates/fae-conductor` crate later). No new Swift conductor surfaces.
- **x0x integrates as a Rust crate directly** in the daemon — no Swift↔x0xd REST/WS boundary required. The original Tier-1 design (`MeshDelegationClient`/`Server` in the Rust daemon) is the target.
- **F-1 is deleted** (was: "conductor-tier1 Rust-core conflicts with AGENTS.md Swift-only" — no longer a conflict; AGENTS.md reconciled by ADR-011).
- **New explicit dependency: MetaOpt is currently Swift.** M3 (learned recipe mutation) requires either a Rust-native MetaOpt/gate port or a temporary control-plane bridge. The Rust-native port is the recommended target.

All other v2 review fixes (F-2 egress membrane, F-3 direct-default, F-4 fingerprint, F-5 ADR-008 amendment, F-6 CI gate, F-7 standing autonomy, F-8 shadow deps, F-9 doc drift, F-10 implicit-signal weighting, F-11/12 eval methodology + thresholds, F-13 integration contract, F-15 runtime asserts, F-16 SOUL-drift metric) carry forward unchanged — they are architecture-agnostic.

## The thesis (one line)

Make Fae's routing judgment itself **learned** — by extending a Rust-native MetaOpt loop — over a heterogeneous pool of local models, ACP agents, and (later) x0x peers. This is the single Fugu insight (TRINITY: a ~0.6B + 10K evolutionary coordinator delegating Thinker/Worker/Verifier roles) grafted onto Fae's existing safety substrate. All seven decisions (D1–D7) fold into one staged build.

## Decisions → milestones

| Decision | Settled in milestone | Recommendation |
|---|---|---|
| **D1** conductor shape | M0 types, M1 policy | E4B butler (Rust engine) + learned routing policy via Rust MetaOpt. **No trained coordinator in v1.** |
| **D4** storage | M0 | Rust-side conductor store (telemetry + candidates). Never the main memory store except via the memory ingest gate. |
| **D6** topology set | M1 | `direct` + `chain` (Thinker→Worker→Verifier) only. `direct` is **default**; `chain` opt-in until M2 proves it. |
| **D5** reward signal | M2 | routing_accuracy eval + implicit signals (weighted below) + limited shadow routing. **Reject pure self-judgment.** |
| **D3** visibility | M1 (copy), M4 (x0x) | L0–L4 progressive disclosure. Never Fugu-opacity. |
| **D7** sync vs async | M4 sync, M6 async | `delegate_to_mesh` same-owner first, via Rust x0x crate. |
| **D2** cross-group boundary | M4 same-owner, M6 signed hints, rest ADR-gated | No raw memory. Signed aggregate priors only. |

## Milestones, dependencies, gates

### M0 — Reconciliation + behavior-free scaffolding
**M0a (docs — do first, no code):** ADR-011 accepted; AGENTS.md / CURRENT_STATE.md / ADR README / conductor-tier1 reaffirmation done; `scripts/ci/guard-no-rust-reintro.sh` retired or inverted.
**M0b (Rust scaffolding, behavior-free):** conductor value types (`FaeConductorRecipe`, `ConductorRole` Thinker/Worker/Verifier, `ConductorTopology` direct|chain, `WorkerSelector`, `PrivacyLane`, budget/escalation/aggregation/stop policies); telemetry event types + route receipt types; the Rust-side conductor store schema (telemetry + recipe tables — confirm the Rust data-dir/storage convention before assuming a filename; do **not** assume Swift's `improvement.db` exists in Rust). No runtime routing change.
**Location:** `crates/fae-daemon/src/conductor/` (promotable to `crates/fae-conductor` later).
**Review gate:** `reviewer` on M0a (stale-Swift-reference sweep, ADR consistency); `reviewer` + `oracle` on M0b before proceeding. **M0b does not start until M0a review passes.**

### M1 — Static recipes (local + ACP runners only; `direct` DEFAULT, `chain` opt-in)
**WPs:** `ConductorRoutingPolicy` (static; local/ACP only; denies mesh/peer/remote) · `direct` + `chain` executor with role-conditioned prompts · progressive-disclosure copy (L0 invisible, L1 status, L4 opt-in team view) · approval matrix.
**F-3 fix:** `direct` is default; `chain` opt-in until M2 establishes a measured baseline.
**F-7 prereq:** standing-autonomy policy decided before M1 start — **RESOLVED 2026-06-22: tiered model (Tier A autonomous in M1; Tier B/C in M2). Seam (`ApprovalClass`) added in M0b.**
**Review gate:** `plan-reviewer` on the M1 spec before implementation.

### M2 — Reward & eval + shadow routing
**WPs:** `routing_accuracy` eval dimension + reward aggregator (reject self-judgment-only) · shadow router (route-decision-only by default; local-only execution under strict budget; never remote/paid/cross-owner) · cost/latency budget governance.
**F-8:** shadow router depends on budget-governance + audit-logging WPs landing first.
**F-10:** implicit signals weighted below `routing_accuracy`; cannot override a measured regression.
**F-11/12:** eval corpus methodology documented (single-annotator, versioned); "measured improvement" = statistical significance + ≥5% relative + no regression on any measured dimension.
**Review gate:** `reviewer` focused on reward-signal weakness + privacy leakage before M3.

### M3 — MetaOpt learning  *(blocked on ADR-008 amendment + MetaOpt Rust port)*
**WPs:** new `MetaOptSurface::ConductorRecipe` + mutation operators (swap worker, direct↔chain, add/remove Verifier, mutate role prompt, adjust budget; apply/rollback transactional; narrator copy).
**F-5 (blocker):** file the **ADR-008 amendment** before M3 begins, explicitly authorizing the Rust-side `conductorRecipe` surface with enforceable constraints (no privacy-lane widening, no budget-cap override without approval, no `trustedPeer`/`remoteProvider`/`star`/`debate` enablement).
**MetaOpt split (new in v3):** MetaOpt currently lives in Swift. M3 requires either (a) a **Rust-native MetaOpt/gate-receipt port** (recommended target), or (b) a temporary control-plane bridge (Rust emits route telemetry; Swift MetaOpt proposes recipe JSON back to the daemon). The bridge is faster but architecture-ugly; the port is cleaner.
**F-15:** `FaeConductorRecipe` initializer runtime-asserts against `star`/`debate`.
**F-16:** SOUL-drift proxy metric + periodic review trigger.
**Review gate:** `oracle`/`reviewer` on ADR-008 amendment + autonomous-mutation rollback + protected-kernel boundaries.

### M4 — Tier-1 same-owner x0x sync (`delegate_to_mesh`)
**WPs:** `fae.delegate/v1` envelope · `MeshDelegationClient`/`Server` in the Rust daemon (x0x crate linked directly — no REST/WS indirection) · `X0xAgentRunner` conformer (timeout→local fallback) · same-owner `CapabilityIndex` · partition-tolerant fallback.
**F-2 (blocker, carried):** the egress membrane (`PrivacyFilterBridge` was missing) is a named WP — `ConductorEgressMembrane` — with concrete acceptance criteria. M4 can't exit until its tests pass.
**F-13:** `MeshDelegationServer` → Rust pipeline integration contract defined before implementation (privacy/egress guards inherited, not bypassed).
**F-14:** confirm x0x crate API surface for direct-message request/response before implementation (read the x0x crate; the Tier-1 doc already cites `ExecService`, `send_direct`, `DmAckWaiter`).
**Review gate:** `red-team` on the egress membrane + same-owner boundary.

### M5 — Hardening + release validation
**WPs:** release-validation update (fix the doc drift F-9: absorb `main-and-cowork-live-test-scenarios.md` into `app-release-validation.md`, update `AGENTS.md` to point at it) · new comprehensive spec `16-conductor-routing.yaml` · real-app + real-audio + screenshots · partition/fallback UX copy.
**F-6:** release gate is **enforced** — CI job / required PR checklist blocking merge to `main` until the full run set executes and attaches results.
**Review gate:** live validation contract signed off.

### M6 — Async own-fleet + shared intelligence (ADR-gated)
**WPs:** x0x-symphony own-fleet async (create work → claim → workspace → signed handoff) · shared intelligence as candidate priors (signed routing heuristics / eval outcomes / topology hints; **never** raw memory; **never** auto-overwrite the memory store; TTL'd; never block on quorum).
**Review gate:** full red-team + oracle before any cross-group path.

### ADR-gated (NOT in v1)
- Pairwise cross-owner capability grants
- MLS group intelligence sharing (needs TreeKEM/G5 production)
- Trained coordinator model / RL pipeline (Conductor-7B path)
- Peer-memory ingestion / new memory schema
- Auto-selected paid remote providers
- x0x-symphony async beyond same-owner spike

## Top-5 cross-cutting risks (full register in guardrails doc)

1. **Memory/privacy violation** — egress membrane (F-2), memory isolation, audit. Gates M0/M3/M6.
2. **SOUL drift (Fae becomes a router)** — progressive disclosure, team view opt-in, live UX validation + SOUL-drift metric (F-16). Gates M1/M4/M5.
3. **Cost runaway with remote models** — approval matrix, budgets, receipts. Gates M2/M4/M5.
4. **MetaOpt architecture split (new in v3)** — Swift MetaOpt vs Rust conductor. Mitigation: Rust-native port in M3, or an explicit temporary bridge with a deprecation date.
5. **Release-validation underestimated** — enforced CI gate (F-6) + doc-drift fix (F-9). Hard gate M5.

## What's safe to build now vs. needs ADR

- **Safe (after M0a review):** M0b → M1 → M2 → M3 (Rust conductor scaffolding, static recipes, reward/eval, MetaOpt port — all local/ACP only, in the Rust core). M4 same-owner x0x sync after the egress membrane (F-2) closes.
- **Needs ADR first:** ADR-008 amendment for M3 autonomous recipe mutation; anything in the "ADR-gated" list above. (ADR-011 already covers the Rust runtime itself.)

## Open questions for David

1. **Standing autonomy (F-7, prereq for clean M1):** always-approve for non-local in v1, or standing delegation policies? *Default proposal: always-approve v1; standing autonomy deferred.*
   **→ DECIDED 2026-06-22:** Tiered model — Tier A (`ApprovalClass::None`, local/local-ACP) autonomous in M1; Tier B (standing grant) and Tier C (per-turn) specified in M2. The `always-approve non-local in v1` default was *rejected* as both too conservative (it would force 3 approvals per chain turn once M3 enables topology) and mis-scoped (M1 has no non-local routes). Seam added in M0b so M2 wires approval without routing-call-site retrofit.
2. **MetaOpt split (new in v3):** Rust-native port (cleaner, recommended) or temporary control-plane bridge (faster)? This decides M3's shape.
3. **ADR-008 amendment (F-5):** OK to file it authorizing the Rust-side `conductorRecipe` surface?
4. **Conductor crate:** new `crates/fae-conductor` from the start, or `crates/fae-daemon/src/conductor/` promoted later?
5. **Cross-group intelligence scope in M6:** aggregate routing stats only, or also project-specific knowledge?

## Appendix — v2 adversarial review findings (all 16, status under v3)

| # | Sev | v2 issue | v3 status |
|---|---|---|---|
| F-1 | BLOCKER | conductor-tier1 Rust-core vs AGENTS.md Swift-only | **DISSOLVED** by ADR-011 — Rust core is canonical |
| F-2 | BLOCKER | `PrivacyFilterBridge` missing, no rebuild plan | Named WP `ConductorEgressMembrane`; gates M4 |
| F-3 | BLOCKER | Ships `chain` as default without baseline | `direct` default; `chain` opt-in until M2 |
| F-4 | MAJOR | `user_text_fingerprint` undefined | HMAC-SHA-256 per-install key, request_id-scoped, TTL'd |
| F-5 | MAJOR | Recipe mutation not in ADR-008 | ADR-008 amendment required before M3 |
| F-6 | MAJOR | Release gate decorative | Enforced CI gate blocking merge |
| F-7 | MAJOR | Standing autonomy unresolved | **RESOLVED 2026-06-22** — tiered model; Tier A autonomous in M1; seam in M0b |
| F-8 | MAJOR | Shadow router deps on M4 guardrails | Explicit M0/M1 dependency before M2 |
| F-9 | MAJOR | AGENTS.md checklist path wrong | Absorb into app-release-validation.md + update AGENTS.md |
| F-10 | MAJOR | Implicit signals noisy | Weighted below routing_accuracy |
| F-11 | MINOR | eval corpus no labeler method | Documented single-annotator + versioning |
| F-12 | MINOR | threshold undefined | Sig + 5% relative + no-regression |
| F-13 | MINOR | Server↔pipeline integration undefined | Contract defined before M4 impl |
| F-14 | MINOR | x0x endpoints unverified | Read x0x crate API before M4 impl |
| F-15 | MINOR | star/debate no code enforcement | Runtime assert in recipe init |
| F-16 | MINOR | SOUL drift no measurement | Proxy metric + periodic review trigger |

**What the v2 reviewer confirmed is sound (carried to v3):** rejecting pure self-judgment for reward; the ADR-gated list; M6 shared-intelligence design; D6 topology set; L0–L4 progressive disclosure; x0x via Rust crate (now even more direct under ADR-011).

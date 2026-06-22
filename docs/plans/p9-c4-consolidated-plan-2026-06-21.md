# P9 / C4 — Consolidated implementation plan (AUTHORITATIVE, 2026-06-21)

> **This is the single source of truth for P9/C4.** It supersedes and folds in:
> - `p9-training-seam-gates-design-2026-06-21.md` (original design — C1 as-built + C4 sketch)
> - `p9-c4-gate-integrity-addendum-2026-06-21.md` (the load-bearing integrity design)
>
> Every comment from the three design reviews (Claude code-reviewer, Codex, third reviewer) is
> tracked in the matrix in §2 with a fix and a closing test. **Definition of Done (§6): every row in
> §2 is `CLOSED` with a passing test, and `just check` is green.** Branch `feat/p9-training-seam-gates`.
> All work is macOS-testable; no Linux host needed.

---

## 1. Scope

- **C1 — `TrainingBackend` seam: DONE.** Shipped in PR #20 `11735755`
  (`Sources/Fae/Scheduler/TrainingBackend.swift`: `AdapterKind`, `AdapterCandidate`,
  `protocol TrainingBackend`, `MlxTuneBackend`, `PeftDaemonBackend`). No further C1 work; this plan
  only consumes `AdapterCandidate.kind`.
- **C4 — mandatory, fail-closed eval gate: THIS PLAN.** Closes the verified unsafe-deploy hole and
  every review finding below.

**The hole (verified at HEAD):** the nightly loop can deploy a freshly-trained adapter with no real
evaluation. The internal review gate (`ExternalReviewGate.runInternalReview:213-245`) passes both
**all-nil** and **all-zero** `EvalDelta`s (`compactMap` + `min() ?? 0.0`, only 4 of 5 fields, the
bridge-absent branch literally builds all-zeros at `ImprovementCycleCoordinator.swift:586-589`), and
`AdapterDeploymentManager.deploy(adapterPath:store:)` writes `currentAdapterPath` from an arbitrary
path with no proof of evaluation.

---

## 2. Findings traceability matrix (every review comment)

Severity: **B**locker / **M**ajor / **R**ecommended / **N**it. Status starts `OPEN`; impl flips to
`CLOSED` only when the linked test passes. IDs are stable references for commits/PR.

| ID | Sev | Source(s) | Finding | Fix (→ §3 / §4) | Closing test (→ §5) |
|----|-----|-----------|---------|------------------|---------------------|
| **F1** | B | rev3-M1 | Nil-delta crack: optional `EvalDelta` + `compactMap`/`min() ?? 0.0` ⇒ all-nil PASSES | `decide(MeasuredDeltas)` requires ≥1 measured correctness dim, else `.blockedNoMeasurement` (§3.1) | T-unit-decide, T-golden |
| **F2** | B | base, rev3-M1 | Zero-delta crack: bridge-absent branch builds all-zeros ⇒ PASS | Delete all-zeros at `ICC:586-589`; unmeasured ⇒ empty `measured` ⇒ block (§3.1) | T-unit-decide, T-golden |
| **F3** | B | rev3-M2, rev2, codex#1 | Receipt forgeable / state-enum is not deploy authority | Un-forgeable `GateReceipt` (single mint path + allowlist + HMAC), `deploy(receipt:)` verifies (§3.2) | T-forgery, T-golden |
| **F4** | B | rev3-M5, rev1-M1, rev2 | `AdapterDeploymentManager.deploy(adapterPath:)` is a public receipt-free bypass | Change signature to `deploy(receipt:store:)`; verify before write (§3.2, §4-W4) | T-golden, T-replay |
| **F5** | B | rev1-B1, codex#5 | ShadowEvaluator must source the **deployed** adapter, never the pending candidate | Verify `ShadowEvaluator` reads deployed path; add invariant + test (§3.5) | T-shadow-source |
| **F6** | M | rev1-M2 | `approveDeployment` can deploy a `.concern` proposal that holds no receipt | Proposal carries its receipt; approve requires a verifying receipt (§3.2) | T-approve-concern |
| **F7** | M | rev3-M3, rev2, codex#2 | Objective contradicts kept ungated paths (`personal_adapter_path`, startup auto-load) | Restate Objective loop-scoped; route hot-swap through audited out-of-gate hatch (§3.3) | T-manual-override-audited |
| **F8** | M | rev3-M4 | `FaeBenchmark --model auto` rejected ⇒ `FaeBenchmarkEvaluator` blocks the MLX lane too | Fix `--model auto` + adapter-mode JSON schema; ships with C4-capability MLX lane (§3.4, §4-W7) | T-benchmark-auto |
| **F9** | M | rev1-M3, rev3-R4 | TOCTOU: sha checked at decision, engine loads by path later | Verify digest at deploy decision; document load path trusted (scope G2) (§3.2) | T-tamper |
| **F10** | M | rev3-R4, codex#5 | MLX-dir hashing unstated (path hash meaningless for a dir) | Canonical recursive sorted content manifest + symlink-escape validation (§3.2) | T-mlxdir-digest |
| **F11** | M | rev2, codex#4 | Recovery too narrow: pre-P9 `.training`/`.evaluating` can hold an ungated live candidate | Recovery repairs ANY non-idle state lacking a verifying receipt → `.idle`/blocked (§3.6) | T-recovery |
| **F12** | M | rev3-R3 | Evaluator baseline is base model, not the live deployed adapter (can pass while regressing) | Baseline = deployed adapter (scale-0 = deployed); record `baseModelId`/deployed in receipt (§3.4) | T-baseline-deployed |
| **F13** | M | rev3-M2, codex#5 | Receipt schema underspecified (replay/identity) | Add cycleId, kind, digest, measured, evaluatorId, baseModelId, evalSuiteVersion, gatePolicyVersion, receiptVersion; single-use (§3.2) | T-replay, T-policy-version |
| **F14** | M | rev3-R1 | Silent nightly dead-loop: C4-safety w/o `DaemonABEvaluator`; no ActionItem surface exists | Refuse-to-train a lane with no evaluator (audited `lane_no_evaluator`); surface in briefing (§3.7, §4-W6) | T-no-evaluator-refuses-train |
| **F15** | M | rev1-m2 | State-split + fail-closed must land atomically or "loop blocks" isn't delivered | Single PR; W2+W3+W4 are one atomic change; ordering enforced (§4) | T-golden |
| **F16** | M | codex#3, rev3-R5, rev1-m3 | Must NOT call `reviewGate.review` on unavailable/failed eval | `.blockedNoMeasurement` short-circuits to audited block → `.idle`, no `review()` (§3.1). **Deferred W1→W4** (lands with audited candidate_blocked + receipt backstop; W1 already fail-closes via the gate rule so no deploy occurs). | T-golden (review spy = 0 calls) |
| **F17** | R | rev3-R2 | Rollback re-promotion is ungated | Allowed (path was once receipt-verified) but emits audited `rollback` event (§3.3) | T-rollback-audited |
| **F18** | R | rev3-R5 | `EvalOutcome` collides with `ShadowEvaluator`; `EvalDelta`/`AdapterDeltas` duplication | Rename evaluator outcome `GateOutcome`; keep single `EvalDelta` transport; `baseModelId` on candidate inputs (§3.8) | compiles; T-naming (grep guard) |
| **F19** | R | rev1-n2, codex#4 | `try?`-swallowed errors on persistence; new receipt writes must fail loud | Use real `try` on receipt/state writes; surface failures (Rule 12) (§3.6) | T-receipt-write-fails-loud |
| **F20** | R | rev3-missing | No golden production-wiring E2E test (highest-value regression guard) | Add `testGoldenProductionWiring_*` with real object graph (§5) | T-golden |
| **F21** | R | rev3-missing | `AdapterKind`↔engine mismatch possible at deploy (gguf→MLX or dir→daemon) | Deploy-time lane check: gguf→daemon, mlxDir→MLX; mismatch blocks (§3.3) | T-kind-engine-mismatch |
| **F22** | R | rev3-missing | `pendingAdapterPath` cleanup on block/reject/deploy | Clear pending path + unconsumed receipt on every terminal transition (§3.6) | T-pending-cleanup |
| **F23** | R | rev3-missing, codex#5 | Eval-set drift / false-pass; evaluator is the trust root | `evalSuiteVersion` in receipt; `gatePolicyVersion` bump invalidates stale receipts (§3.2, open Q3) | T-policy-version |
| **F24** | N | rev1-m1 | Stale line numbers throughout the original design doc | Re-anchor to symbols in this plan; cite symbols not line numbers | review |
| **F25** | N | rev1-n1, codex#2 | Owner-override provenance receipt? | Open Q1 — default: audited security-event log only, out-of-gate (§7) | n/a (decision) |
| **F26** | — | rev1-B2 | "Migration mechanism doesn't exist" | **REFUTED at HEAD** — `ImprovementStore:222-243` already does guarded `ALTER TABLE ADD COLUMN`. Follow that pattern. | `CLOSED-NOACTION` |

> Already-folded Codex APPROVE-WITH-CHANGES items from the base doc (persisted receipt, fence bypass,
> never-review-unavailable, migration+recovery, shadow-on-deployed, update broken tests) map to
> F3/F4, F11, F16, F5, and §5 respectively — kept here so nothing is lost.

---

## 3. Design (the fixes)

### 3.1 Gate rule — measured-or-blocked (F1, F2, F16)
`EvalDelta` (optional fields) stays the transport. The gate consumes `MeasuredDeltas` where a `nil`
field means **not measured** (NOT 0.0):

```swift
struct MeasuredDeltas: Sendable {
    let measured: [GateDimension: Double]   // .toolCalling/.faeCapability/.assistantFit/.serialization
    let throughputDelta: Double?            // advisory only — never gates
}
enum GateDecision: Sendable { case pass, concern, fail, blockedNoMeasurement }

func decide(_ d: MeasuredDeltas) -> GateDecision {
    let v = Array(d.measured.values)
    guard !v.isEmpty else { return .blockedNoMeasurement }   // nothing measured
    if v.contains(where: { $0 < -5.0 }) { return .fail }
    if v.contains(where: { $0 < 0.0 })  { return .concern }
    if v.contains(where: { $0 > 0.0 })  { return .pass }     // ≥1 real improvement, no regression
    return .blockedNoMeasurement                              // all-flat ≈ non-measurement
}
```
- An all-flat (all-zero) measured result is treated as `.blockedNoMeasurement`: it is
  indistinguishable from a non-measurement and must not auto-deploy (matches the §5 truth table).
- Delete the all-zeros `EvalDelta` at `ICC:586-589`; the bridge-absent / benchmark-unavailable path
  yields **empty `measured`** (`EvalDelta.unmeasured`, all-nil). **[DONE in W1.]**
- **W1 (landed):** the gate rule itself fail-closes — `runInternalReview` delegates to
  `AdapterGate.decide`, so internal review can never certify an unmeasured/all-flat candidate. A
  test/interim `injectedMeasuredDelta` seam (formalized by W7's `AdapterEvaluator`) lets the gate be
  exercised with a real measured delta. The loss-proxy is demoted to advisory logging.
- **W4 (F16):** the coordinator additionally **short-circuits** a `.blockedNoMeasurement` candidate —
  audited `candidate_blocked(reason)`, clear pending (§3.6), `forceIdle`, and **do not** call
  `reviewGate.review`, **do not** enter `.proposing`. (Deferred from W1 to land with the audited
  candidate_blocked state + the receipt deploy gate, which is the real backstop; until then an
  unmeasured candidate still *fails* internal review, so it cannot deploy.)
- Loss-proxy (`lossBasedEvalDelta:805-822`) may annotate proposal text but contributes **zero**
  entries to `measured`.

### 3.2 `GateReceipt` — un-forgeable, single-use, lane-correct (F3, F4, F9, F10, F13, F23)
Threat model: local single-user; the real risk is **accidental re-opening** (a future path, a test
helper in prod, a stale row), not a motivated local attacker. Controls are structural; HMAC is
tamper-evidence/defense-in-depth.

```swift
struct GateReceipt: Codable, Sendable {
    let cycleId, candidatePath: String
    let kind: AdapterKind
    let artifactDigest: String       // §3.2 digest, NOT a path hash
    let measured: [String: Double]
    let decision: String             // only "pass" is ever persisted
    let evaluatorId: String          // must be on allowlist
    let baseModelId: String          // evaluated against THIS deployed baseline (F12)
    let evalSuiteVersion: String
    let gatePolicyVersion: Int        // bump when decide() changes ⇒ old receipts invalid
    let receiptVersion: Int
    let mintedAt: String
    let hmac: String                  // HMAC-SHA256 over canonical encoding, key in Keychain
    // No accessible public init — minted ONLY through the evaluator seam.
}
```
- **Single mint path:** only `AdapterEvaluator` conformers can construct a verifying receipt (move-only
  `GateMinter` capability, or module-internal init + mint-time allowlist assertion). No other type can
  produce a receipt whose HMAC verifies.
- **Allowlist:** `allowedEvaluators = ["DaemonABEvaluator","FaeBenchmarkEvaluator"]`; loss-proxy absent.
- **Digest (kind-driven):** `.gguf` = file SHA-256; `.mlxDir` = recursive **sorted content manifest**
  (`sort by relpath; hash relpath\0fileSHA\0…; SHA-256 the whole`) with symlink-escape validation (F10).
- **Single-use:** `consumed_at` stamped in the SAME transaction as `pending → current`; consumed or
  `gatePolicyVersion`-stale receipts fail verification (F13/F23).
- **TOCTOU (F9):** `verify` recomputes the digest at the deploy decision and requires equality. G2 is
  scoped to "tamper-evidence at deploy decision," not engine-load-time binding (owner's machine trusted).
- **Key:** per-install random `SymmetricKey` in **Keychain**, not `fae.db`, created first run.

### 3.3 Deploy boundary — receipt is the only authority (F4, F6, F7, F17, F21)
| Sink (HEAD) | Change |
|---|---|
| Auto-loop deploy (`ICC` post-PASS, `:646`+) | promote `pending→current` only via `deploy(receipt:)` inside one txn |
| `AdapterDeploymentManager.deploy(adapterPath:store:)` `:119` | **→ `deploy(receipt: GateReceipt, store:)`**; verify (allowlist+digest+single-use+policyVersion+kind↔engine) before writing `currentAdapterPath`. No raw-path prod entry. |
| `approveDeployment()` | approvable only if the held proposal carries a verifying receipt for that exact candidate; `.concern` proposals hold no receipt ⇒ not approvable (F6) |
| `rollback()` `:136` | re-promotes a once-deployed path; allowed without fresh receipt but emits audited `rollback` event (F17) |
| `training.personal_adapter_path` → `core.swapPersonalAdapter` `FaeCore.swift:2380` | explicit **owner manual override**, out-of-gate by design; route through audited `manual_adapter_override` security event (F7) |
| Startup auto-load of `currentAdapterPath` | safe once only receipt-verified paths reach `currentAdapterPath`; add deploy-time **kind↔engine** check: gguf→daemon, mlxDir→MLX, mismatch blocks (F21) |

**Objective (restated, F7):** *"No adapter is deployed by the autonomous improvement loop without a
verifying `GateReceipt`. The owner may manually override via `training.personal_adapter_path`, which
is audited and explicitly out-of-gate."*

### 3.4 `AdapterEvaluator` seam (F8, F12)
```swift
protocol AdapterEvaluator: Sendable {
    var id: String { get }                     // on the allowlist
    func evaluate(_ candidate: AdapterCandidate, baseline: DeployedBaseline)
        async throws -> GateOutcome             // measured deltas + minted receipt on .pass
}
```
- `DaemonABEvaluator` (`.gguf`): scale-0 = **deployed adapter** (or base if none) vs scale-1 =
  candidate on a held-out set (F12). **C4-capability** (larger; may follow).
- `FaeBenchmarkEvaluator` (`.mlxDir`): existing FaeBenchmark, **with `--model auto` reject fixed**
  (`FaeBenchmark` CLI) and the adapter-mode output schema aligned to what we parse (F8). If those
  aren't fixed it must report unavailable, never silently pass.
- No evaluator for a lane ⇒ that lane is treated as "no evaluator" (F14).

### 3.5 ShadowEvaluator (F5)
Confirm `ShadowEvaluator` sources the **deployed** adapter, never `pendingAdapterPath`. Add an
explicit invariant + test; no behavior change intended — this is a correctness guard against the
state split accidentally re-pointing it.

### 3.6 State, migration, recovery, cleanup (F11, F19, F22, F26)
- **State:** add `pendingAdapterPath`, `pendingAdapterKind`, `pendingCycleId` to `ImprovementState`;
  `currentAdapterPath`/`previousAdapterPath` stay the deployed+rollback pointers.
- **Migration:** follow the existing guarded pattern (`PRAGMA table_info` + `if !contains ALTER ADD
  COLUMN`, `:222-243`) for the three new columns; `CREATE TABLE IF NOT EXISTS gate_receipts` (§ addendum).
  Exhaustive create/select/update/insert/mapper updates (codex#4).
- **Recovery (on upgrade/startup):** repair ANY non-idle state (`.training/.evaluating/.proposing/
  .deploying`) that lacks a verifying receipt for its pending/current candidate → audited
  `candidate_blocked` → `.idle`. Covers pre-P9 rows whose `currentAdapterPath` was set pre-eval (F11).
- **Cleanup (F22):** every terminal transition (block/reject/deploy-success) clears `pendingAdapterPath`
  and deletes/marks any unconsumed receipt for that cycle.
- **Fail-loud (F19):** receipt/state writes use real `try`; surfaced on failure (no `try?`).

### 3.7 Refuse-to-train without an evaluator (F14)
Before launching training for a lane, check an evaluator exists+available for that `AdapterKind`. If
not: skip with audited `lane_no_evaluator`, surface in the morning-briefing text, do not burn a
training run. (No ActionItem system exists yet — this is the interim surface.)

### 3.8 Swift hygiene (F18, F24)
Rename evaluator outcome → `GateOutcome` (avoid `ShadowEvaluator` collision); single `EvalDelta`
transport (no parallel `AdapterDeltas`); add `baseModelId`/`DeployedBaseline` to evaluator inputs;
cite symbols not line numbers going forward.

---

## 4. Implementation work breakdown (ordered)

Atomic safety set = **W2–W5 ship together** (F15); a partial split would leave a window where a
blocked lane still mutated the live path.

- **W1 — Gate rule. [LANDED]** `GateDimension`/`MeasuredDeltas`/`GateDecision`/`AdapterGate.decide` +
  `EvalDelta.measuredDeltas`/`.unmeasured` (`ExternalReviewGate.swift`); `runInternalReview` delegates
  to `decide` (fail-closes on unmeasured/all-flat); delete all-zeros branch `ICC:586-589` → `.unmeasured`;
  loss-proxy demoted to advisory; interim `injectedMeasuredDelta` seam (W7 formalizes). Closes **F1, F2**.
  (F16 — the external-review short-circuit — deferred to W4; W1's gate rule already prevents any
  unmeasured deploy by failing internal review.) Existing review-gate/proposing tests updated to the
  fail-closed semantics / a real injected measured delta.
- **W2 — Receipt type + persistence.** `GateReceipt`, `GateMinter`, allowlist, HMAC (Keychain key),
  kind-driven digest (+mlxDir manifest+symlink check), `gate_receipts` table + state columns +
  migration + mappers, single-use/consume. Closes **F3, F10, F13, F19, F23, F26(noaction)**.
- **W3 — State split.** Training writes `pendingAdapterPath`/kind/cycleId only (never
  `currentAdapterPath`); `.blockedNoMeasurement` path; cleanup on terminal transitions.
  Closes **F2(wire), F22**; enables **F15**.
- **W4 — Deploy fencing.** `AdapterDeploymentManager.deploy(receipt:store:)`; coordinator promotes via
  receipt verify (digest+allowlist+single-use+policyVersion+kind↔engine); `approveDeployment` requires
  receipt; rollback audited; `personal_adapter_path` audited out-of-gate hatch; **F16** — short-circuit
  a `.blockedNoMeasurement` candidate to audited `candidate_blocked` → `.idle` without calling
  `reviewGate.review`. Closes **F4, F6, F7, F9, F16, F17, F21**.
- **W5 — Recovery + ShadowEvaluator guard.** Upgrade/startup repair of ungated non-idle states;
  ShadowEvaluator deployed-source invariant. Closes **F5, F11**. (W2–W5 = the atomic safety PR, F15.)
- **W6 — Refuse-to-train without evaluator.** Lane evaluator-availability check + audited skip +
  briefing surface. Closes **F14**.
- **W7 — `AdapterEvaluator` seam + FaeBenchmark fixes (C4-capability).** `GateOutcome`, evaluator
  protocol, `FaeBenchmarkEvaluator` (+`--model auto`/schema fix), baseline=deployed; `DaemonABEvaluator`
  may be a tracked follow-on (lane blocks safely until it lands). Closes **F8, F12, F18**.
- **W8 — Tests.** All of §5, incl. the golden E2E. Closes **F20** and verifies all above.

> Staging: **W1–W6 + W8** is the safety release — closes the hole with NO real evaluator (loop blocks,
> audited; lanes refuse-to-train). **W7** unblocks actual personalization deploys. If `DaemonABEvaluator`
> is too large for this PR, ship it separately; the daemon lane stays safely blocked meanwhile.

---

## 5. Test plan (each maps to finding IDs)

Unit:
- **T-unit-decide** (F1,F2): truth table for `decide` incl. empty-measured→`.blockedNoMeasurement`,
  all-zero→`.blockedNoMeasurement` (NOT pass), one `-6`→`.fail`, one `-2`→`.concern`, all `+`→`.pass`.
- **T-mlxdir-digest** (F10): dir manifest stable under reorder; changes when one file mutates; symlink
  escaping root rejected.
- **T-policy-version** (F13,F23): receipt with old `gatePolicyVersion` fails verify; consumed receipt fails.
- **T-receipt-write-fails-loud** (F19): injected store-write failure propagates (no silent swallow).
- **T-naming** (F18): grep guard — no `EvalOutcome`; single `EvalDelta` definition.

Integration / golden:
- **T-golden — `testGoldenProductionWiring_noDeployWithoutReceipt`** (F15,F16,F20, exercises F1–F4):
  real object graph (temp-DB `ImprovementStore`, real `ExternalReviewGate` with a **review spy**, real
  `AdapterDeploymentManager`, stub `TrainingBackend`, Keychain key). **No evaluator** ⇒
  `currentAdapterPath` unchanged, `.idle`, audited `candidate_blocked`, **review spy asserts 0 calls**,
  no `gate_receipts` row. **Stub evaluator returns `{toolCalling:+3}`** ⇒ exactly one consumed
  receipt, hmac verifies, `currentAdapterPath==candidate`, digest recomputed matches.
- **T-tamper** (F9): mutate candidate bytes after mint, before deploy ⇒ deploy refuses, path unchanged.
- **T-forgery** (F3): hand-inserted `gate_receipts` row w/ wrong hmac ⇒ verify rejects, deploy refuses.
- **T-replay** (F4,F13): consumed receipt from cycle A presented for candidate B ⇒ rejects.
- **T-approve-concern** (F6): `.concern` proposal (no receipt) ⇒ `approveDeployment` refuses to deploy.
- **T-manual-override-audited** (F7): `personal_adapter_path` swap emits `manual_adapter_override` audit,
  does not touch the gated path.
- **T-kind-engine-mismatch** (F21): gguf candidate aimed at MLX engine (or vice-versa) ⇒ blocked.
- **T-no-evaluator-refuses-train** (F14): lane w/o evaluator ⇒ training NOT launched, audited
  `lane_no_evaluator`.
- **T-recovery** (F11): seed a pre-P9 `.evaluating` row with `currentAdapterPath` set + no receipt ⇒
  upgrade repairs to `.idle`, candidate not deployed.
- **T-baseline-deployed** (F12): evaluator baseline is the deployed adapter, not base model.
- **T-shadow-source** (F5): ShadowEvaluator reads deployed path; never the pending candidate.
- **T-pending-cleanup** (F22): block/reject/deploy all clear `pendingAdapterPath` + unconsumed receipt.
- **T-benchmark-auto** (F8): `FaeBenchmark --model auto` accepted; adapter-mode JSON parses (or
  evaluator reports unavailable, never silent pass).

Update intentionally-broken existing tests (codex#6): `ImprovementCycleCoordinatorTests` nil-bridge
cases that expected `.proposing`/zero-delta pass (`:410-419, 824-842`) — they now expect
`candidate_blocked`/`.idle`; `ImprovementState` init gains fields.

Rule 9: every test encodes WHY ("an un-evaluated candidate is never deployable" / "a forged or stale
receipt never deploys") so it fails the moment someone re-opens the path.

---

## 6. Definition of Done

1. **Every row in §2 is `CLOSED`** (or `CLOSED-NOACTION` for F26) with its linked test passing.
2. `just check` green (build + full test suite) on `feat/p9-training-seam-gates`.
3. No `unwrap/expect/panic/try?` on the new gate/receipt/deploy/persistence paths (Rule 12; F19).
4. The golden E2E (T-golden) passes in both the no-evaluator (blocks) and evaluator-present (deploys
   with receipt) configurations.
5. codex review on the diff confirms no remaining ungated `currentAdapterPath` writer.
6. Base design doc + addendum carry the "superseded by this plan" banner; this plan is the reference.
7. Obsidian vault note synced (repo doc-sync rule) — **deferred until implementation is complete**
   (owner decision, 2026-06-21); do not sync mid-flight.

---

## 7. Open questions (decide before/with W7)
- **Q1 (F25):** manual-override provenance — audited security-event log only (default), or also mint a
  provenance receipt? *Leaning: log only; out-of-gate by design.*
- **Q2:** `DaemonABEvaluator` promotion threshold — reuse ShadowEvaluator's 60% win-rate, or a
  delta-threshold consistent with `decide`'s ±5%?
- **Q3 (F23):** where the held-out eval set lives + how `evalSuiteVersion`/`gatePolicyVersion` are
  provenance-tracked so bumps invalidate stale receipts.
- **Q4 (F14): RESOLVED — refuse-to-train.** A lane with no available evaluator is skipped before the
  training run (audited `lane_no_evaluator`, surfaced in the briefing); we do not burn a run to then
  block. (Owner decision, 2026-06-21.)

## 8. Risks
- **DaemonABEvaluator size** — if W7's daemon harness is too big, ship W1–W6+W8; daemon lane blocks
  safely (no regression vs today's unsafe deploy). Surfaced, not hidden.
- **Behavior change** — nightly loop stops auto-deploying until a real evaluator is wired; intended.
  The audited block + briefing text tells the user what to configure.
- **Atomicity (F15)** — W2–W5 must land together; a partial merge re-opens the window.

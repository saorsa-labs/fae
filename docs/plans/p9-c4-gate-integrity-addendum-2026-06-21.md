# P9 / C4 — Gate integrity addendum: the evaluator→receipt→deploy chain (2026-06-21)

> **Folded into `p9-c4-consolidated-plan-2026-06-21.md` (AUTHORITATIVE).** Use that plan as the
> implementation reference and its §2 matrix as the checklist; this doc is retained as the detailed
> rationale behind the gate/receipt design.
>
> Companion to `p9-training-seam-gates-design-2026-06-21.md`. This addendum fixes the
> findings that defeat the headline property ("no adapter deploys without a real eval")
> from three independent design reviews (Claude code-reviewer, Codex, third reviewer).
> Grounded against HEAD — symbols + line refs verified 2026-06-21, branch
> `feat/p9-training-seam-gates`.

## 0. Corrections to the base design doc (stale/wrong-vs-HEAD)

These must be folded into the base doc before implementation:

1. **C1 is DONE, not proposed.** `Sources/Fae/Scheduler/TrainingBackend.swift` already ships
   `AdapterKind{gguf,mlxDir}`, `AdapterCandidate{path,kind,finalLoss}`, `protocol TrainingBackend`,
   `MlxTuneBackend`, `PeftDaemonBackend` (merged PR #20 `11735755`). Rewrite the C1 section as
   "as-built"; this addendum + C4 are the only open work.
2. **The migration mechanism exists.** `ImprovementStore.createSchema` uses
   `PRAGMA table_info(improvement_state)` + guarded `ALTER TABLE … ADD COLUMN`
   (`ImprovementStore.swift:222-243`). The base doc's "additive nullable columns" plan is
   exactly this existing pattern — Review#1's "migration won't execute" is **refuted**. Follow
   the same `if !columnNames.contains(...)` guard.
3. **The real gate is `minDelta`/`compactMap`, not `sum < -0.001`.** Any base-doc text describing
   the gate as a summed-delta threshold or non-optional `EvalDelta` fields is stale. HEAD:
   `EvalDelta` fields are `Double?` (`ExternalReviewGate.swift:320-331`); the internal verdict is
   `runInternalReview` (`:213-245`).

## 1. The hole that survives the base design (verified)

`runInternalReview` (`ExternalReviewGate.swift:213-245`):

```swift
let allDeltas = [
    evalDelta.toolCallingDelta,
    evalDelta.faeCapabilityDelta,
    evalDelta.assistantFitDelta,
    evalDelta.serializationDelta,
].compactMap { $0 }            // nils silently dropped; throughputDelta NOT considered
let minDelta = allDeltas.min() ?? 0.0
if minDelta < -5.0 { .fail } else if minDelta < 0.0 { .concern } else { .pass }
```

Two ways an un-evaluated candidate scores **PASS**:

- **All-nil deltas** (e.g. a future evaluator that couldn't measure, or a parser that yields nil):
  `allDeltas == []` → `min() ?? 0.0 == 0.0` → not `< 0.0` → **PASS**.
- **All-zero deltas**: the bridge-absent branch constructs exactly this
  (`ImprovementCycleCoordinator.swift:586-589`): `EvalDelta(toolCallingDelta: 0.0, …)` →
  `minDelta == 0.0` → **PASS**.

Codex's earlier "remove the zero-delta fallback" fix addresses neither cleanly: the *type* permits
all-nil, and zero is a legal measured value. The gate must distinguish **"measured, and good"**
from **"not measured"** — today it cannot.

A second hole: the receipt the base design adds is **forgeable**. `AdapterDeploymentManager.deploy`
(`:119-126`) is `static func deploy(adapterPath: String, store:)` — it writes an arbitrary path to
`currentAdapterPath` with no proof of evaluation. Any current or future caller (or a hand-inserted
SQLite row) re-opens the loop one call away. The receipt must be **un-forgeable by construction**,
not just "present in a table."

## 2. Fix M1 — the gate requires *measured* improvement, fail-closed

Replace the "min-of-present-or-zero" rule with an explicit measured-coverage rule.

```swift
/// The result of an evaluator measuring a candidate. Distinguishes
/// "measured" from "absent" so the gate can fail-closed on absence.
struct MeasuredDeltas: Sendable {
    /// Only the dimensions actually measured this cycle. Empty == nothing measured.
    let measured: [GateDimension: Double]   // .toolCalling, .faeCapability, .assistantFit, .serialization
    // throughput is advisory-only and never gates (perf, not correctness).
    let throughputDelta: Double?
}

enum GateDecision: Sendable { case pass, concern, fail, blockedNoMeasurement }

/// Gate rule (replaces runInternalReview's min-or-zero):
/// 1. require ≥1 of the FOUR correctness dimensions measured, else .blockedNoMeasurement
/// 2. any measured dimension < -5.0           → .fail
/// 3. any measured dimension in [-5.0, 0.0)   → .concern
/// 4. all measured dimensions ≥ 0.0           → .pass
func decide(_ d: MeasuredDeltas) -> GateDecision {
    let values = Array(d.measured.values)
    guard !values.isEmpty else { return .blockedNoMeasurement }      // ← closes the nil crack
    if values.contains(where: { $0 < -5.0 }) { return .fail }
    if values.contains(where: { $0 < 0.0 })  { return .concern }
    if values.contains(where: { $0 > 0.0 })  { return .pass }        // ≥1 real improvement, no regression
    return .blockedNoMeasurement                                     // all-flat ≈ non-measurement (closes the zero crack)
}
```

Wiring consequences:
- `EvalDelta` (optional fields) is the *transport*; the gate consumes `MeasuredDeltas`. The adapter
  from `EvalDelta` → `MeasuredDeltas` drops nils into "not measured" (not into "0.0").
- **Delete the all-zeros construction** at `ImprovementCycleCoordinator.swift:586-589`. The
  bridge-absent / benchmark-unavailable path must yield **empty `measured`** → `.blockedNoMeasurement`,
  NOT a synthetic zero pass.
- `.blockedNoMeasurement` is terminal-for-this-cycle: audited `candidate_blocked`
  (reason `benchmark_unavailable`), `forceIdle`, and **do not call `reviewGate.review`** and **do
  not enter `.proposing`** (matches Codex change #3 in the base doc).
- The loss-proxy (`lossBasedEvalDelta`, `:805-822`) may still annotate the proposal text, but it
  contributes **zero entries** to `measured` — it can never satisfy `decide`.

Rule-9 test (encodes WHY): *"a cycle whose evaluator measured nothing must never reach `.proposing`
or write `currentAdapterPath`"* — fails the instant someone reintroduces a synthetic-zero or
treats `min() ?? 0.0` as a pass.

## 3. Fix M2 — `GateReceipt`: un-forgeable by construction, single-use, lane-correct hashing

### 3.1 Threat model (be honest)
This is a local single-user app; the owner already controls the machine, so the threat is **not** a
motivated attacker forging a row — it is **accidental re-opening**: a future code path, a test helper
leaking into prod, or a stale in-flight row deploying ungated. So the controls are **structural
un-forgeability + single minting path + allowlist**, with an HMAC as tamper-evidence/defense-in-depth.
(Consistent with the project's "voice identity is the security model; DamageControlPolicy is the
safety net" philosophy.)

### 3.2 Only an evaluator can mint a receipt
A receipt cannot be constructed by arbitrary code. Its initializer is unavailable outside the
evaluator seam; evaluators receive a non-`Sendable`, un-storable minting capability.

```swift
struct GateReceipt: Codable, Sendable {
    let candidatePath: String
    let kind: AdapterKind
    let artifactDigest: String     // §3.4 — content digest, NOT a path hash
    let measured: [String: Double] // the measured dimensions that produced the verdict
    let decision: String           // "pass" only ever persisted; concern/fail/block don't mint
    let evaluatorId: String        // must be on the allowlist (§3.3)
    let cycleId: String            // ties receipt to the cycle that produced it
    let baseModelId: String        // candidate evaluated against THIS base (see §5 R3)
    let evalSuiteVersion: String   // eval-set drift guard (open Q3)
    let gatePolicyVersion: Int     // bump when decide() changes; old receipts auto-invalid
    let receiptVersion: Int        // schema evolution
    let mintedAt: String           // ISO-8601
    let hmac: String               // HMAC-SHA256 over the canonical encoding of all fields above

    // No public init. Minted only via GateMinter.mint(...).
    private init(...) { ... }
}

/// Held only by the AdapterEvaluator seam; cannot be stored or forwarded.
struct GateMinter: ~Copyable {            // move-only: cannot be stashed for later forgery
    func mint(_ fields: GateReceiptFields, key: SymmetricKey) -> GateReceipt { ... }
}
```

If move-only ergonomics are awkward in the target toolchain, fall back to: receipt init is
`internal` to the evaluator module + a runtime assertion that `evaluatorId` is on the allowlist at
mint time. The non-negotiable property: **no type outside `AdapterEvaluator` conformers can produce a
`GateReceipt` whose `hmac` verifies.**

### 3.3 Evaluator allowlist
```swift
static let allowedEvaluators: Set<String> = ["DaemonABEvaluator", "FaeBenchmarkEvaluator"]
```
`verify(receipt:)` rejects any `evaluatorId ∉ allowedEvaluators`. The loss-proxy is **not** on the
list and has no `GateMinter`, so it structurally cannot gate.

### 3.4 Lane-correct artifact digest (`kind` drives it)
- `.gguf`: SHA-256 of the file bytes.
- `.mlxDir`: a **canonical content manifest** — recursively walk the dir, sort entries by relative
  POSIX path, hash `relpath \0 fileSHA256 \0` for each, SHA-256 the concatenation. Validate no
  symlink escapes the dir root before hashing. (A path-string hash is meaningless for a directory.)

`verify(receipt:)` recomputes the digest for `receipt.kind` and requires equality — closing the
re-point gap (receipt for A, file swapped to B).

### 3.5 Single-use
Receipts are consumed on use: `gate_receipts.consumed_at` is stamped inside the same transaction
that promotes `pending → current`. A consumed (or `gatePolicyVersion`-stale) receipt fails
verification. Prevents replay of an old passing receipt onto a new candidate.

### 3.6 Persistence (follows the existing migration convention)
New table, created in `createSchema` alongside the others:
```sql
CREATE TABLE IF NOT EXISTS gate_receipts (
    cycle_id            TEXT PRIMARY KEY,
    candidate_path      TEXT NOT NULL,
    kind                TEXT NOT NULL,
    artifact_digest     TEXT NOT NULL,
    measured_json       TEXT NOT NULL,
    evaluator_id        TEXT NOT NULL,
    base_model_id       TEXT NOT NULL,
    eval_suite_version  TEXT NOT NULL,
    gate_policy_version INTEGER NOT NULL,
    receipt_version     INTEGER NOT NULL,
    minted_at           TEXT NOT NULL,
    hmac                TEXT NOT NULL,
    consumed_at         TEXT
);
```
New `improvement_state` columns via the **same guarded ALTER pattern** (`:222-243`):
`pending_adapter_path TEXT`, `pending_adapter_kind TEXT`, `pending_cycle_id TEXT`.
Writes use real `try` (not `try?`) so a receipt-write failure surfaces (Rule 12); a swallowed
write that later reads as "no receipt" would wrongly block a legitimate deploy.

The HMAC key is a per-install random `SymmetricKey` in the **Keychain** (not in `fae.db`), created
on first run. Stored separately from the receipts so a copied/edited `.db` row can't carry a valid
HMAC. (Tamper-evidence, not secrecy from the owner.)

## 4. Fix M3/M5 — fence every sink; receipt is the only deploy authority

| Sink (HEAD) | Change |
|---|---|
| Auto-loop deploy (`ImprovementCycleCoordinator`, after review PASS, `:646`+) | promote `pending → current` only via `deploy(receipt:)`; verify receipt in the same txn |
| `AdapterDeploymentManager.deploy(adapterPath:store:)` (`:119`) | **change signature** to `deploy(receipt: GateReceipt, store:)`; `verify(receipt:)` (allowlist + digest + single-use + policyVersion) before writing `currentAdapterPath`. No raw-path entry point in prod. |
| `approveDeployment()` (semi-auto) | approvable **only** if the held proposal carries a verifying receipt for that exact candidate; a `.concern` proposal has **no** receipt → not approvable into deploy |
| `rollback()` (`:136`) | re-promotes a **previously-deployed** path (which by definition once carried a receipt). Allowed without a fresh receipt, but log an audited `rollback` event (R2). |
| `training.personal_adapter_path` SelfConfig → `core.swapPersonalAdapter` (`FaeCore.swift:2380`) | explicit **owner manual override**, out-of-gate **by design**. Route through a clearly-audited `manual_adapter_override` security event; document in the Objective that the no-ungated-deploy property is **loop-scoped**, with this one audited hatch (resolves M3 contradiction). |
| Startup auto-load of `currentAdapterPath` | loads whatever the gated loop persisted; safe once §2–§4 hold (only receipt-verified paths ever reach `currentAdapterPath`). Add a deploy-time `AdapterKind`↔engine check (gguf→daemon, mlxDir→MLX) to avoid lane mismatch. |

Restate the base-doc **Objective** as: *"No adapter is deployed by the autonomous improvement loop
without a verifying GateReceipt. The owner may manually override via
`training.personal_adapter_path`, which is audited and explicitly out-of-gate."*

## 5. Recommended fixes folded in (from the three reviews)

- **R1 (don't silently dead-loop).** Shipping C4-safety without `DaemonABEvaluator` makes the daemon
  lane `train → blockedNoMeasurement → idle` every night. There is **no ActionItem surface** today
  (verified: no such system). Until one exists: **refuse to train a lane that has no evaluator** —
  check evaluator availability in the training phase and skip with an audited `lane_no_evaluator`
  reason, so we don't burn a training run to then block. Surface it in the morning briefing text.
- **R2.** Rollback re-promotion is allowed but must emit an audited event (above).
- **R3 (baseline correctness).** The evaluator's "base" must be the **currently-deployed adapter**,
  not the bare base model — else a candidate can pass while regressing vs what the user actually
  runs. Record `baseModelId`/deployed-adapter in the receipt; `DaemonABEvaluator` A/B should be
  scale-0 = *deployed adapter* (or base if none), scale-1 = candidate.
- **R4.** TOCTOU: §3.4 digest is verified at the deploy decision; document that the engine load path
  is trusted (owner's machine) — G2 is "tamper-evidence at deploy decision," not load-time binding.
- **R5 (Swift hygiene).** Rename the evaluator outcome type to `GateOutcome` to avoid collision with
  `ShadowEvaluator`'s result types; keep `EvalDelta` as the single delta transport (don't introduce a
  parallel `AdapterDeltas`); add `baseModelId` to the evaluator inputs.

## 6. Golden production-wiring E2E test (the regression guard the doc lacks)

One end-to-end test that fails if *any* path reaches a live adapter without a verifying receipt.
This is the highest-value test — it catches a future re-opening regardless of which sink reintroduces
it.

```
testGoldenProductionWiring_noDeployWithoutReceipt():
  Given a coordinator wired with the PRODUCTION object graph (real ImprovementStore on a temp DB,
        real ExternalReviewGate, real AdapterDeploymentManager, a stub TrainingBackend that
        produces a candidate, and NO evaluator configured) and a Keychain HMAC key:
  When  a full improvement cycle runs:
  Then  currentAdapterPath is UNCHANGED (still nil / still the prior deployed path),
        state is .idle,
        a candidate_blocked audit row exists with reason "benchmark_unavailable" or
            "lane_no_evaluator",
        gate_receipts has NO row for this cycleId,
        reviewGate.review was NOT called (spy asserts zero invocations).

  AND, with a stub evaluator that returns measured deltas {toolCalling:+3.0}:
  When  the cycle runs and (earned autonomy) auto-deploys:
  Then  exactly one gate_receipts row exists, hmac verifies, consumed_at is set,
        currentAdapterPath == candidate.path,
        artifactDigest recomputed from disk matches the receipt.

  AND, tamper case:
  Given a persisted passing receipt, when the candidate file bytes are mutated before deploy:
  Then  deploy refuses (digest mismatch), currentAdapterPath UNCHANGED, audited.

  AND, forgery case:
  Given a hand-inserted gate_receipts row with a plausible-looking but wrong hmac:
  Then  verify(receipt:) rejects it, deploy refuses.

  AND, replay case:
  Given a valid consumed receipt from cycle A, presented for a different candidate in cycle B:
  Then  verify rejects (consumed / cycleId mismatch), deploy refuses.
```

Supporting unit tests: `decide(MeasuredDeltas)` truth table incl. empty-measured →
`.blockedNoMeasurement`; mlxDir manifest digest stability (reorder dir walk → same digest; mutate one
file → different digest); allowlist rejection of `loss_proxy` evaluatorId; migration adds the three
state columns on an old DB and `gate_receipts` is created; recovery repairs a stale `.proposing`
row with no receipt → `.idle`.

## 7. Staging (unchanged intent, sharpened)

1. **C4-integrity (this addendum):** `decide`/`MeasuredDeltas` gate, `GateReceipt` mint+verify,
   `deploy(receipt:)`, fence all sinks, migration+recovery, golden E2E. Closes the hole even with
   **no** real evaluator (loop blocks, audited). With R1, the daemon lane refuses-to-train rather
   than nightly dead-looping.
2. **C4-capability (DaemonABEvaluator):** scale-0(deployed)/scale-1(candidate) A/B scoring harness →
   the daemon lane can actually *pass* a gate. Larger; ship together if tractable, else tracked.
3. **FaeBenchmark `--model auto` + adapter-mode JSON** fix is a prerequisite for the MLX-dir lane's
   `FaeBenchmarkEvaluator` (it currently rejects `auto` and emits a different schema) — must land
   with C4-capability for that lane, not as a footnote.

## 8. Open questions for the author
- Q1: Manual-override receipts — mint a provenance receipt for `personal_adapter_path` too (audited),
  or leave it purely as a security-event log? (Leaning: log only; it's out-of-gate by design.)
- Q2: `DaemonABEvaluator` promotion threshold — reuse ShadowEvaluator's 60% win-rate, or a delta
  threshold consistent with `decide`'s ±5%?
- Q3: `evalSuiteVersion` provenance — where does the held-out eval set live and how is it versioned
  so `gatePolicyVersion`/`evalSuiteVersion` bumps invalidate stale receipts?
- Q4: R1 — is "refuse to train a lane with no evaluator" acceptable, or do we want the training run
  to proceed and just block deploy (burning the run but exercising the pipeline)?

# P9 / C1+C4 — Training seam + mandatory eval gates: design (2026-06-21)

Branch: `feat/p9-training-seam-gates`. Reviewer-gated (codex on design + code; codex already gave a second
opinion that shaped this scope). macOS-testable; no Linux host needed.

## Objective (roadmap)

> Formalize the `TrainingBackend` seam (`prepareDataset/trainAdapter/convertAdapter/…`) across MLX/Unsloth/PEFT,
> and enforce **FaeBenchmark regression gates** on every adapter before deploy ("LoRA prevents forgetting" was
> REFUTED — gates are mandatory). **Done:** the training loop is backend-agnostic behind the seam; no adapter
> deploys without passing gates.

Codex second-opinion refinement (verified in code): the literal "FaeBenchmark mandatory" is too Apple/MLX-specific —
FaeBenchmark is MLX-backed and loads adapter **directories**, but the daemon lane produces a **GGUF**, so
FaeBenchmark cannot evaluate the daemon adapter. The portable gate is the **daemon scale-0/1 A/B eval**;
FaeBenchmark stays the Apple-lane convenience. So C4 = a lane-appropriate **mandatory, fail-closed eval gate**,
not "wire FaeBenchmark everywhere."

## Current-state findings (the real bug C4 must fix)

The nightly self-improvement loop can today **auto-deploy an adapter with no real evaluation**:

1. Training writes the candidate straight into the live `currentAdapterPath` BEFORE eval
   (`ImprovementCycleCoordinator.swift:534`).
2. No production path calls `setBenchmarkPath`, so `isBenchmarkAvailable` is false
   (`TrainingBridge.swift:194,703`) → step 6 always takes the **loss-proxy** path (`:582`).
3. Loss-proxy failure becomes a **zero delta** (`:826-830`), which the internal `ExternalReviewGate` **passes**
   (`ExternalReviewGate.swift:228`).
4. `performDeploy` deploys `state.currentAdapterPath` (`:790-797`) — i.e. whatever training produced.

Net: train → (no real eval) → review passes neutral deltas → deploy. That is the exact hole the roadmap calls out.

Additional wiring mismatches (so we don't pretend FaeBenchmark already gates the GGUF lane):
- `runBenchmark` passes `--model auto` (`TrainingBridge.swift:726`); FaeBenchmark has no `auto` and rejects unknown
  model names (`FaeBenchmark/main.swift:25,1618`).
- FaeBenchmark adapter mode writes a comparison JSON (`FaeBenchmark/main.swift:1763`), not the `models` schema
  `TrainingBridge` parses (`TrainingBridge.swift:791`).
- FaeBenchmark loads adapter **directories** via MLX (`FaeBenchmark/main.swift:478,504`); the daemon lane emits a
  **GGUF** (`ImprovementCycleCoordinator.swift:512-513`).

## Design

### C1 — `TrainingBackend` seam

Today backend choice is a branch on `daemonTrainingBaseModel != nil` (`ImprovementCycleCoordinator.swift:501`)
with two concrete `TrainingBridge` lanes (mlx-tune `launchTraining/pollUntilComplete` `:520,526`; PEFT
`trainPeftAndConvert` `:510`). Extract a protocol:

```swift
protocol TrainingBackend: Sendable {
    var id: String { get }                              // "mlx", "peft", (future) "unsloth"
    func trainAdapter(dataset: TrainingDataset) async throws -> AdapterCandidate
}
struct AdapterCandidate: Sendable {
    let path: String          // GGUF (peft/daemon) or adapter dir (mlx)
    let kind: AdapterKind     // .gguf | .mlxDir
    let finalLoss: Double?
}
```

- `MlxTuneBackend` wraps `launchTraining`+`pollUntilComplete` → `AdapterCandidate(kind: .mlxDir)`.
- `PeftDaemonBackend` wraps `trainPeftAndConvert` → `AdapterCandidate(kind: .gguf)`.
- `UnslothBackend`: **not implemented** — documented as a future conformer (Unsloth is CUDA-only, planned per
  open-gaps). The seam must not pretend it exists.
- `ImprovementCycleCoordinator` selects a backend (same condition as today) and calls `trainAdapter`; no behavior
  change to the lanes themselves — this is a refactor that makes the lane swap explicit and testable.

`AdapterKind` is what lets C4 pick the right evaluator.

### C4 — mandatory, fail-closed eval gate

**1. Split candidate state from active/deployed state.**
Add `pendingAdapterPath` to the improvement state. Training writes the candidate to `pendingAdapterPath`
(NOT `currentAdapterPath`). `currentAdapterPath`/`previousAdapterPath` remain the *deployed* + rollback pointers.
Deploy promotes `pending → current` (and `current → previous`) ONLY after the gate passes. A candidate that
fails the gate can never be deployed because it never reaches `currentAdapterPath`.

**2. `AdapterEvaluator` seam (lane-appropriate), mirroring C1.**
```swift
protocol AdapterEvaluator: Sendable {
    func evaluate(_ candidate: AdapterCandidate) async throws -> EvalOutcome  // real deltas, or .unavailable
}
```
- `DaemonABEvaluator` (GGUF lane, the portable primary gate): runs a held-out eval set through the daemon at
  `set_adapter_scale(0)` (base) vs `(1)` (candidate) and scores — this is the arch-doc-designated portable eval.
  **Staging note:** the daemon A/B *scoring* harness is new; see Staging below.
- `FaeBenchmarkEvaluator` (MLX dir lane, Apple convenience): the existing FaeBenchmark path, but only for
  `.mlxDir` candidates, and with the `--model auto` / output-schema mismatches fixed (or the evaluator reports
  `.unavailable` rather than silently passing).

**3. Fail-closed at the deploy boundary (the safety fix).**
- The loss-based proxy is **demoted**: it may annotate a proposal for a human, but it can **never** satisfy the
  gate, and a failed/zero eval is **never** a pass. Remove the zero-delta fallback as a deploy-eligible outcome
  (`:826-830`).
- If the lane's real evaluator returns `.unavailable` (or throws): persist an **audited** `candidate_blocked`
  result (reason `benchmark_unavailable` / `benchmark_failed`), surface a setup action item, and return to
  **idle**. Do **NOT** enter `.proposing` — because `approveDeployment()` deploys whatever is staged
  (`:726-735`), entering `.proposing` with an un-gated candidate would re-open the hole.
- Only a **real** eval that meets the regression threshold (no dimension regressed beyond tolerance) may move the
  candidate to `.proposing` (semi-auto) or auto-deploy (earned mode).

**4. Auto-deploy stays gated.** Earned auto-deploy (after N approved cycles) also requires a real passing eval;
fail-closed applies identically.

## Staging (so the safety fix lands even if the A/B harness is larger)

- **C1** (seam refactor) — low risk, pure structure.
- **C4-safety** (state split + remove loss/zero-delta deploy path + fail-closed-block-when-no-real-eval) —
  **this closes the hole now**, independent of whether a real evaluator exists yet. With no real evaluator wired,
  the loop will *block + audit + idle* instead of unsafe-deploying. That is the correct conservative behavior.
- **C4-capability** (`DaemonABEvaluator` real scoring harness) — makes the GGUF lane actually *pass* a gate so
  personalization can deploy. Larger; may land in the same PR if tractable, else a tracked follow-on. If deferred,
  the loop safely blocks daemon-lane deploys until it exists (no regression vs today — today it unsafe-deploys).

## Scope / non-goals

- No Linux host / no daemon tool execution (that's the separate foundation phase before P7).
- No Unsloth implementation (future conformer only).
- Don't expand FaeBenchmark to GGUF; it stays the MLX-dir evaluator.

## Verification

1. macOS: `just check` (build + test) green; new unit tests for: backend seam dispatch; state split (candidate
   never auto-promotes); fail-closed (no real evaluator → `candidate_blocked`, state stays out of `.proposing`,
   `currentAdapterPath` unchanged); loss-proxy can't satisfy the gate; a passing real eval promotes correctly.
2. Tests must encode WHY (Rule 9): e.g. "an un-evaluated candidate is never deployable" — fails if someone
   re-points deploy at `pendingAdapterPath`.
3. codex review on this design and on the diff.

## Codex design-review changes (APPROVE-WITH-CHANGES — folded in, required)

1. **Persisted gate receipt (the real deploy gate).** `pendingAdapterPath` is necessary but not sufficient —
   `performDeploy` trusts `currentAdapterPath` (`:790`). Add a persisted `GateReceipt { candidatePath, kind,
   sha256, deltas, evaluatorId, at }` in the improvement state. `performDeploy` MUST verify a receipt exists whose
   `candidatePath` == the pending candidate AND whose `sha256` matches the artifact on disk; otherwise refuse to
   deploy. The receipt — not the state enum — is the authority that "this exact artifact passed a real gate."
2. **Fence the bypass deploy paths.** `AdapterDeploymentManager.deploy(adapterPath:)` writes an arbitrary path
   straight to `currentAdapterPath` (`AdapterDeploymentManager.swift:119-124`) — restrict it to consume only a
   receipt-bearing gated candidate (or remove/mark test-only). `shouldAutoDeploy` (trust threshold, `:103`) must
   NOT imply deploy eligibility — eligibility = a valid receipt. The `training.personal_adapter_path` SelfConfig
   hot-swap is an explicit **owner manual override**: keep it, but route it through a clearly-audited
   manual-override path (logged, never via the auto-loop's gated deploy), and document it as out-of-gate by design.
3. **Never review an unavailable/failed eval.** `ExternalReviewGate.review` passes zero deltas
   (`ExternalReviewGate.swift:224-236`), so an `.unavailable`/failed evaluator must short-circuit to audited
   `candidate_blocked` → `.idle` WITHOUT calling `review` and WITHOUT entering `.proposing` (`.evaluating→.idle`
   is legal, `:31`).
4. **Migration + recovery.** `ImprovementStore` adds nullable columns (pending path, candidate kind, receipt
   fields) with read/write/mapper updates (`ImprovementStore.swift:208-220,441-470,749-766`). On upgrade, **repair**
   any persisted `.proposing`/`.deploying` state that lacks a valid receipt → `candidate_blocked`/`.idle` (an
   in-flight pre-P9 candidate must not deploy ungated after upgrade).
5. **Shadow evaluator.** It evaluates `currentAdapterPath` (`ShadowEvaluator.swift:108-185`); post-split that's the
   *deployed* adapter, not the pending candidate. For this PR, keep it pointed at the deployed adapter (correct as
   shadow A/B of what's live) and explicitly do NOT treat it as the pending candidate's gate. Document; no behavior
   change to shadow.
6. **Tests.** Update the intentionally-broken tests (nil-bridge no longer reaches `.proposing`
   `ImprovementCycleCoordinatorTests.swift:825-839,891-912`; auto-deploy no longer passes on zero delta `:414-430`;
   `ImprovementState` init gains fields). Add tests for: receipt-required deploy; receipt sha mismatch refused;
   bypass fenced; fail-closed blocks without calling review; recovery repairs ungated in-flight state.

Persist `AdapterKind` as the candidate's artifact kind (drives evaluator + receipt).

## Risks

- **Daemon A/B harness size**: if `DaemonABEvaluator` scoring is too big for this PR, ship C1 + C4-safety (the hole
  closes; daemon-lane deploys block until the evaluator lands). Surfaced, not hidden.
- **Behavior change**: nightly loop will stop auto-deploying until a real eval is wired — intended (it was deploying
  unsafely). Documented; the proposal/audit path tells the user what to configure.
- **State migration**: adding `pendingAdapterPath` to the improvement DB needs a migration; keep it additive/nullable.

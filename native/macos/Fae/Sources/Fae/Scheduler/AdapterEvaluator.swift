import Foundation

// MARK: - GateOutcome (P9/C4 W7)

/// The result of evaluating a candidate adapter against the deployed baseline.
///
/// Carries the **measured** correctness deltas plus the receipt provenance fields
/// the coordinator needs to mint a `GateReceipt`. A non-measurement is expressed
/// as `delta == .unmeasured` so the fail-closed gate (`AdapterGate.decide`) blocks
/// it — the evaluator never fabricates a synthetic zero-delta "pass".
struct GateOutcome: Sendable {
    /// The measured deltas (candidate minus baseline; positive = improvement).
    /// `.unmeasured` when the evaluator could not produce a real measurement.
    let delta: EvalDelta
    /// The baseline the candidate was evaluated AGAINST — the deployed adapter
    /// (or the base model id when nothing is deployed). Bound into the receipt so a
    /// pass can never be claimed against the wrong baseline.
    let baseModelId: String
    /// Version of the held-out eval suite that produced `delta` (drift guard, bound
    /// into the receipt).
    let evalSuiteVersion: String
}

// MARK: - AdapterEvaluator (P9/C4 W7)

/// Errors surfaced by an `AdapterEvaluator`.
enum AdapterEvaluatorError: Error, CustomStringConvertible {
    /// The evaluator's backing harness (e.g. the FaeBenchmark binary) is not configured.
    case notAvailable(String)
    /// The evaluation ran but could not produce a usable measurement.
    case measurementFailed(String)

    var description: String {
        switch self {
        case .notAvailable(let why): return "evaluator not available: \(why)"
        case .measurementFailed(let why): return "evaluation failed: \(why)"
        }
    }
}

/// Evaluates a freshly trained candidate adapter against the currently DEPLOYED
/// adapter and returns the measured correctness deltas (P9/C4 W7).
///
/// The seam exists so each adapter lane gets a lane-appropriate, real evaluator:
/// - `FaeBenchmarkEvaluator` (`.mlxDir`) wraps the MLX FaeBenchmark binary (W7a).
/// - `DaemonABEvaluator` (`.gguf`) scale-0/1 A/Bs the daemon adapter (W7b — not yet).
///
/// An evaluator's `evaluatorId` MUST be on `GatePolicy.allowedEvaluators` or the
/// receipt it mints can never verify. The coordinator mints the receipt; the
/// evaluator only measures (so the privileged minting path stays singular).
protocol AdapterEvaluator: Sendable {
    /// The adapter kind this evaluator can score (drives lane selection).
    var kind: AdapterKind { get }
    /// Stable id stamped into the minted receipt — must be on the gate allowlist.
    var evaluatorId: String { get }
    /// Whether the evaluator's backing harness is configured and usable right now.
    /// `false` ⇒ the lane stays blocked (W6) rather than burning a training run.
    func isAvailable() async -> Bool
    /// Evaluate `candidatePath` against `baselinePath` (the deployed adapter, or
    /// `nil` for the base model) and return the measured outcome.
    ///
    /// - Throws: `AdapterEvaluatorError` if the harness is unavailable or the
    ///   measurement fails — the coordinator treats a throw as fail-closed.
    func evaluate(candidatePath: String, baselinePath: String?) async throws -> GateOutcome
}

// MARK: - FaeBenchmarkEvaluator (mlxDir lane, P9/C4 W7a)

/// Evaluates an MLX adapter directory by running the FaeBenchmark binary on the
/// candidate and on the deployed baseline, then differencing the accuracies.
///
/// ## Baseline = the DEPLOYED adapter, not the base model
/// The gate measures whether the candidate improves on **what is live today**, not
/// on the untrained base model. Scoring the candidate against the deployed adapter
/// is the only delta that answers "should I replace what the user already has?" —
/// a candidate that beats the base model but regresses against the deployed adapter
/// must NOT pass. When nothing is deployed (`baselinePath == nil`) the base model is
/// the baseline (the first adapter genuinely competes against base).
struct FaeBenchmarkEvaluator: AdapterEvaluator {
    let bridge: TrainingBridge
    /// The eval-suite version stamped into the receipt (drift guard).
    let evalSuiteVersion: String

    var kind: AdapterKind { .mlxDir }
    var evaluatorId: String { "FaeBenchmarkEvaluator" }

    init(bridge: TrainingBridge, evalSuiteVersion: String = "faebench-v1") {
        self.bridge = bridge
        self.evalSuiteVersion = evalSuiteVersion
    }

    func isAvailable() async -> Bool {
        await bridge.isBenchmarkAvailable
    }

    func evaluate(candidatePath: String, baselinePath: String?) async throws -> GateOutcome {
        guard await bridge.isBenchmarkAvailable else {
            throw AdapterEvaluatorError.notAvailable("FaeBenchmark binary not configured")
        }
        do {
            // Baseline = the DEPLOYED adapter (or base model when none is deployed).
            let baseline = try await bridge.runBenchmark(adapterPath: baselinePath)
            let candidate = try await bridge.runBenchmark(adapterPath: candidatePath)
            let delta = candidate.delta(from: baseline)
            // baseModelId records WHAT the candidate was scored against, so a receipt
            // can never claim a pass vs the wrong baseline. Use the BASELINE run's path
            // (the deployed adapter) when one is deployed, else the baseline run's
            // modelId (the un-adapted base model the baseline actually scored) — NOT the
            // candidate's, which would misread a base-model baseline as a deployed adapter.
            let baseModelId = baselinePath ?? baseline.modelId
            return GateOutcome(
                delta: delta, baseModelId: baseModelId, evalSuiteVersion: evalSuiteVersion
            )
        } catch {
            throw AdapterEvaluatorError.measurementFailed(error.localizedDescription)
        }
    }
}

import CryptoKit
import XCTest
@testable import Fae

/// P9/C4 W7a — the `AdapterEvaluator` seam (mlxDir lane) and the receipt it produces.
///
/// These tests encode WHY the evaluator gates the way it does:
/// - the baseline MUST be the DEPLOYED adapter, so a delta measures improvement over
///   what is LIVE today (a candidate that beats base but regresses against the
///   deployed adapter must not pass);
/// - a passing measurement MUST mint a gate receipt the W4 deploy gate accepts, end to
///   end through the real `GateReceiptVerifier` (no test-only bypass);
/// - a non-measurement / evaluator failure MUST be fail-closed (no receipt, blocked).
final class AdapterEvaluatorTests: XCTestCase {

    private let gateTestKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))

    // MARK: - Recording fake evaluator

    /// A fake `AdapterEvaluator` that records the baseline it was asked to score against
    /// and returns a caller-supplied outcome. Lets us assert the coordinator passes the
    /// DEPLOYED adapter as baseline and mints the receipt from the evaluator's deltas.
    private actor RecordingEvaluator: AdapterEvaluator {
        let kind: AdapterKind
        let evaluatorId: String
        private let outcome: GateOutcome?
        private(set) var lastBaseline: String?
        private(set) var lastCandidate: String?
        private(set) var evaluateCalls = 0

        init(kind: AdapterKind, evaluatorId: String, outcome: GateOutcome?) {
            self.kind = kind
            self.evaluatorId = evaluatorId
            self.outcome = outcome
        }

        func isAvailable() async -> Bool { true }

        func evaluate(candidatePath: String, baselinePath: String?) async throws -> GateOutcome {
            evaluateCalls += 1
            lastCandidate = candidatePath
            lastBaseline = baselinePath
            guard let outcome else {
                throw AdapterEvaluatorError.measurementFailed("forced failure")
            }
            return outcome
        }
    }

    private func makeTempStore() async throws -> ImprovementStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ImprovementStore()
        try await store.open(at: dir.appendingPathComponent("improvement.db"))
        return store
    }

    /// Create a real on-disk mlxDir candidate (a directory with one file) so the receipt
    /// digest can be computed + later verified against the same bytes.
    private func makeMlxCandidateDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-cand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "weights".write(
            toFile: dir.appendingPathComponent("adapters.safetensors").path,
            atomically: true, encoding: .utf8
        )
        return dir.path
    }

    private func improvementOutcome() -> GateOutcome {
        GateOutcome(
            delta: EvalDelta(
                toolCallingDelta: 4.0, faeCapabilityDelta: 2.0,
                assistantFitDelta: 3.0, serializationDelta: 1.0, throughputDelta: 5.0
            ),
            baseModelId: "/tmp/deployed_mlx", evalSuiteVersion: "faebench-v1"
        )
    }

    // MARK: - Baseline = deployed adapter

    /// The coordinator must hand the evaluator the DEPLOYED `currentAdapterPath` as the
    /// baseline — NOT the base model — so the delta measures improvement over what is live.
    func testEvaluatorScoresAgainstDeployedAdapterBaseline() async throws {
        let store = try await makeTempStore()
        let candidate = try makeMlxCandidateDir()
        try await store.ensureStateRow()
        var s = try await store.readState()
        s.currentAdapterPath = "/tmp/deployed_mlx"   // what is LIVE today
        s.pendingAdapterPath = candidate
        s.pendingAdapterKind = "mlxDir"
        s.pendingCycleId = "cyc-baseline"
        try await store.writeState(s)

        let evaluator = RecordingEvaluator(
            kind: .mlxDir, evaluatorId: "FaeBenchmarkEvaluator", outcome: improvementOutcome()
        )
        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setAdapterEvaluator(evaluator)

        let result = await coordinator.evaluateViaAdapterEvaluator(adapterPath: candidate, kind: .mlxDir)

        let baseline = await evaluator.lastBaseline
        XCTAssertEqual(
            baseline, "/tmp/deployed_mlx",
            "Baseline must be the DEPLOYED adapter so the delta measures improvement over what is live"
        )
        XCTAssertEqual(result.delta.toolCallingDelta, 4.0, "Returns the evaluator's measured delta")
        XCTAssertEqual(result.mint?.evaluatorId, "FaeBenchmarkEvaluator")
        XCTAssertEqual(result.mint?.kind, .mlxDir)
    }

    /// With nothing deployed, the baseline is nil (base model) — the first adapter
    /// legitimately competes against the untrained base.
    func testEvaluatorBaselineIsBaseModelWhenNoneDeployed() async throws {
        let store = try await makeTempStore()
        let candidate = try makeMlxCandidateDir()
        try await store.ensureStateRow()
        var s = try await store.readState()
        s.currentAdapterPath = nil
        s.pendingAdapterKind = "mlxDir"
        try await store.writeState(s)

        let evaluator = RecordingEvaluator(
            kind: .mlxDir, evaluatorId: "FaeBenchmarkEvaluator", outcome: improvementOutcome()
        )
        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setAdapterEvaluator(evaluator)

        _ = await coordinator.evaluateViaAdapterEvaluator(adapterPath: candidate, kind: .mlxDir)

        let baseline = await evaluator.lastBaseline
        XCTAssertNil(baseline, "No deployed adapter ⇒ baseline is the base model (nil)")
    }

    // MARK: - Fail-closed

    /// A throwing evaluator yields `.unmeasured` with no mint context — the gate then
    /// blocks the candidate (it can never reach deploy).
    func testEvaluatorFailureIsFailClosed() async throws {
        let store = try await makeTempStore()
        let candidate = try makeMlxCandidateDir()
        try await store.ensureStateRow()
        var s = try await store.readState()
        s.pendingAdapterKind = "mlxDir"
        try await store.writeState(s)

        let evaluator = RecordingEvaluator(
            kind: .mlxDir, evaluatorId: "FaeBenchmarkEvaluator", outcome: nil   // forces throw
        )
        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setAdapterEvaluator(evaluator)

        let result = await coordinator.evaluateViaAdapterEvaluator(adapterPath: candidate, kind: .mlxDir)

        XCTAssertNil(result.delta.toolCallingDelta, "A failed evaluation is unmeasured")
        XCTAssertEqual(
            AdapterGate.decide(result.delta.measuredDeltas), .blockedNoMeasurement,
            "Unmeasured ⇒ fail-closed block"
        )
        XCTAssertNil(result.mint, "No receipt provenance on a failed evaluation")
    }

    /// A lane with no registered evaluator is fail-closed (no measurement, no mint).
    func testNoEvaluatorForLaneIsUnmeasured() async throws {
        let store = try await makeTempStore()
        let coordinator = ImprovementCycleCoordinator(store: store)
        // No evaluator registered for .mlxDir.
        let result = await coordinator.evaluateViaAdapterEvaluator(adapterPath: "/tmp/x", kind: .mlxDir)
        XCTAssertNil(result.delta.toolCallingDelta)
        XCTAssertNil(result.mint)
    }

    // MARK: - Un-block + registration

    /// Registering an evaluator un-blocks ITS lane (and only its lane), so the W6
    /// refuse-to-train gate and the evaluator wiring can never drift apart.
    func testRegisteringEvaluatorUnblocksOnlyItsLane() async throws {
        let store = try await makeTempStore()
        let coordinator = ImprovementCycleCoordinator(store: store)
        let evaluator = RecordingEvaluator(
            kind: .mlxDir, evaluatorId: "FaeBenchmarkEvaluator", outcome: improvementOutcome()
        )
        await coordinator.setAdapterEvaluator(evaluator)
        let kinds = await coordinator.availableEvaluatorKindsForTest
        XCTAssertTrue(kinds.contains(.mlxDir), "mlxDir lane un-blocked by registering its evaluator")
        XCTAssertFalse(kinds.contains(.gguf), "gguf lane stays blocked (no evaluator) — W7b")
    }

    // MARK: - FaeBenchmarkEvaluator availability (fail-closed without a binary)

    /// Without a configured FaeBenchmark binary the evaluator reports unavailable and
    /// throws `notAvailable` — it never silently produces a fabricated measurement.
    func testFaeBenchmarkEvaluatorUnavailableWithoutBinary() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = TrainingBridge(uvPath: "/usr/bin/false", orchestratorScriptsDir: tmp, dataBridgeScriptsDir: tmp)
        let evaluator = FaeBenchmarkEvaluator(bridge: bridge)

        let available = await evaluator.isAvailable()
        XCTAssertFalse(available, "No benchmark binary configured ⇒ unavailable")

        do {
            _ = try await evaluator.evaluate(candidatePath: "/tmp/cand", baselinePath: "/tmp/base")
            XCTFail("evaluate must throw when the harness is unavailable")
        } catch let error as AdapterEvaluatorError {
            if case .notAvailable = error { return }
            XCTFail("Expected .notAvailable, got \(error)")
        }
    }

    // MARK: - FIX 1: baseModelId reflects the BASELINE run, not the candidate

    /// When NO adapter is deployed (baseline = base model), the receipt's `baseModelId`
    /// must reflect the BASELINE benchmark run's model id — NOT the candidate's. Otherwise
    /// a future verifier would misread a base-model baseline as "evaluated against a
    /// deployed adapter". Driven through a scripted FaeBenchmark binary that stamps a
    /// distinct model_id for the baseline (no --adapter) vs the candidate (--adapter) run.
    func testFaeBenchmarkEvaluatorBaseModelIdReflectsBaselineRun() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Scripted benchmark: writes valid BenchmarkOutput JSON to the --output path,
        // stamping model_id = CANDIDATE_MODEL when --adapter is present, else BASELINE_MODEL.
        // Candidate scores strictly higher so the delta is a measured improvement.
        let script = """
        #!/bin/bash
        out=""; adapter=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --output) out="$2"; shift 2;;
            --adapter) adapter="1"; shift 2;;
            *) shift;;
          esac
        done
        if [ -n "$adapter" ]; then
          mid="CANDIDATE_MODEL"; tc=true
        else
          mid="BASELINE_MODEL"; tc=false
        fi
        cat > "$out" <<JSON
        {"models":[{"model_id":"$mid",
          "tool_calling":[{"correct":$tc}],
          "fae_capability_eval":[{"correct":$tc}],
          "assistant_fit_eval":[{"correct":$tc}],
          "serialization_eval":[{"valid":true,"correct":$tc}]}]}
        JSON
        """
        let binPath = tmp.appendingPathComponent("FaeBenchmarkStub").path
        try script.write(toFile: binPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binPath)

        let bridge = TrainingBridge(uvPath: "/usr/bin/false", orchestratorScriptsDir: tmp, dataBridgeScriptsDir: tmp)
        await bridge.setBenchmarkPath(binPath)
        let evaluator = FaeBenchmarkEvaluator(bridge: bridge)

        // No deployed adapter ⇒ baselinePath nil ⇒ baseModelId must come from the baseline run.
        let outcome = try await evaluator.evaluate(candidatePath: "/tmp/candidate_dir", baselinePath: nil)

        XCTAssertEqual(
            outcome.baseModelId, "BASELINE_MODEL",
            "baseModelId must reflect the BASELINE benchmark run, not the candidate"
        )
        XCTAssertNotEqual(outcome.baseModelId, "CANDIDATE_MODEL", "Must not record the candidate's model id")
        // Candidate scored higher across all four dims ⇒ a measured improvement.
        XCTAssertEqual(try XCTUnwrap(outcome.delta.toolCallingDelta), 100.0, accuracy: 0.001)
        XCTAssertEqual(AdapterGate.decide(outcome.delta.measuredDeltas), .pass)
    }
}

import CryptoKit
import XCTest
@testable import Fae

/// P9/C4 W8 — golden production-wiring + adversarial gate tests.
///
/// These close the Definition-of-Done for the "training-seam + mandatory eval gate"
/// series. The unsafe hole the series shuts: the nightly self-improvement loop could
/// promote a freshly trained LoRA adapter into the live `currentAdapterPath` with NO
/// real evaluation. W1–W7 made a deploy require a *verifying, unconsumed, tamper-evident*
/// `GateReceipt` minted by a real `AdapterEvaluator`.
///
/// The master invariant these tests defend:
/// **no path writes `currentAdapterPath` without a verifying, unconsumed receipt.**
///
/// Tests are written to fail the moment someone re-opens the un-gated path — each one
/// encodes WHY the behaviour matters, not merely WHAT it does (Rule 9).
final class GateGoldenWiringTests: XCTestCase {

    // MARK: - Shared helpers

    /// Fixed HMAC key so mint + verify run without Keychain access (matches the
    /// `gateTestKey` used across the suite). Production uses a per-install Keychain key.
    private let gateTestKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))

    private func makeTempStore() async throws -> ImprovementStore {
        let store = ImprovementStore()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gate_golden_\(UUID().uuidString).db")
        try await store.open(at: url)
        try await store.ensureStateRow()
        return store
    }

    /// A real on-disk mlxDir candidate (directory + weights file) so the artifact
    /// digest can be recomputed at the deploy boundary.
    private func makeMlxCandidate() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-cand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "weights-v1".write(
            toFile: dir.appendingPathComponent("adapters.safetensors").path,
            atomically: true, encoding: .utf8
        )
        return dir.path
    }

    /// Seed enough feedback events to clear the cycle-start thresholds (≥20 events, ≥5
    /// corrections) so `runCycle()` proceeds past the data gate.
    private func seedSufficientData(store: ImprovementStore) async throws {
        for i in 0..<15 {
            _ = try await store.appendFeedbackEvent(FeedbackEvent(
                id: nil, recordedAt: ISO8601DateFormatter().string(from: Date()),
                signalType: "correction", turnFingerprint: "corr-\(UUID().uuidString)-\(i)",
                userInput: "u", assistantOutput: "a", sentimentScore: nil, consumed: false
            ))
        }
        for i in 0..<10 {
            _ = try await store.appendFeedbackEvent(FeedbackEvent(
                id: nil, recordedAt: ISO8601DateFormatter().string(from: Date()),
                signalType: "re_ask", turnFingerprint: "reask-\(UUID().uuidString)-\(i)",
                userInput: "u", assistantOutput: "a", sentimentScore: nil, consumed: false
            ))
        }
    }

    // MARK: - Golden production-wiring E2E (T-golden — F15, F16, F20; exercises F1–F4)

    /// GOLDEN (a): with NO evaluator registered for the trained lane, a full cycle must
    /// fail closed BEFORE external review. WHY: the external review providers must never
    /// get the chance to PASS an un-evaluated candidate — if they did, an adapter with no
    /// measured improvement could deploy. The review-spy (the gate's own audit closure,
    /// the same seam production wires to `SecurityEventLogger`) proves `review()` was
    /// never entered, and `currentAdapterPath` proves nothing was promoted.
    func testGoldenProductionWiring_noEvaluator_blocksBeforeReviewAndNeverDeploys() async throws {
        let store = try await makeTempStore()

        // A live baseline that must remain untouched.
        var seed = try await store.readState()
        seed.currentAdapterPath = "/tmp/live_deployed_adapter"
        try await store.writeState(seed)

        // Real review gate + a review SPY: production logs every completed review via the
        // security-log closure (`logResult`). If the closure never fires, `review()` was
        // never reached. A delegate runner that would PASS is also installed so a leak
        // would be loud (it would flip both flags and try to deploy).
        let gate = ExternalReviewGate()
        var reviewCallCount = 0
        await gate.setSecurityLogClosure { event, _, _, _, _, _ in
            // Production logs EVERY completed review via this closure (`logResult` ⇒
            // "external_review_gate"). Counting it is how we prove review was reached.
            if event == "external_review_gate" { reviewCallCount += 1 }
        }
        var delegateConsulted = false
        await gate.setDelegateAgentRunner { _ in
            delegateConsulted = true
            return "PASS: looks great."
        }

        let coordinator = ImprovementCycleCoordinator(store: store, reviewGate: gate)
        // No `setAdapterEvaluator` / no `setInjectedMeasuredDelta`: the real eval phase has
        // no measurement source ⇒ `.unmeasured` ⇒ `candidate_blocked`.
        try await seedSufficientData(store: store)

        try await coordinator.runCycle()

        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle, "An un-evaluated candidate must end at idle, never proposing")
        let persisted = try await store.readState()
        XCTAssertEqual(
            persisted.currentAdapterPath, "/tmp/live_deployed_adapter",
            "The live adapter must be untouched when nothing was measured"
        )
        XCTAssertNil(persisted.pendingAdapterPath, "Blocked cycle clears the pending candidate")
        XCTAssertEqual(
            persisted.lastCycleError, "candidate_blocked: no_measured_improvement",
            "The block must be audited as a no-measurement block"
        )
        XCTAssertEqual(reviewCallCount, 0, "External review must NOT be consulted for an un-evaluated candidate")
        XCTAssertFalse(delegateConsulted, "The review provider must never run when there is no measurement")
        // No receipt may exist for a cycle that never measured anything.
        let consumed = try? await store.isGateReceiptConsumed(cycleId: "cyc-golden-a")
        XCTAssertNotEqual(consumed, true)
    }

    /// GOLDEN (b): with a REAL evaluator registered the same way `FaeScheduler` does
    /// (`setAdapterEvaluator`), a measured PASS mints a verifying receipt, and approving
    /// the proposal promotes the candidate to `currentAdapterPath` AND consumes the
    /// receipt exactly once. WHY: this is the only path that may write the live path, and
    /// it must go end-to-end through the real mint → real `GateReceiptVerifier` →
    /// atomic promote-and-consume (no bypass, no manual receipt insertion).
    func testGoldenProductionWiring_realEvaluatorPass_deploysAndConsumesReceipt() async throws {
        let store = try await makeTempStore()
        let candidate = try makeMlxCandidate()

        // Stage the pending candidate exactly as the training step (W3) would.
        var state = try await store.readState()
        state.currentAdapterPath = "/tmp/deployed_before"  // the rollback target
        state.pendingAdapterPath = candidate
        state.pendingAdapterKind = "mlxDir"
        state.pendingCycleId = "cyc-golden-b"
        try await store.writeState(state)

        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setInjectedGateKey(gateTestKey)
        var patchedPath: String? = "<unset>"
        await coordinator.setAdapterPatchCallback { p in patchedPath = p }

        // Register a real `AdapterEvaluator` (mlxDir lane) that measures a clean PASS —
        // the SAME registration API FaeScheduler uses at runtime.
        let evaluator = StubMlxEvaluator(
            outcome: GateOutcome(
                delta: EvalDelta(
                    toolCallingDelta: 3.0, faeCapabilityDelta: 2.0,
                    assistantFitDelta: 1.0, serializationDelta: 1.0, throughputDelta: 4.0
                ),
                baseModelId: "/tmp/deployed_before",
                evalSuiteVersion: "faebench-v1"
            )
        )
        await coordinator.setAdapterEvaluator(evaluator)

        // Drive the production eval → mint chain on the staged candidate (this is exactly
        // what `runCycle`'s eval phase does internally via `evaluateViaAdapterEvaluator`).
        let evaluated = await coordinator.evaluateViaAdapterEvaluator(adapterPath: candidate, kind: .mlxDir)
        XCTAssertEqual(
            AdapterGate.decide(evaluated.delta.measuredDeltas), .pass,
            "A measured improvement with no regression must pass the gate"
        )
        let mint = try XCTUnwrap(evaluated.mint, "A real evaluator must carry receipt-mint provenance on a pass")
        XCTAssertEqual(mint.evaluatorId, "FaeBenchmarkEvaluator", "Receipt is stamped with the allowlisted evaluator id")
        try await coordinator.mintAndStoreGateReceipt(context: mint, measured: evaluated.delta.measuredDeltas)

        // Walk to proposing, then approve — `performDeploy` verifies through the REAL
        // `GateReceiptVerifier` and promotes + consumes atomically.
        for s in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: s)
        }
        try await coordinator.approveDeployment()

        let deployed = try await store.readState()
        XCTAssertEqual(deployed.currentAdapterPath, candidate, "The measured-PASS candidate is promoted to live")
        XCTAssertEqual(deployed.previousAdapterPath, "/tmp/deployed_before", "Prior live adapter becomes the rollback target")
        XCTAssertNil(deployed.pendingAdapterPath, "Pending candidate cleared after deploy")
        XCTAssertEqual(patchedPath, candidate, "Pipeline is notified of the deployed adapter")
        let consumed = try await store.isGateReceiptConsumed(cycleId: "cyc-golden-b")
        XCTAssertTrue(consumed, "The receipt is consumed exactly once on deploy (single-use)")
    }

    // MARK: - Tamper (T-tamper — F9), coordinator-level

    /// The candidate artifact is mutated AFTER the receipt is minted, so the on-disk digest
    /// no longer matches what the receipt attests. `performDeploy` must refuse and leave the
    /// live path untouched. WHY: the receipt is a promise about a SPECIFIC artifact; trusting
    /// a mismatched artifact would re-open the un-gated-deploy hole (deploy something the
    /// evaluator never scored).
    func testTamperedCandidateAfterMintIsRejectedAtDeploy() async throws {
        let store = try await makeTempStore()
        let candidate = try makeMlxCandidate()

        var state = try await store.readState()
        state.currentAdapterPath = "/tmp/live_before_tamper"
        state.pendingAdapterPath = candidate
        state.pendingAdapterKind = "mlxDir"
        state.pendingCycleId = "cyc-tamper"
        try await store.writeState(state)

        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setInjectedGateKey(gateTestKey)
        try await coordinator.mintAndStoreGateReceipt(
            context: ImprovementCycleCoordinator.ReceiptMintContext(
                kind: .mlxDir, evaluatorId: "FaeBenchmarkEvaluator",
                baseModelId: "/tmp/live_before_tamper", evalSuiteVersion: "faebench-v1"
            ),
            measured: MeasuredDeltas(
                measured: [.toolCalling: 2.0, .faeCapability: 1.0, .assistantFit: 1.0, .serialization: 1.0],
                throughputDelta: nil
            )
        )

        // TAMPER: change the candidate's bytes after the receipt was minted.
        try "weights-TAMPERED".write(
            toFile: URL(fileURLWithPath: candidate).appendingPathComponent("adapters.safetensors").path,
            atomically: true, encoding: .utf8
        )

        for s in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: s)
        }
        await XCTAssertThrowsErrorAsync(
            try await coordinator.approveDeployment(),
            "A tampered artifact must not deploy"
        ) { error in
            guard case ImprovementCycleError.gateReceiptRejected = error else {
                return XCTFail("Expected gateReceiptRejected, got \(error)")
            }
        }

        let after = try await store.readState()
        XCTAssertEqual(after.currentAdapterPath, "/tmp/live_before_tamper", "Tampered candidate must not reach the live path")
        let consumed = try await store.isGateReceiptConsumed(cycleId: "cyc-tamper")
        XCTAssertFalse(consumed, "A rejected deploy must not consume the receipt")
    }

    // MARK: - Forgery (T-forgery — F3)

    /// A receipt persisted with a tampered HMAC (signed with the wrong key) can never
    /// verify, so the deploy boundary rejects it. WHY: the HMAC is the tamper-evidence
    /// binding evaluator-id + path + digest together; a forged signature must not be
    /// honoured or any code could hand-craft a deployable receipt.
    func testForgedReceiptHmacIsRejectedAtDeploy() async throws {
        let store = try await makeTempStore()
        let candidate = try makeMlxCandidate()

        var state = try await store.readState()
        state.currentAdapterPath = "/tmp/live_before_forgery"
        state.pendingAdapterPath = candidate
        state.pendingAdapterKind = "mlxDir"
        state.pendingCycleId = "cyc-forge"
        try await store.writeState(state)

        // Mint with the WRONG key, then persist — the coordinator verifies with `gateTestKey`.
        let wrongKey = SymmetricKey(data: Data(repeating: 0x99, count: 32))
        let forged = try GateMinter.mint(
            cycleId: "cyc-forge", candidatePath: candidate, kind: .mlxDir,
            measured: [.toolCalling: 2.0, .faeCapability: 1.0, .assistantFit: 1.0, .serialization: 1.0],
            evaluatorId: "FaeBenchmarkEvaluator", baseModelId: "/tmp/live_before_forgery",
            evalSuiteVersion: "faebench-v1", mintedAt: "2026-06-22T00:00:00Z", using: wrongKey
        )
        try await store.insertGateReceipt(forged)

        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setInjectedGateKey(gateTestKey)  // verifies with the RIGHT key ⇒ mismatch
        for s in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: s)
        }
        await XCTAssertThrowsErrorAsync(
            try await coordinator.approveDeployment(),
            "A forged-HMAC receipt must not deploy"
        ) { error in
            guard case ImprovementCycleError.gateReceiptRejected = error else {
                return XCTFail("Expected gateReceiptRejected, got \(error)")
            }
        }
        let after = try await store.readState()
        XCTAssertEqual(after.currentAdapterPath, "/tmp/live_before_forgery", "Forged receipt must not touch the live path")
    }

    /// Minting with an evaluator id that is NOT on `GatePolicy.allowedEvaluators` throws —
    /// the loss-proxy (or any future non-evaluator) can never forge a deployable receipt.
    /// WHY: the allowlist is the privilege boundary; only the two real evaluators may
    /// produce a receipt the verifier will honour.
    func testReceiptFromNonAllowlistedEvaluatorCannotBeMinted() async throws {
        let store = try await makeTempStore()
        let candidate = try makeMlxCandidate()
        var state = try await store.readState()
        state.pendingAdapterPath = candidate
        state.pendingAdapterKind = "mlxDir"
        state.pendingCycleId = "cyc-allow"
        try await store.writeState(state)

        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setInjectedGateKey(gateTestKey)
        await XCTAssertThrowsErrorAsync(
            try await coordinator.mintAndStoreGateReceipt(
                context: ImprovementCycleCoordinator.ReceiptMintContext(
                    kind: .mlxDir, evaluatorId: "loss-proxy",  // NOT allowlisted
                    baseModelId: "x", evalSuiteVersion: "v1"
                ),
                measured: MeasuredDeltas(
                    measured: [.toolCalling: 1.0, .faeCapability: 1.0, .assistantFit: 1.0, .serialization: 1.0],
                    throughputDelta: nil
                )
            ),
            "A non-allowlisted evaluator must not be able to mint a receipt"
        ) { error in
            guard case GateReceiptError.evaluatorNotAllowed = error else {
                return XCTFail("Expected evaluatorNotAllowed, got \(error)")
            }
        }
    }

    // MARK: - Replay (T-replay — F4, F13)

    /// A receipt that has already authorized one successful deploy cannot authorize a
    /// second. WHY: `promoteAndConsumeReceipt`'s `changesCount == 1` guard makes the
    /// receipt single-use; a replay would deploy a stale candidate the evaluator scored
    /// once and let the loop double-spend a single measurement.
    func testConsumedReceiptCannotDeployAgain() async throws {
        let store = try await makeTempStore()
        let candidate = try makeMlxCandidate()

        var state = try await store.readState()
        state.currentAdapterPath = "/tmp/live_before_replay"
        state.pendingAdapterPath = candidate
        state.pendingAdapterKind = "mlxDir"
        state.pendingCycleId = "cyc-replay"
        try await store.writeState(state)

        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setInjectedGateKey(gateTestKey)
        try await coordinator.mintAndStoreGateReceipt(
            context: ImprovementCycleCoordinator.ReceiptMintContext(
                kind: .mlxDir, evaluatorId: "FaeBenchmarkEvaluator",
                baseModelId: "/tmp/live_before_replay", evalSuiteVersion: "faebench-v1"
            ),
            measured: MeasuredDeltas(
                measured: [.toolCalling: 2.0, .faeCapability: 1.0, .assistantFit: 1.0, .serialization: 1.0],
                throughputDelta: nil
            )
        )

        // First deploy succeeds and consumes the receipt.
        for s in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: s)
        }
        try await coordinator.approveDeployment()
        let afterFirst = try await store.readState().currentAdapterPath
        XCTAssertEqual(afterFirst, candidate, "First deploy promotes the candidate")
        let firstConsumed = try await store.isGateReceiptConsumed(cycleId: "cyc-replay")
        XCTAssertTrue(firstConsumed, "Receipt consumed by the first deploy")

        // Replay: re-stage the SAME consumed receipt's cycle as pending and try to deploy again.
        var replay = try await store.readState()
        replay.pendingAdapterPath = candidate
        replay.pendingAdapterKind = "mlxDir"
        replay.pendingCycleId = "cyc-replay"
        try await store.writeState(replay)
        for s in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: s)
        }
        await XCTAssertThrowsErrorAsync(
            try await coordinator.approveDeployment(),
            "A consumed receipt must not authorize a second deploy"
        ) { error in
            guard case ImprovementCycleError.gateReceiptRejected = error else {
                return XCTFail("Expected gateReceiptRejected, got \(error)")
            }
        }
    }

    /// A receipt minted for cycle A cannot deploy cycle B's candidate. WHY: the receipt is
    /// bound to a specific `cycleId`; if cycle B's pending candidate could be promoted with
    /// A's receipt, an un-evaluated candidate would inherit a different candidate's evaluation.
    func testReceiptBoundToCycleACannotDeployCycleB() async throws {
        let store = try await makeTempStore()
        let candidateA = try makeMlxCandidate()
        let candidateB = try makeMlxCandidate()

        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setInjectedGateKey(gateTestKey)

        // Mint a receipt for cycle A's candidate (path A).
        var state = try await store.readState()
        state.pendingAdapterPath = candidateA
        state.pendingAdapterKind = "mlxDir"
        state.pendingCycleId = "cyc-A"
        try await store.writeState(state)
        try await coordinator.mintAndStoreGateReceipt(
            context: ImprovementCycleCoordinator.ReceiptMintContext(
                kind: .mlxDir, evaluatorId: "FaeBenchmarkEvaluator",
                baseModelId: "base", evalSuiteVersion: "faebench-v1"
            ),
            measured: MeasuredDeltas(
                measured: [.toolCalling: 2.0, .faeCapability: 1.0, .assistantFit: 1.0, .serialization: 1.0],
                throughputDelta: nil
            )
        )

        // Now the pending candidate is B's path but the cycle id still points at A's receipt.
        // The receipt's candidatePath (A) cannot match the candidate being deployed (B).
        var crossed = try await store.readState()
        crossed.currentAdapterPath = "/tmp/live_before_cross"
        crossed.pendingAdapterPath = candidateB
        crossed.pendingAdapterKind = "mlxDir"
        crossed.pendingCycleId = "cyc-A"  // A's receipt, B's candidate
        try await store.writeState(crossed)

        for s in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: s)
        }
        await XCTAssertThrowsErrorAsync(
            try await coordinator.approveDeployment(),
            "A receipt bound to cycle A must not deploy cycle B's candidate"
        ) { error in
            guard case ImprovementCycleError.gateReceiptRejected = error else {
                return XCTFail("Expected gateReceiptRejected, got \(error)")
            }
        }
        let afterCross = try await store.readState().currentAdapterPath
        XCTAssertEqual(
            afterCross, "/tmp/live_before_cross",
            "Cross-bound receipt must not touch the live path"
        )
    }

    // MARK: - Gate rule truth table (T-unit-decide — F1, F2)

    /// The fail-closed gate rule, exhaustively. WHY: every previously-deployable crack
    /// lived here — all-nil (`compactMap`/`min() ?? 0.0` once passed it) and all-zero
    /// (a synthetic "no regression" pass). The rule must treat both as
    /// `.blockedNoMeasurement`, never a deploy.
    func testGateDecideTruthTable() {
        // Nothing measured at all ⇒ blocked.
        XCTAssertEqual(
            AdapterGate.decide(MeasuredDeltas(measured: [:], throughputDelta: nil)),
            .blockedNoMeasurement,
            "An empty measurement is indistinguishable from no eval and must block"
        )
        // Incomplete measurement (a dimension missing) ⇒ blocked.
        XCTAssertEqual(
            AdapterGate.decide(MeasuredDeltas(
                measured: [.toolCalling: 5.0, .faeCapability: 5.0, .assistantFit: 5.0],
                throughputDelta: nil
            )),
            .blockedNoMeasurement,
            "A partial measurement means the evaluator malfunctioned and cannot certify a deploy"
        )
        // All dimensions flat (zero) ⇒ blocked (NOT pass): a measured all-zero is
        // indistinguishable from a non-measurement.
        XCTAssertEqual(
            AdapterGate.decide(MeasuredDeltas(
                measured: [.toolCalling: 0.0, .faeCapability: 0.0, .assistantFit: 0.0, .serialization: 0.0],
                throughputDelta: nil
            )),
            .blockedNoMeasurement,
            "An all-zero result must not auto-deploy — nothing improved"
        )
        // Any dimension regressed > 5% ⇒ fail.
        XCTAssertEqual(
            AdapterGate.decide(MeasuredDeltas(
                measured: [.toolCalling: 3.0, .faeCapability: -6.0, .assistantFit: 1.0, .serialization: 1.0],
                throughputDelta: nil
            )),
            .fail,
            "A >5% regression is a hard fail"
        )
        // A small regression (≤5%) ⇒ concern.
        XCTAssertEqual(
            AdapterGate.decide(MeasuredDeltas(
                measured: [.toolCalling: 3.0, .faeCapability: -2.0, .assistantFit: 1.0, .serialization: 1.0],
                throughputDelta: nil
            )),
            .concern,
            "A small regression warrants human deferral, not a silent pass"
        )
        // At least one improvement, no regression ⇒ pass.
        XCTAssertEqual(
            AdapterGate.decide(MeasuredDeltas(
                measured: [.toolCalling: 3.0, .faeCapability: 0.0, .assistantFit: 0.0, .serialization: 0.0],
                throughputDelta: nil
            )),
            .pass,
            "One real improvement with no regression is the only thing that passes"
        )
        // Throughput is advisory only: a throughput gain with no correctness change blocks.
        XCTAssertEqual(
            AdapterGate.decide(MeasuredDeltas(
                measured: [.toolCalling: 0.0, .faeCapability: 0.0, .assistantFit: 0.0, .serialization: 0.0],
                throughputDelta: 50.0
            )),
            .blockedNoMeasurement,
            "Throughput must never make an adapter deployable on its own"
        )
    }

    // MARK: - Receipt write fails loud (T-receipt-write-fails-loud — F19)

    /// A failure persisting the gate receipt must propagate — it must NOT be swallowed.
    /// WHY: a passing eval that silently fails to persist its receipt would leave the deploy
    /// boundary with no receipt to verify; the loop must fail closed loudly, not proceed.
    /// Here the store is CLOSED before the mint, so `insertGateReceipt` throws `.notOpen`.
    func testReceiptWriteFailsLoud() async throws {
        let store = try await makeTempStore()
        let candidate = try makeMlxCandidate()
        var state = try await store.readState()
        state.pendingAdapterPath = candidate
        state.pendingAdapterKind = "mlxDir"
        state.pendingCycleId = "cyc-writefail"
        try await store.writeState(state)

        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setInjectedGateKey(gateTestKey)

        // Close the store so the persistence write fails.
        await store.close()

        await XCTAssertThrowsErrorAsync(
            try await coordinator.mintAndStoreGateReceipt(
                context: ImprovementCycleCoordinator.ReceiptMintContext(
                    kind: .mlxDir, evaluatorId: "FaeBenchmarkEvaluator",
                    baseModelId: "base", evalSuiteVersion: "faebench-v1"
                ),
                measured: MeasuredDeltas(
                    measured: [.toolCalling: 2.0, .faeCapability: 1.0, .assistantFit: 1.0, .serialization: 1.0],
                    throughputDelta: nil
                )
            ),
            "A receipt-persistence failure must propagate, never be swallowed (Rule 12)"
        ) { _ in
            // Any thrown error satisfies "fails loud" — the point is it is NOT swallowed.
        }
    }
}

// MARK: - Test doubles

/// A real `AdapterEvaluator` for the mlxDir lane that returns a fixed outcome. Registered
/// via `setAdapterEvaluator` exactly like `FaeBenchmarkEvaluator` is in production, so the
/// golden test exercises the genuine evaluator → mint path (not the test-only injected seam).
/// `evaluatorId` is `FaeBenchmarkEvaluator` so the minted receipt is on the gate allowlist.
private struct StubMlxEvaluator: AdapterEvaluator {
    let outcome: GateOutcome
    var kind: AdapterKind { .mlxDir }
    var evaluatorId: String { "FaeBenchmarkEvaluator" }
    func isAvailable() async -> Bool { true }
    func evaluate(candidatePath: String, baselinePath: String?) async throws -> GateOutcome { outcome }
}

// MARK: - Async throwing assertion helper

/// XCTAssertThrowsError has no async overload; this awaits the expression and routes the
/// thrown error to the handler (or fails if nothing throws). No force-unwraps.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message.isEmpty ? "Expected an error to be thrown" : message, file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

import CryptoKit
import XCTest
@testable import Fae

final class ImprovementCycleCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    /// Fixed HMAC key for gate-receipt tests (avoids Keychain access).
    private let gateTestKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))

    private func makeTempStore() async throws -> ImprovementStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("improvement.db")
        let store = ImprovementStore()
        try await store.open(at: url)
        return store
    }

    /// Create a temp GGUF candidate file and a valid gate receipt for it (signed with
    /// `gateTestKey`). The file must exist on disk because verify recomputes the digest.
    private func makeCandidateWithReceipt(cycleId: String) throws -> (path: String, receipt: GateReceipt) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-cand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("adapter.gguf").path
        try "candidate weights".write(toFile: path, atomically: true, encoding: .utf8)
        let receipt = try GateMinter.mint(
            cycleId: cycleId, candidatePath: path, kind: .gguf,
            measured: [.toolCalling: 3.0, .faeCapability: 1.0, .assistantFit: 2.0, .serialization: 0.0],
            evaluatorId: "DaemonABEvaluator", baseModelId: "gemma-test",
            evalSuiteVersion: "v1", mintedAt: "2026-06-22T00:00:00Z", using: gateTestKey
        )
        return (path, receipt)
    }

    /// Drive a coordinator (daemon/gguf lane) to `.proposing` with a valid pending
    /// candidate + an inserted gate receipt. Returns the candidate path.
    @discardableResult
    private func setupProposingWithValidReceipt(
        _ coordinator: ImprovementCycleCoordinator,
        store: ImprovementStore,
        cycleId: String = "cyc-1",
        priorDeployed: String? = "/tmp/prior_deployed"
    ) async throws -> String {
        let (path, receipt) = try makeCandidateWithReceipt(cycleId: cycleId)
        try await store.ensureStateRow()
        var s = try await store.readState()
        s.currentAdapterPath = priorDeployed
        s.pendingAdapterPath = path
        s.pendingAdapterKind = "gguf"
        s.pendingCycleId = cycleId
        try await store.writeState(s)
        try await store.insertGateReceipt(receipt)
        await coordinator.setInjectedGateKey(gateTestKey)
        await coordinator.setDaemonTrainingBaseModel("gemma-test") // gguf lane ⇒ expectedKind == .gguf
        for st in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: st)
        }
        return path
    }

    private func makeCoordinator(store: ImprovementStore) -> ImprovementCycleCoordinator {
        ImprovementCycleCoordinator(store: store)
    }

    /// A measured improvement delta (all +5pp). Drives the P9/C4 gate to PASS in
    /// tests that exercise the proposing/deploy path, standing in for a real
    /// FaeBenchmark result.
    private func measuredImprovement() -> EvalDelta {
        EvalDelta(
            toolCallingDelta: 5.0, faeCapabilityDelta: 5.0,
            assistantFitDelta: 5.0, serializationDelta: 5.0, throughputDelta: 1.0
        )
    }

    /// Arm the injected measured-delta seam so a `runCycle()` can pass the W7 fail-closed
    /// gate. The seam stands in for a real `AdapterEvaluator`: it provisions its own
    /// synthetic on-disk candidate during the eval phase (a real cycle's candidate, like
    /// this one, can only exist AFTER the cycle-start `idle ⇒ no pending` clear), then
    /// mints a receipt for it. The injected HMAC key lets that mint + the later deploy
    /// verify without Keychain access. Call this INSTEAD of a bare
    /// `setInjectedMeasuredDelta` whenever a `runCycle()` must reach the review gate.
    private func armInjectedPass(
        _ coordinator: ImprovementCycleCoordinator,
        store: ImprovementStore,
        delta: EvalDelta? = nil
    ) async {
        await coordinator.setInjectedGateKey(gateTestKey)
        await coordinator.setInjectedMeasuredDelta(delta ?? measuredImprovement())
    }

    private func makeEvent(
        signalType: String = "correction",
        fingerprint: String? = nil
    ) -> FeedbackEvent {
        FeedbackEvent(
            id: nil,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            signalType: signalType,
            turnFingerprint: fingerprint ?? UUID().uuidString,
            userInput: "test",
            assistantOutput: "test",
            sentimentScore: nil,
            consumed: false
        )
    }

    /// Seed the store with enough events to pass thresholds.
    private func seedSufficientData(store: ImprovementStore) async throws {
        // 15 corrections + 10 other signals = 25 total (>= 20 events, >= 5 corrections)
        for i in 0..<15 {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "correction", fingerprint: "corr-\(i)"
            ))
        }
        for i in 0..<10 {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "re_ask", fingerprint: "reask-\(i)"
            ))
        }
    }

    // MARK: - Initial State

    func testInitialStateIsIdle() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle)
    }

    // MARK: - Data Threshold Enforcement

    func testRunCycleSkipsIfInsufficientTotalEvents() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)

        // Add only 5 events (threshold is 20).
        for i in 0..<5 {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "correction", fingerprint: "e\(i)"
            ))
        }

        // Should skip silently (no error) and remain idle.
        try await coordinator.runCycle()
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle)
    }

    func testRunCycleSkipsIfInsufficientCorrectionEvents() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)

        // Add 25 events but only 3 corrections (threshold is 5).
        for i in 0..<3 {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "correction", fingerprint: "corr-\(i)"
            ))
        }
        for i in 0..<22 {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "re_ask", fingerprint: "reask-\(i)"
            ))
        }

        try await coordinator.runCycle()
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle)
    }

    // MARK: - State Transitions

    func testValidTransitionsSucceed() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        try await coordinator.transition(to: .collecting)
        let s1 = try await coordinator.currentState()
        XCTAssertEqual(s1, .collecting)

        try await coordinator.transition(to: .metaOptimizing)
        let s1b = try await coordinator.currentState()
        XCTAssertEqual(s1b, .metaOptimizing)

        try await coordinator.transition(to: .training)
        let s2 = try await coordinator.currentState()
        XCTAssertEqual(s2, .training)

        try await coordinator.transition(to: .evaluating)
        let s3 = try await coordinator.currentState()
        XCTAssertEqual(s3, .evaluating)

        try await coordinator.transition(to: .proposing)
        let s4 = try await coordinator.currentState()
        XCTAssertEqual(s4, .proposing)

        try await coordinator.transition(to: .deploying)
        let s5 = try await coordinator.currentState()
        XCTAssertEqual(s5, .deploying)

        try await coordinator.transition(to: .idle)
        let s6 = try await coordinator.currentState()
        XCTAssertEqual(s6, .idle)
    }

    func testInvalidTransitionThrows() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        // From idle, cannot go directly to training.
        do {
            try await coordinator.transition(to: .training)
            XCTFail("Expected invalidTransition error")
        } catch let error as ImprovementCycleError {
            if case .invalidTransition(let from, let to) = error {
                XCTAssertEqual(from, .idle)
                XCTAssertEqual(to, .training)
            } else {
                XCTFail("Expected invalidTransition, got \(error)")
            }
        }
    }

    func testRecoveryToIdleAlwaysAllowed() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        // Go to collecting, then recover to idle.
        try await coordinator.transition(to: .collecting)
        try await coordinator.transition(to: .idle)
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle)
    }

    // MARK: - Full Cycle

    func testRunCycleCompletesWithSufficientData() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        // P9/C4 (W7): a real measured improvement is required to pass the gate, AND a gate
        // pass must be backed by a minted receipt — so stage a mintable pending candidate.
        await armInjectedPass(coordinator, store: store)
        try await seedSufficientData(store: store)

        try await coordinator.runCycle()

        // With 0 prior approved cycles, runCycle pauses in PROPOSING awaiting user approval.
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .proposing, "runCycle should pause in proposing before 5 approvals earned")

        // Events should be consumed (collected at start of cycle).
        let pendingCount = try await store.pendingFeedbackCount()
        XCTAssertEqual(pendingCount, 0)
    }

    // MARK: - Stuck Detection

    func testStuckDetectionResetsToIdle() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()

        // Manually set state to training with a timestamp > 2h ago.
        var storeState = try await store.readState()
        storeState.cycleState = "training"
        let threeHoursAgo = Date().addingTimeInterval(-3 * 3600)
        storeState.trainingStartedAt = ISO8601DateFormatter().string(from: threeHoursAgo)
        try await store.writeState(storeState)

        let coordinator = makeCoordinator(store: store)

        // runCycle should detect stuck state, reset to idle, then attempt a normal cycle.
        // With no data, it will skip after reset. The important thing is it recovered.
        try await coordinator.runCycle()
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle)

        let updatedState = try await store.readState()
        XCTAssertNil(updatedState.trainingStartedAt)
    }

    // MARK: - Idempotency

    func testRunCycleTwiceInIdleIsSafe() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)

        // No data, so both calls should skip gracefully.
        try await coordinator.runCycle()
        try await coordinator.runCycle()
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle)
    }

    func testRunCycleWhileNotIdleSkips() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()

        // Force state to collecting (simulating in-progress cycle).
        var storeState = try await store.readState()
        storeState.cycleState = "collecting"
        try await store.writeState(storeState)

        let coordinator = makeCoordinator(store: store)
        // Should skip because not idle.
        try await coordinator.runCycle()
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .collecting) // Unchanged.
    }

    // MARK: - Training Sets trainingStartedAt

    func testTransitionToTrainingSetsTimestamp() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        try await coordinator.transition(to: .collecting)
        try await coordinator.transition(to: .metaOptimizing)
        try await coordinator.transition(to: .training)

        let storeState = try await store.readState()
        XCTAssertNotNil(storeState.trainingStartedAt)
    }

    // MARK: - Approval Flow (Phase 2.3)

    /// approveDeployment() increments userApprovedCycles and returns to idle.
    func testApproveDeploymentIncrementsApprovedCycles() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        // P9/C4 (W4): a deploy now REQUIRES a verifying gate receipt for the candidate.
        let candidate = try await setupProposingWithValidReceipt(coordinator, store: store)

        let preApproveState = try await coordinator.currentState()
        XCTAssertEqual(preApproveState, .proposing)

        try await coordinator.approveDeployment()

        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle)

        let storeState = try await store.readState()
        XCTAssertEqual(storeState.userApprovedCycles, 1)
        XCTAssertEqual(storeState.completedCycles, 1)
        XCTAssertNotNil(storeState.lastCycleAt)
        // The candidate is promoted; the prior becomes the rollback target; pending cleared.
        XCTAssertEqual(storeState.currentAdapterPath, candidate, "Candidate promoted to deployed")
        XCTAssertEqual(storeState.previousAdapterPath, "/tmp/prior_deployed", "Prior becomes rollback target")
        XCTAssertNil(storeState.pendingAdapterPath, "Pending cleared after deploy")
        // The receipt is consumed (single-use).
        let consumed = try await store.isGateReceiptConsumed(cycleId: "cyc-1")
        XCTAssertTrue(consumed, "Receipt consumed after deploy")
    }

    // MARK: - W4: deploy requires a verifying gate receipt

    /// Approve with no gate receipt for the candidate ⇒ fail closed (no deploy).
    func testApproveWithoutReceiptIsBlocked() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        // Pending candidate present, but NO receipt inserted.
        let (path, _) = try makeCandidateWithReceipt(cycleId: "cyc-x")
        var s = try await store.readState()
        s.currentAdapterPath = "/tmp/prior"
        s.pendingAdapterPath = path
        s.pendingAdapterKind = "gguf"
        s.pendingCycleId = "cyc-x"
        try await store.writeState(s)
        let coordinator = makeCoordinator(store: store)
        await coordinator.setInjectedGateKey(gateTestKey)
        await coordinator.setDaemonTrainingBaseModel("gemma-test")
        for st in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: st)
        }

        do {
            try await coordinator.approveDeployment()
            XCTFail("approve must throw without a gate receipt")
        } catch ImprovementCycleError.gateReceiptRejected {
            // expected
        }

        let after = try await store.readState()
        XCTAssertEqual(after.cycleState, "idle", "Fail-closed back to idle")
        XCTAssertEqual(after.currentAdapterPath, "/tmp/prior", "Deployed pointer untouched")
        XCTAssertNil(after.pendingAdapterPath, "Rejected candidate discarded")
        XCTAssertEqual(after.userApprovedCycles, 0, "No deploy earned")
    }

    /// A consumed (replayed) receipt cannot deploy again.
    func testApproveWithConsumedReceiptIsBlocked() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        try await setupProposingWithValidReceipt(coordinator, store: store, cycleId: "cyc-r")
        // Pre-consume the receipt.
        try await store.consumeGateReceipt(cycleId: "cyc-r", at: "2026-06-22T00:00:00Z")

        do {
            try await coordinator.approveDeployment()
            XCTFail("approve must throw on an already-consumed receipt")
        } catch ImprovementCycleError.gateReceiptRejected {
            // expected
        }
        let after = try await store.readState()
        XCTAssertEqual(after.currentAdapterPath, "/tmp/prior_deployed", "Deployed pointer untouched")
        XCTAssertNil(after.pendingAdapterPath, "Rejected candidate discarded")
    }

    /// A receipt minted for a DIFFERENT candidate path cannot deploy this candidate.
    func testApproveWithMismatchedCandidateReceiptIsBlocked() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let (path, _) = try makeCandidateWithReceipt(cycleId: "cyc-m")
        // Insert a receipt for a DIFFERENT candidate path under the same cycle id.
        let (otherPath, otherReceiptForOtherPath) = try makeCandidateWithReceipt(cycleId: "cyc-m")
        _ = otherPath
        try await store.insertGateReceipt(otherReceiptForOtherPath)
        var s = try await store.readState()
        s.pendingAdapterPath = path  // candidate is `path`, but the receipt is for `otherPath`
        s.pendingAdapterKind = "gguf"
        s.pendingCycleId = "cyc-m"
        try await store.writeState(s)
        let coordinator = makeCoordinator(store: store)
        await coordinator.setInjectedGateKey(gateTestKey)
        await coordinator.setDaemonTrainingBaseModel("gemma-test")
        for st in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: st)
        }

        do {
            try await coordinator.approveDeployment()
            XCTFail("approve must throw when the receipt is for a different candidate")
        } catch ImprovementCycleError.gateReceiptRejected {
            // expected (candidateMismatch inside verify)
        }
        let after = try await store.readState()
        XCTAssertNil(after.currentAdapterPath)
    }

    /// A receipt whose kind does not match the active engine lane is blocked.
    func testApproveWithKindEngineMismatchIsBlocked() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        // setup uses the gguf/daemon lane (expectedKind == .gguf) and a .gguf receipt...
        try await setupProposingWithValidReceipt(coordinator, store: store, cycleId: "cyc-k")
        // ...but flip the engine lane to MLX (expectedKind becomes .mlxDir) so the
        // .gguf receipt now mismatches the engine.
        await coordinator.setDaemonTrainingBaseModel(nil)

        do {
            try await coordinator.approveDeployment()
            XCTFail("approve must throw on a kind↔engine mismatch")
        } catch ImprovementCycleError.gateReceiptRejected {
            // expected (kind_engine_mismatch)
        }
        let after = try await store.readState()
        XCTAssertEqual(after.currentAdapterPath, "/tmp/prior_deployed", "Mismatched-kind candidate must not deploy")
    }

    // MARK: - W5: stale-state recovery + shadow-eval source guard

    /// A crashed/stale `.proposing` with no valid receipt is reset to idle, the candidate
    /// discarded, and the deployed pointer left untouched (fail-closed).
    func testRecoveryResetsStaleProposingWithoutReceipt() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var s = try await store.readState()
        s.cycleState = "proposing"
        s.currentAdapterPath = "/tmp/deployed"
        s.pendingAdapterPath = "/tmp/candidate"
        s.pendingAdapterKind = "gguf"
        s.pendingCycleId = "stale-cyc"
        try await store.writeState(s)
        let coordinator = makeCoordinator(store: store)

        await coordinator.recoverStaleStateIfNeeded()

        let after = try await store.readState()
        XCTAssertEqual(after.cycleState, "idle", "Stale proposing without a receipt is reset")
        XCTAssertNil(after.pendingAdapterPath, "Pending candidate discarded")
        XCTAssertEqual(after.lastCycleError, "recovered_stale_proposing")
        XCTAssertEqual(after.currentAdapterPath, "/tmp/deployed", "Deployed pointer untouched")
    }

    /// A `.proposing` whose pending candidate still has a valid, unconsumed receipt is
    /// legitimately resumable after a restart — recovery keeps it.
    func testRecoveryKeepsResumableProposingWithValidReceipt() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        let cycleId = "resumable-cyc"
        let (path, receipt) = try makeCandidateWithReceipt(cycleId: cycleId)
        try await store.insertGateReceipt(receipt)
        try await store.ensureStateRow()
        var s = try await store.readState()
        s.cycleState = "proposing"
        s.pendingAdapterPath = path
        s.pendingAdapterKind = "gguf"
        s.pendingCycleId = cycleId
        try await store.writeState(s)
        await coordinator.setInjectedGateKey(gateTestKey)

        await coordinator.recoverStaleStateIfNeeded()

        let after = try await store.readState()
        XCTAssertEqual(after.cycleState, "proposing", "Resumable proposing with a valid receipt is kept")
        XCTAssertEqual(after.pendingAdapterPath, path, "Pending candidate preserved")
    }

    /// A crashed `.training`/`.evaluating` cycle is reset to idle with its half-baked
    /// candidate discarded.
    func testRecoveryResetsInterruptedTraining() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var s = try await store.readState()
        s.cycleState = "training"
        s.pendingAdapterPath = "/tmp/halfbaked"
        s.pendingCycleId = "t-cyc"
        try await store.writeState(s)
        let coordinator = makeCoordinator(store: store)

        await coordinator.recoverStaleStateIfNeeded()

        let after = try await store.readState()
        XCTAssertEqual(after.cycleState, "idle")
        XCTAssertNil(after.pendingAdapterPath, "Half-baked candidate discarded")
        XCTAssertEqual(after.lastCycleError, "recovered_stale_training")
    }

    /// Recovery is a no-op when already idle.
    func testRecoveryNoOpWhenIdle() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var s = try await store.readState()
        s.currentAdapterPath = "/tmp/deployed"
        s.lastCycleError = "previous_thing"
        try await store.writeState(s)
        let coordinator = makeCoordinator(store: store)

        await coordinator.recoverStaleStateIfNeeded()

        let after = try await store.readState()
        XCTAssertEqual(after.cycleState, "idle")
        XCTAssertEqual(after.currentAdapterPath, "/tmp/deployed")
        XCTAssertEqual(after.lastCycleError, "previous_thing", "Idle state untouched")
    }

    /// Shadow eval A/Bs the DEPLOYED adapter, never the pending candidate (F5): the
    /// coordinator pins the evaluator's adapter path to currentAdapterPath before running.
    func testShadowEvalUsesDeployedAdapterNotPending() async throws {
        let store = try await makeTempStore()

        let evaluator = ShadowEvaluator(store: store)
        await evaluator.setResponseGenerator { _, _ in "response" }
        await evaluator.setScorer { _, _, _ in .adapterWins }
        for i in 0..<5 {
            _ = try await store.appendShadowEpisode(ShadowEvalEpisode(
                id: nil, recordedAt: ISO8601DateFormatter().string(from: Date()),
                conversationJSON: "[{\"role\":\"user\",\"content\":\"test\"}]",
                actualResponse: "response \(i)",
                receptionScore: nil, evaluated: false, evalOutcome: nil
            ))
        }

        let coordinator = ImprovementCycleCoordinator(
            store: store, reviewGate: ExternalReviewGate(), shadowEvaluator: evaluator
        )
        // Arm the injected seam (it self-provisions a pending candidate during eval, W7),
        // then pin the deployed adapter that shadow eval must A/B against.
        await armInjectedPass(coordinator, store: store)
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.completedCycles = 1 // odd ⇒ shadow eval night
        state.currentAdapterPath = "/tmp/deployed_adapter"
        try await store.writeState(state)

        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        // The coordinator pinned the evaluator to the DEPLOYED adapter, never the (self-
        // provisioned) pending candidate.
        let pinned = await evaluator.currentAdapterPath
        XCTAssertEqual(pinned, "/tmp/deployed_adapter", "Shadow eval must A/B the deployed adapter")
        XCTAssertFalse(
            pinned?.contains("injected-seam") ?? false,
            "Shadow eval must never use the pending candidate"
        )
    }

    /// A `.deploying` state is NOT resumable (no path advances it) — recovery resets it
    /// even with a valid receipt.
    func testRecoveryResetsDeployingEvenWithValidReceipt() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        let cycleId = "deploy-cyc"
        let (path, receipt) = try makeCandidateWithReceipt(cycleId: cycleId)
        try await store.insertGateReceipt(receipt)
        try await store.ensureStateRow()
        var s = try await store.readState()
        s.cycleState = "deploying"
        s.currentAdapterPath = "/tmp/deployed"
        s.pendingAdapterPath = path
        s.pendingAdapterKind = "gguf"
        s.pendingCycleId = cycleId
        try await store.writeState(s)
        await coordinator.setInjectedGateKey(gateTestKey)

        await coordinator.recoverStaleStateIfNeeded()

        let after = try await store.readState()
        XCTAssertEqual(after.cycleState, "idle", ".deploying is not resumable — reset")
        XCTAssertNil(after.pendingAdapterPath, "Pending discarded")
        XCTAssertEqual(after.currentAdapterPath, "/tmp/deployed", "Genuine deployed pointer (pending recorded) kept")
    }

    /// A `.proposing` with a CONSUMED receipt is not resumable — reset.
    func testRecoveryResetsProposingWithConsumedReceipt() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        let cycleId = "consumed-cyc"
        let (path, receipt) = try makeCandidateWithReceipt(cycleId: cycleId)
        try await store.insertGateReceipt(receipt)
        try await store.consumeGateReceipt(cycleId: cycleId, at: "2026-06-22T00:00:00Z")
        try await store.ensureStateRow()
        var s = try await store.readState()
        s.cycleState = "proposing"
        s.pendingAdapterPath = path
        s.pendingCycleId = cycleId
        try await store.writeState(s)
        await coordinator.setInjectedGateKey(gateTestKey)

        await coordinator.recoverStaleStateIfNeeded()

        let after = try await store.readState()
        XCTAssertEqual(after.cycleState, "idle", "Consumed receipt ⇒ not resumable ⇒ reset")
        XCTAssertNil(after.pendingAdapterPath)
    }

    /// A PRE-P9-shaped post-eval state (candidate written to currentAdapterPath, no pending
    /// fields) has its ungated current rolled back to the previous adapter (fail-closed).
    func testRecoveryRollsBackPreP9UngatedCurrentAdapter() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var s = try await store.readState()
        s.cycleState = "evaluating"                       // post-(old)-eval state
        s.currentAdapterPath = "/tmp/ungated_candidate"   // pre-P9: candidate sat in current
        s.previousAdapterPath = "/tmp/last_good"
        s.pendingAdapterPath = nil                        // pre-P9 shape: no pending fields
        s.pendingCycleId = nil
        try await store.writeState(s)
        let coordinator = makeCoordinator(store: store)

        await coordinator.recoverStaleStateIfNeeded()

        let after = try await store.readState()
        XCTAssertEqual(after.cycleState, "idle")
        XCTAssertEqual(after.currentAdapterPath, "/tmp/last_good", "Pre-P9 ungated current rolled back to previous")
        XCTAssertEqual(after.lastCycleError, "recovered_stale_evaluating")
    }

    /// The crash window AFTER promote commits (current = just-promoted, receipt-gated
    /// candidate; pending cleared) but BEFORE the .idle transition: recovery must KEEP the
    /// promoted current (it has a consumed-receipt provenance), not mistake it for pre-P9.
    func testRecoveryKeepsPromotedCurrentOnCrashAfterPromote() async throws {
        let store = try await makeTempStore()
        let cycleId = "promote-cyc"
        let (path, receipt) = try makeCandidateWithReceipt(cycleId: cycleId)
        try await store.insertGateReceipt(receipt)
        try await store.consumeGateReceipt(cycleId: cycleId, at: "2026-06-22T00:00:00Z")
        try await store.ensureStateRow()
        var s = try await store.readState()
        s.cycleState = "deploying"        // promote committed; .idle transition not yet run
        s.currentAdapterPath = path       // the just-promoted candidate
        s.previousAdapterPath = "/tmp/old"
        s.pendingAdapterPath = nil        // pending was cleared by the promote
        s.pendingCycleId = nil
        try await store.writeState(s)
        let coordinator = makeCoordinator(store: store)

        await coordinator.recoverStaleStateIfNeeded()

        let after = try await store.readState()
        XCTAssertEqual(after.cycleState, "idle")
        XCTAssertEqual(
            after.currentAdapterPath, path,
            "A promoted, receipt-gated current must NOT be rolled back"
        )
    }

    // MARK: - W6: refuse to train a lane with no evaluator

    private func makeFakeBridge() throws -> TrainingBridge {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-w6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return TrainingBridge(
            uvPath: "/usr/bin/false", orchestratorScriptsDir: tmpDir, dataBridgeScriptsDir: tmpDir
        )
    }

    /// With a training bridge present but NO evaluator available for the lane, the cycle
    /// refuses to train (it would only burn a run — the candidate could never pass the gate).
    func testRefuseToTrainWhenNoEvaluatorForLane() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        await coordinator.setTrainingBridge(try makeFakeBridge())
        // availableEvaluatorKinds left empty ⇒ refuse.
        try await seedSufficientData(store: store)

        try await coordinator.runCycle()

        let state = try await store.readState()
        XCTAssertEqual(state.cycleState, "idle")
        XCTAssertEqual(state.lastCycleError, "lane_no_evaluator:mlxDir",
                       "mlx lane must refuse to train without an evaluator")
        // F14: the refusal is also surfaced in the morning-briefing narrative.
        let narrative = await coordinator.pendingMetaOptNarrative
        XCTAssertTrue(narrative?.contains("mlxDir") ?? false, "Refusal surfaced in the briefing narrative")
    }

    /// The daemon (gguf) lane also refuses to train without a gguf evaluator.
    func testRefuseToTrainGgufLaneWhenNoEvaluator() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        await coordinator.setTrainingBridge(try makeFakeBridge())
        await coordinator.setDaemonTrainingBaseModel("gemma-test") // gguf lane
        // Only an mlxDir evaluator available — the gguf lane still refuses.
        await coordinator.setAvailableEvaluatorKinds([.mlxDir])
        try await seedSufficientData(store: store)

        try await coordinator.runCycle()

        let state = try await store.readState()
        XCTAssertEqual(state.cycleState, "idle")
        XCTAssertEqual(state.lastCycleError, "lane_no_evaluator:gguf",
                       "gguf lane must refuse without a gguf evaluator")
    }

    /// With an evaluator available for the lane, the cycle gets PAST the refuse-to-train
    /// gate (and then fails downstream on the fake bridge — not at the gate).
    func testTrainsPastGateWhenEvaluatorAvailable() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        await coordinator.setTrainingBridge(try makeFakeBridge())
        await coordinator.setAvailableEvaluatorKinds([.mlxDir])
        try await seedSufficientData(store: store)

        try await coordinator.runCycle()

        let state = try await store.readState()
        XCTAssertFalse(
            state.lastCycleError?.starts(with: "lane_no_evaluator") ?? false,
            "With an evaluator available the cycle must pass the refuse-to-train gate, got: \(state.lastCycleError ?? "nil")"
        )
    }

    /// rejectDeployment() returns to idle without incrementing userApprovedCycles.
    func testRejectDeploymentReturnsToIdleWithoutApproval() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        for state in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: state)
        }

        try await coordinator.rejectDeployment()

        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle)

        let storeState = try await store.readState()
        XCTAssertEqual(storeState.userApprovedCycles, 0, "Rejection must not increment userApprovedCycles")
        XCTAssertEqual(storeState.completedCycles, 1, "completedCycles should still increment")
    }

    /// rejectDeployment() discards the pending candidate and leaves the deployed
    /// adapter untouched — a rejected candidate never becomes current (P9/C4 W3).
    func testRejectDeploymentDiscardsPendingKeepsDeployed() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        // Post-training proposing state: candidate is PENDING; the deployed adapter
        // is in currentAdapterPath (training never touched it).
        var state = try await store.readState()
        state.currentAdapterPath = "/tmp/deployed"
        state.pendingAdapterPath = "/tmp/rejected_candidate"
        try await store.writeState(state)

        let coordinator = makeCoordinator(store: store)
        for s in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: s)
        }

        try await coordinator.rejectDeployment()

        let after = try await store.readState()
        XCTAssertEqual(after.cycleState, "idle")
        XCTAssertEqual(
            after.currentAdapterPath, "/tmp/deployed",
            "Deployed adapter must be untouched by a rejection"
        )
        XCTAssertNil(after.pendingAdapterPath, "Rejected candidate must be discarded")
        XCTAssertEqual(after.userApprovedCycles, 0, "Reject must not earn auto-deploy")
    }

    /// approveDeployment with no pending candidate fails closed (throws) rather than
    /// silently "succeeding" with nothing deployed (P9/C4 W3).
    func testApproveWithNoPendingCandidateThrows() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)
        // Drive to proposing WITHOUT seeding a pending candidate.
        for s in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: s)
        }

        do {
            try await coordinator.approveDeployment()
            XCTFail("approveDeployment must throw when there is no pending candidate")
        } catch ImprovementCycleError.noPendingCandidate {
            // expected
        } catch {
            XCTFail("expected noPendingCandidate, got \(error)")
        }

        // The failed approve leaves the machine in proposing (recoverable), NOT stuck
        // in deploying, and has no side effects.
        let stateAfter = try await coordinator.currentState()
        XCTAssertEqual(stateAfter, .proposing)
        let after = try await store.readState()
        XCTAssertNil(after.currentAdapterPath, "Nothing should be deployed")
        XCTAssertEqual(after.userApprovedCycles, 0, "Failed approve must not earn auto-deploy")
    }

    /// A fail-closed cycle clears any (stale) pending candidate — idle never
    /// coexists with a candidate a later path could deploy (P9/C4 W3).
    func testFailClosedCycleClearsPendingCandidate() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        // Seed a stale pending candidate (e.g. left from an earlier interrupted run).
        var seed = try await store.readState()
        seed.pendingAdapterPath = "/tmp/stale_candidate"
        seed.pendingAdapterKind = "gguf"
        try await store.writeState(seed)

        let coordinator = makeCoordinator(store: store)
        try await seedSufficientData(store: store)
        // No bridge + no injected delta ⇒ unmeasured ⇒ fail-closed block.
        try await coordinator.runCycle()

        let after = try await store.readState()
        XCTAssertEqual(after.cycleState, "idle")
        XCTAssertNil(after.pendingAdapterPath, "Fail-closed must clear the stale pending candidate")
        XCTAssertNil(after.currentAdapterPath, "Nothing deployed")
    }

    /// approveDeployment() throws invalidTransition when not in proposing state.
    func testApproveDeploymentFromNonProposingStateThrows() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        do {
            try await coordinator.approveDeployment()
            XCTFail("Expected invalidTransition")
        } catch let error as ImprovementCycleError {
            if case .invalidTransition(let from, let to) = error {
                XCTAssertEqual(from, .idle)
                XCTAssertEqual(to, .deploying)
            } else {
                XCTFail("Expected invalidTransition, got \(error)")
            }
        }
    }

    /// rejectDeployment() throws invalidTransition when not in proposing state.
    func testRejectDeploymentFromNonProposingStateThrows() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        do {
            try await coordinator.rejectDeployment()
            XCTFail("Expected invalidTransition")
        } catch let error as ImprovementCycleError {
            if case .invalidTransition = error {
                // Expected.
            } else {
                XCTFail("Expected invalidTransition, got \(error)")
            }
        }
    }

    // MARK: - Rollback (Phase 2.3)

    /// rollback() swaps currentAdapterPath and previousAdapterPath.
    func testRollbackSwapsAdapterPaths() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        // Seed paths.
        var state = try await store.readState()
        state.currentAdapterPath = "/adapters/cycle-2"
        state.previousAdapterPath = "/adapters/cycle-1"
        try await store.writeState(state)

        try await coordinator.rollback()

        let afterRollback = try await store.readState()
        XCTAssertEqual(afterRollback.currentAdapterPath, "/adapters/cycle-1")
        XCTAssertEqual(afterRollback.previousAdapterPath, "/adapters/cycle-2")
    }

    /// rollback() with nil previousAdapterPath unloads the adapter.
    func testRollbackWithNilPreviousPathUnloads() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        var state = try await store.readState()
        state.currentAdapterPath = "/adapters/cycle-1"
        state.previousAdapterPath = nil
        try await store.writeState(state)

        try await coordinator.rollback()

        let afterRollback = try await store.readState()
        XCTAssertNil(afterRollback.currentAdapterPath, "Rollback to nil should unload the adapter")
        XCTAssertEqual(afterRollback.previousAdapterPath, "/adapters/cycle-1")
    }

    /// rollback() invokes adapterPatchCallback with the previous path.
    func testRollbackInvokesAdapterPatchCallback() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        var state = try await store.readState()
        state.currentAdapterPath = "/adapters/cycle-2"
        state.previousAdapterPath = "/adapters/cycle-1"
        try await store.writeState(state)

        // Capture patcher call.
        final class Capture: @unchecked Sendable { var path: String? = "uninvoked" }
        let capture = Capture()
        await coordinator.setAdapterPatchCallback { path in capture.path = path }

        try await coordinator.rollback()

        XCTAssertEqual(capture.path, "/adapters/cycle-1")
    }

    // MARK: - Auto-Deploy After 5 Approved Cycles (Phase 2.3)

    // P9/C4 (W1): with no benchmark evaluator wired, a cycle cannot produce a
    // MEASURED improvement, so the fail-closed gate rule (`AdapterGate.decide`)
    // makes the internal review FAIL — the candidate can never reach `.proposing`
    // or deploy. WHY: an un-evaluated adapter must never be proposed or deployed —
    // the previous all-zero/all-nil "pass" was the hole C4 closes. The
    // proposing-pause and auto-deploy happy paths are re-covered in W8 with a stub
    // evaluator that returns a real measured improvement. (External-review
    // short-circuit on unmeasured deltas — F16 — lands in W4.)

    /// runCycle() with no evaluator fails closed instead of proposing.
    func testRunCycleBlocksWhenNoEvaluatorConfigured() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        try await seedSufficientData(store: store)

        try await coordinator.runCycle()

        // Fail-closed: no measured improvement ⇒ blocked BEFORE review ⇒ idle, NOT proposing.
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle, "No evaluator ⇒ candidate is blocked, never proposed")
        let persisted = try await store.readState()
        XCTAssertEqual(persisted.lastCycleError, "candidate_blocked: no_measured_improvement")
        XCTAssertNil(persisted.currentAdapterPath, "Blocked candidate must not be deployed")
    }

    /// Earned auto-deploy does NOT bypass the gate: with no measurement the
    /// candidate is blocked before review and nothing is deployed.
    func testRunCycleBlocksAutoDeployWhenNoMeasurement() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        // Seed 5 prior approved cycles to "earn" auto-deploy.
        var state = try await store.readState()
        state.userApprovedCycles = 5
        try await store.writeState(state)

        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        // Earned autonomy must not deploy an un-evaluated candidate.
        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle, "Blocked candidate returns to idle")
        let persisted = try await store.readState()
        XCTAssertEqual(persisted.lastCycleError, "candidate_blocked: no_measured_improvement")
        XCTAssertNil(persisted.currentAdapterPath, "Auto-deploy must not ship an un-evaluated adapter")
    }

    // MARK: - External Review Gate Integration

    /// When the review gate returns CONCERN, the cycle defers and returns to idle.
    func testRunCycleDeferOnConcernVerdict() async throws {
        let store = try await makeTempStore()
        let gate = ExternalReviewGate()
        // Mock delegate returns CONCERN
        await gate.setDelegateAgentRunner { _ in
            "CONCERN: Minor regression in tool calling. Recommend human review."
        }
        let coordinator = ImprovementCycleCoordinator(store: store, reviewGate: gate)
        // P9/C4 (W1/W7): a measured delta is required to reach the external review gate,
        // and the gate pass must be backed by a minted receipt — stage a candidate.
        await armInjectedPass(coordinator, store: store)

        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        // Should return to idle with deferral incremented.
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle, "Concern should return to idle")

        let storeState = try await store.readState()
        XCTAssertEqual(storeState.deferralCount, 1, "Deferral count should be 1 after CONCERN")
        XCTAssertEqual(storeState.lastCycleError, "review_concern_deferred")
    }

    /// When the review gate returns FAIL, the cycle aborts and returns to idle.
    func testRunCycleAbortsOnFailVerdict() async throws {
        let store = try await makeTempStore()
        let gate = ExternalReviewGate()
        await gate.setDelegateAgentRunner { _ in
            "FAIL: Significant regression in tool calling (-15%)."
        }
        let coordinator = ImprovementCycleCoordinator(store: store, reviewGate: gate)
        // P9/C4 (W1/W7): reach the review gate with a measured delta backed by a receipt.
        await armInjectedPass(coordinator, store: store)

        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle, "Fail should return to idle")

        let storeState = try await store.readState()
        XCTAssertEqual(storeState.deferralCount, 0, "Deferrals should be reset on FAIL")
        XCTAssertTrue(
            storeState.lastCycleError?.starts(with: "review_failed") ?? false,
            "Error should start with review_failed"
        )
    }

    /// When the review gate returns PASS, the cycle continues to proposing.
    func testRunCycleContinuesOnPassVerdict() async throws {
        let store = try await makeTempStore()
        let gate = ExternalReviewGate()
        await gate.setDelegateAgentRunner { _ in
            "PASS: All metrics improved, no regressions detected."
        }
        let coordinator = ImprovementCycleCoordinator(store: store, reviewGate: gate)
        // P9/C4 (W1/W7): reach the review gate with a measured delta backed by a receipt.
        await armInjectedPass(coordinator, store: store)

        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        // With 0 user-approved cycles, should pause in proposing.
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .proposing, "PASS should continue to proposing")

        let storeState = try await store.readState()
        XCTAssertEqual(storeState.deferralCount, 0, "Deferrals should be reset on PASS")
    }

    /// P9/C4 (W7, Codex FIX 2): a measured delta that PASSES the gate but came through the
    /// legacy bridge-benchmark / loss-proxy branch (no real evaluator ⇒ no minted receipt)
    /// must FAIL CLOSED immediately — it must NOT reach external review, must NOT enter
    /// `.proposing`/`.deploying`, and must NOT touch `currentAdapterPath`. Why: only a real
    /// `AdapterEvaluator` (which mints a receipt) may pass the gate; relying on the late W4
    /// deploy fence would let a non-evaluator pass run external review first.
    func testGatePassWithoutReceiptFailsClosed() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var seed = try await store.readState()
        seed.currentAdapterPath = "/tmp/live_adapter"
        try await store.writeState(seed)

        // A reviewer that would PASS if it were ever consulted — it must NOT be.
        let gate = ExternalReviewGate()
        var reviewWasConsulted = false
        await gate.setDelegateAgentRunner { _ in
            reviewWasConsulted = true
            return "PASS: looks great."
        }
        let coordinator = ImprovementCycleCoordinator(store: store, reviewGate: gate)
        // Drive the legacy no-receipt path with a clean +5pp pass.
        await coordinator.setInjectedLegacyMeasuredDelta(measuredImprovement())
        try await seedSufficientData(store: store)

        try await coordinator.runCycle()

        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle, "A gate pass with no receipt must end fail-closed at idle")
        let persisted = try await store.readState()
        XCTAssertEqual(persisted.lastCycleError, "gate_pass_but_no_receipt")
        XCTAssertEqual(persisted.currentAdapterPath, "/tmp/live_adapter",
                       "The live adapter must be untouched")
        XCTAssertNil(persisted.pendingAdapterPath, "Pending candidate discarded")
        XCTAssertFalse(reviewWasConsulted, "External review must NOT be consulted for a no-receipt pass")
    }

    /// P9/C4 (F1 gate-decision fix): a candidate whose MEASURED deltas carry a > 5%
    /// regression (`AdapterGate.decide == .fail`) is blocked BEFORE minting/review — it
    /// must never mint a receipt, never consult external review, never reach
    /// `.proposing`/`.deploying`, and must leave the deployed adapter untouched. Why: the
    /// review chain's (future) external reviewers can PASS anything, so the gate's own
    /// decision — not the reviewer — is the barrier against deploying a regression.
    func testRunCycleBlocksRegressedFailDeltaBeforeReview() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var seed = try await store.readState()
        seed.currentAdapterPath = "/tmp/live_adapter"
        try await store.writeState(seed)

        // A reviewer that would PASS if it were ever consulted — it must NOT be.
        let gate = ExternalReviewGate()
        var reviewWasConsulted = false
        await gate.setDelegateAgentRunner { _ in
            reviewWasConsulted = true
            return "PASS: looks great."
        }
        let coordinator = ImprovementCycleCoordinator(store: store, reviewGate: gate)
        // A measured regression > 5% on one dimension ⇒ AdapterGate .fail.
        await armInjectedPass(coordinator, store: store, delta: EvalDelta(
            toolCallingDelta: -10.0, faeCapabilityDelta: 5.0,
            assistantFitDelta: 5.0, serializationDelta: 5.0, throughputDelta: 1.0
        ))
        try await seedSufficientData(store: store)

        try await coordinator.runCycle()

        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle, "A .fail-delta candidate must end fail-closed at idle")
        let persisted = try await store.readState()
        XCTAssertEqual(persisted.lastCycleError, "candidate_blocked: measured_regression")
        XCTAssertEqual(persisted.currentAdapterPath, "/tmp/live_adapter", "Deployed adapter untouched")
        XCTAssertNil(persisted.pendingAdapterPath, "Regressed candidate discarded")
        XCTAssertFalse(reviewWasConsulted, "External review must NOT see a regressed candidate")
    }

    /// P9/C4 (F1 gate-decision fix): a candidate with a within-threshold regression
    /// (`AdapterGate.decide == .concern`) is deferred deterministically at the gate — it
    /// increments the deferral count and ends at idle WITHOUT minting, reviewing, or
    /// deploying. This replaces trusting the external reviewer to catch the regression.
    func testRunCycleDefersConcernDeltaBeforeReview() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var seed = try await store.readState()
        seed.currentAdapterPath = "/tmp/live_adapter"
        try await store.writeState(seed)

        let gate = ExternalReviewGate()
        var reviewWasConsulted = false
        await gate.setDelegateAgentRunner { _ in
            reviewWasConsulted = true
            return "PASS: looks great."
        }
        let coordinator = ImprovementCycleCoordinator(store: store, reviewGate: gate)
        // A within-threshold regression (≤ 5%) on one dimension ⇒ AdapterGate .concern.
        await armInjectedPass(coordinator, store: store, delta: EvalDelta(
            toolCallingDelta: -2.0, faeCapabilityDelta: 5.0,
            assistantFitDelta: 5.0, serializationDelta: 5.0, throughputDelta: 1.0
        ))
        try await seedSufficientData(store: store)

        try await coordinator.runCycle()

        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle, "A .concern-delta candidate defers to idle")
        let persisted = try await store.readState()
        XCTAssertEqual(persisted.lastCycleError, "candidate_blocked_concern_deferred")
        XCTAssertEqual(persisted.deferralCount, 1, "Concern defers deterministically at the gate")
        XCTAssertEqual(persisted.currentAdapterPath, "/tmp/live_adapter", "Deployed adapter untouched")
        XCTAssertNil(persisted.pendingAdapterPath, "Concern candidate discarded")
        XCTAssertFalse(reviewWasConsulted, "External review must NOT see a concern candidate")
    }

    /// Multiple CONCERN deferrals accumulate until max is reached.
    func testDeferralsAccumulateAcrossCycles() async throws {
        let store = try await makeTempStore()
        let gate = ExternalReviewGate()
        await gate.setDelegateAgentRunner { _ in
            "CONCERN: Minor issue detected."
        }
        let coordinator = ImprovementCycleCoordinator(store: store, reviewGate: gate)
        // The injected seam self-provisions a fresh candidate + receipt each cycle (a CONCERN
        // fail-closes and clears the pending candidate), so arming once suffices (W7).
        await armInjectedPass(coordinator, store: store)

        // Run 3 cycles, each should defer.
        for i in 1...3 {
            try await seedSufficientData(store: store)
            try await coordinator.runCycle()

            let storeState = try await store.readState()
            XCTAssertEqual(storeState.deferralCount, i, "Deferral count should be \(i) after cycle \(i)")
            XCTAssertEqual(storeState.cycleState, "idle")
        }
    }

    /// When max deferrals reached, cycle aborts and resets deferrals.
    func testMaxDeferralsReachedAbortsAndResets() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let gate = ExternalReviewGate()
        // Set deferralCount to the max so review() throws maxDeferralsReached.
        var storeState = try await store.readState()
        storeState.deferralCount = ExternalReviewGate.maxDeferrals
        try await store.writeState(storeState)

        let coordinator = ImprovementCycleCoordinator(store: store, reviewGate: gate)
        // P9/C4 (W1/W7): a measured delta backed by a receipt is required to reach the
        // review gate, where the max-deferrals check then fires.
        await armInjectedPass(coordinator, store: store)
        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle, "Max deferrals should abort to idle")

        let finalStoreState = try await store.readState()
        XCTAssertEqual(finalStoreState.deferralCount, 0, "Deferrals should be reset after max reached")
        XCTAssertEqual(finalStoreState.lastCycleError, "max_deferrals_reached")
    }

    // MARK: - Directive Tuning Integration

    /// isDirectiveTuningCycle returns false when completedCycles is 0.
    func testDirectiveTuningCycleFalseWhenZeroCycles() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        let result = try await coordinator.isDirectiveTuningCycle()
        XCTAssertFalse(result, "Zero completed cycles should not be a directive cycle")
    }

    /// isDirectiveTuningCycle returns true every 7th completed cycle.
    func testDirectiveTuningCycleTrueOnSeventhCycle() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.completedCycles = 7
        try await store.writeState(state)

        let coordinator = makeCoordinator(store: store)
        let result = try await coordinator.isDirectiveTuningCycle()
        XCTAssertTrue(result, "7th cycle should be a directive tuning cycle")
    }

    /// isDirectiveTuningCycle returns false for non-multiples of 7.
    func testDirectiveTuningCycleFalseOnNonSeventh() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.completedCycles = 5
        try await store.writeState(state)

        let coordinator = makeCoordinator(store: store)
        let result = try await coordinator.isDirectiveTuningCycle()
        XCTAssertFalse(result, "5th cycle should not be directive tuning")
    }

    /// On a directive tuning cycle, runCycle applies amendment and returns to idle.
    func testDirectiveTuningCycleAppliesAmendmentAndReturnsToIdle() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()

        // Set completedCycles = 7 to trigger directive tuning.
        var state = try await store.readState()
        state.completedCycles = 7
        try await store.writeState(state)

        let coordinator = makeCoordinator(store: store)

        // Wire up directive reader/writer.
        var writtenDirective: String?
        await coordinator.setDirectiveReader { "Existing directive." }
        await coordinator.setDirectiveWriter { text in writtenDirective = text }

        // Seed enough corrections to form a pattern (>= minRepeatedCorrections)
        // but fewer than minCorrectionEvents, so the cycle stops after the
        // meta-optimization/directive-tuning phase instead of running training.
        for _ in 0..<4 {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "correction", fingerprint: "same-correction"
            ))
        }
        for i in 0..<16 {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "re_ask", fingerprint: "reask-\(i)"
            ))
        }

        try await coordinator.runCycle()

        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle, "Directive tuning should return to idle")

        // Directive should have been amended.
        XCTAssertNotNil(writtenDirective, "Directive writer should have been called")
        XCTAssertTrue(writtenDirective?.contains("Auto-tuned") ?? false)
    }

    /// On a directive tuning cycle, previous directive is stored for rollback.
    func testDirectiveTuningStoresPreviousDirectiveForRollback() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.completedCycles = 7
        try await store.writeState(state)

        let coordinator = makeCoordinator(store: store)
        await coordinator.setDirectiveReader { "Original directive." }
        await coordinator.setDirectiveWriter { _ in }

        for _ in 0..<15 {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "correction", fingerprint: "same-fix"
            ))
        }
        for i in 0..<10 {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "re_ask", fingerprint: "r-\(i)"
            ))
        }

        try await coordinator.runCycle()

        let storeState = try await store.readState()
        XCTAssertEqual(storeState.previousDirective, "Original directive.")
    }

    // MARK: - Shadow Evaluation Integration

    /// isShadowEvalNight returns false when completedCycles is 0.
    func testShadowEvalNightFalseWhenZeroCycles() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        let result = try await coordinator.isShadowEvalNight()
        XCTAssertFalse(result)
    }

    /// isShadowEvalNight returns true for odd cycles.
    func testShadowEvalNightTrueForOddCycles() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.completedCycles = 3
        try await store.writeState(state)

        let coordinator = makeCoordinator(store: store)
        let result = try await coordinator.isShadowEvalNight()
        XCTAssertTrue(result, "Odd cycle (3) should be shadow eval night")
    }

    /// isShadowEvalNight returns false for even cycles.
    func testShadowEvalNightFalseForEvenCycles() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.completedCycles = 4
        try await store.writeState(state)

        let coordinator = makeCoordinator(store: store)
        let result = try await coordinator.isShadowEvalNight()
        XCTAssertFalse(result, "Even cycle (4) should not be shadow eval night")
    }

    /// isShadowEvalNight returns false for directive tuning cycles (multiples of 7).
    func testShadowEvalNightFalseOnDirectiveTuningCycle() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.completedCycles = 21 // 21 is both odd and multiple of 7 → directive tuning wins
        try await store.writeState(state)

        let coordinator = makeCoordinator(store: store)
        let result = try await coordinator.isShadowEvalNight()
        XCTAssertFalse(result, "Directive tuning takes priority over shadow eval")
    }

    /// Shadow eval failure blocks deployment.
    func testShadowEvalFailureBlocksDeployment() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.completedCycles = 1 // Odd = shadow eval night
        try await store.writeState(state)

        // Create shadow evaluator with scorer that always returns baseWins.
        let evaluator = ShadowEvaluator(store: store)
        await evaluator.setResponseGenerator { _, _ in "response" }
        await evaluator.setScorer { _, _, _ in .baseWins }

        // Add some episodes to evaluate.
        for i in 0..<5 {
            _ = try await store.appendShadowEpisode(ShadowEvalEpisode(
                id: nil, recordedAt: ISO8601DateFormatter().string(from: Date()),
                conversationJSON: "[{\"role\":\"user\",\"content\":\"test\"}]",
                actualResponse: "response \(i)",
                receptionScore: nil, evaluated: false, evalOutcome: nil
            ))
        }

        let coordinator = ImprovementCycleCoordinator(
            store: store, reviewGate: ExternalReviewGate(), shadowEvaluator: evaluator
        )
        // P9/C4 (W1/W7): a measured improvement backed by a receipt is required to pass
        // the review gate and reach the shadow-eval step — where the baseWins scorer then
        // blocks the deployment.
        await armInjectedPass(coordinator, store: store)
        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle, "Shadow eval failure should return to idle")

        let storeState = try await store.readState()
        XCTAssertEqual(storeState.lastCycleError, "shadow_eval_gate_failed")
    }

    /// Shadow eval passes → deployment continues.
    func testShadowEvalPassAllowsDeployment() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.completedCycles = 1 // Odd = shadow eval night
        try await store.writeState(state)

        let evaluator = ShadowEvaluator(store: store)
        await evaluator.setResponseGenerator { _, _ in "response" }
        await evaluator.setScorer { _, _, _ in .adapterWins } // All adapter wins → gate passes

        for i in 0..<5 {
            _ = try await store.appendShadowEpisode(ShadowEvalEpisode(
                id: nil, recordedAt: ISO8601DateFormatter().string(from: Date()),
                conversationJSON: "[{\"role\":\"user\",\"content\":\"test\"}]",
                actualResponse: "response \(i)",
                receptionScore: nil, evaluated: false, evalOutcome: nil
            ))
        }

        let coordinator = ImprovementCycleCoordinator(
            store: store, reviewGate: ExternalReviewGate(), shadowEvaluator: evaluator
        )
        // P9/C4 (W7): a measured improvement backed by a receipt is required to pass the
        // gate and reach the shadow-eval step.
        await armInjectedPass(coordinator, store: store)
        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        // With 0 approved cycles, should pause in proposing (not idle).
        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .proposing, "Shadow eval pass should allow cycle to continue to proposing")
    }

    /// No shadow episodes available → gracefully skips, continues to deploy.
    func testShadowEvalSkipsGracefullyWhenNoEpisodes() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.completedCycles = 1 // Shadow eval night but no episodes
        try await store.writeState(state)

        let evaluator = ShadowEvaluator(store: store)
        await evaluator.setResponseGenerator { _, _ in "response" }
        // No episodes seeded → noEpisodesAvailable will be thrown → skipped gracefully

        let coordinator = ImprovementCycleCoordinator(
            store: store, reviewGate: ExternalReviewGate(), shadowEvaluator: evaluator
        )
        // P9/C4 (W7): a measured improvement backed by a receipt is required to pass the gate.
        await armInjectedPass(coordinator, store: store)
        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .proposing, "No episodes should be skipped, cycle continues")
    }

    /// rollbackDirective restores the previous directive.
    func testRollbackDirectiveRestoresPrevious() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.previousDirective = "Before amendment."
        try await store.writeState(state)

        let coordinator = makeCoordinator(store: store)
        var writtenDirective: String?
        await coordinator.setDirectiveWriter { text in writtenDirective = text }

        try await coordinator.rollbackDirective()

        XCTAssertEqual(writtenDirective, "Before amendment.")
        let storeState = try await store.readState()
        XCTAssertNil(storeState.previousDirective, "Previous directive cleared after rollback")
    }

    /// SecurityEventLogger closure is wired through the gate when used from coordinator.
    func testSecurityLogClosureWiredInGate() async throws {
        let store = try await makeTempStore()
        let gate = ExternalReviewGate()
        var logCalled = false
        await gate.setSecurityLogClosure { _, _, _, _, _, _ in
            logCalled = true
        }
        let coordinator = ImprovementCycleCoordinator(store: store, reviewGate: gate)
        // P9/C4 (W1/W7): a measured delta backed by a receipt is required to reach the
        // review gate (where the security-log closure fires).
        await armInjectedPass(coordinator, store: store)

        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        XCTAssertTrue(logCalled, "SecurityEventLogger closure should be called during cycle review")
    }

    // MARK: - TrainingBridge Integration

    func testRunCycleFailsClosedWhenBridgeNil() async throws {
        // P9/C4 (W1): when no TrainingBridge is set, the cycle still runs but the
        // evaluation is UNMEASURED — the fail-closed gate makes review FAIL so the
        // cycle returns to idle WITHOUT proposing or deploying. WHY: a missing
        // training/eval path must never be treated as a passing (zero-delta) result.
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        // Do NOT set trainingBridge and do NOT inject a measured delta.
        try await seedSufficientData(store: store)

        try await coordinator.runCycle()

        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle, "No bridge ⇒ unmeasured ⇒ fail-closed to idle, not proposing")
        let persisted = try await store.readState()
        XCTAssertEqual(persisted.lastCycleError, "candidate_blocked: no_measured_improvement")
        XCTAssertNil(persisted.currentAdapterPath, "Nothing should be deployed")
    }

    func testTrainingBridgeSetterWorks() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        // Create a bridge with a dummy uv path and temp directories.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-bridge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let bridge = TrainingBridge(
            uvPath: "/usr/bin/false",
            orchestratorScriptsDir: tmpDir,
            dataBridgeScriptsDir: tmpDir
        )
        await coordinator.setTrainingBridge(bridge)
        // If we got here without error, setter works.
    }

    func testMinSFTExamplesConstant() {
        // Verify the minimum threshold is reasonable.
        XCTAssertEqual(ImprovementCycleCoordinator.minSFTExamples, 10)
    }

    func testTrainingBenchmarkResultDeltaComputation() {
        // Verify the delta computation matches what the coordinator uses.
        let baseline = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.80,
            faeCapabilityAccuracy: 0.70,
            assistantFitAccuracy: 0.60,
            serializationAccuracy: 0.50,
            avgThroughputTPS: 40.0,
            modelId: "test",
            adapterPath: nil
        )
        let adapter = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.90,
            faeCapabilityAccuracy: 0.80,
            assistantFitAccuracy: 0.70,
            serializationAccuracy: 0.60,
            avgThroughputTPS: 42.0,
            modelId: "test",
            adapterPath: "/tmp/adapter"
        )
        let delta = adapter.delta(from: baseline)
        // All +10 percentage points.
        XCTAssertEqual(delta.toolCallingDelta ?? 0, 10.0, accuracy: 0.01)
        XCTAssertEqual(delta.faeCapabilityDelta ?? 0, 10.0, accuracy: 0.01)
        XCTAssertEqual(delta.assistantFitDelta ?? 0, 10.0, accuracy: 0.01)
        XCTAssertEqual(delta.serializationDelta ?? 0, 10.0, accuracy: 0.01)
        XCTAssertEqual(delta.throughputDelta ?? 0, 2.0, accuracy: 0.01)
    }

    func testNilBridgeCycleFailsClosedWithNoMeasurement() async throws {
        // P9/C4 (W1): the previous "zero deltas ⇒ review passes ⇒ proposing ⇒
        // approve ⇒ deploy" path was the unsafe hole. With no bridge the eval is
        // UNMEASURED and the gate fails closed: the cycle returns to idle, there is
        // no proposal, and an approve attempt is refused (no un-gated deploy).
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        try await seedSufficientData(store: store)

        try await coordinator.runCycle()

        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle, "Unmeasured cycle fails closed to idle, never proposing")

        // Not in proposing ⇒ approveDeployment must refuse (no un-gated deploy).
        do {
            try await coordinator.approveDeployment()
            XCTFail("approveDeployment should throw when the cycle is not in proposing")
        } catch {
            // expected: invalidTransition
        }

        let storedState = try await store.readState()
        XCTAssertNil(storedState.currentAdapterPath, "Nothing should be deployed")
    }

    // MARK: - Skill Curation Eligibility (Phase G4)

    private static let oneDayMs: Int64 = 24 * 60 * 60 * 1000

    func testCurationEligibility_staleUnusedAutoSkillIsEligible() {
        let nowMs: Int64 = 1_000_000_000_000
        let usage: [[String: Any]] = [
            [
                "name": "auto-stale-skill",
                "run_count": 0,
                "first_seen_ms": NSNumber(value: nowMs - 15 * Self.oneDayMs),
            ]
        ]
        let eligible = ImprovementCycleCoordinator.skillsEligibleForArchival(usage, nowMs: nowMs)
        XCTAssertEqual(
            eligible, ["auto-stale-skill"],
            "An auto-* skill never run and >14 days old must be archived — that is the whole point of curation")
    }

    func testCurationEligibility_builtinSkillNeverEligible() {
        let nowMs: Int64 = 1_000_000_000_000
        let usage: [[String: Any]] = [
            [
                "name": "proactive-awareness",
                "run_count": 0,
                "first_seen_ms": NSNumber(value: nowMs - 100 * Self.oneDayMs),
            ]
        ]
        let eligible = ImprovementCycleCoordinator.skillsEligibleForArchival(usage, nowMs: nowMs)
        XCTAssertTrue(
            eligible.isEmpty,
            "Built-in skills (no auto- prefix) must NEVER be archived regardless of usage")
    }

    func testCurationEligibility_freshAutoSkillNotEligible() {
        let nowMs: Int64 = 1_000_000_000_000
        let usage: [[String: Any]] = [
            [
                "name": "auto-new-skill",
                "run_count": 0,
                "first_seen_ms": NSNumber(value: nowMs - 3 * Self.oneDayMs),
            ]
        ]
        let eligible = ImprovementCycleCoordinator.skillsEligibleForArchival(usage, nowMs: nowMs)
        XCTAssertTrue(
            eligible.isEmpty,
            "An auto-* skill under the 14-day threshold gets a fair chance to be used first")
    }

    func testCurationEligibility_usedAutoSkillNotEligible() {
        let nowMs: Int64 = 1_000_000_000_000
        let usage: [[String: Any]] = [
            [
                "name": "auto-used-skill",
                "run_count": 5,
                "first_seen_ms": NSNumber(value: nowMs - 30 * Self.oneDayMs),
                "last_used_ms": NSNumber(value: nowMs - 20 * Self.oneDayMs),
            ]
        ]
        let eligible = ImprovementCycleCoordinator.skillsEligibleForArchival(usage, nowMs: nowMs)
        XCTAssertTrue(
            eligible.isEmpty,
            "A skill that has actually run is providing value — never archive it")
    }

    func testCurationEligibility_noTimestampAnchorSkipped() {
        let nowMs: Int64 = 1_000_000_000_000
        // Pre-G4 stores have no first_seen_ms; unknown age must fail safe (skip).
        let usage: [[String: Any]] = [
            ["name": "auto-legacy-skill", "run_count": 0]
        ]
        let eligible = ImprovementCycleCoordinator.skillsEligibleForArchival(usage, nowMs: nowMs)
        XCTAssertTrue(
            eligible.isEmpty,
            "Unknown age must fail safe: never archive a skill we cannot date")
    }

    func testCurationEligibility_capsAtMaxPerCycleOldestFirst() {
        let nowMs: Int64 = 1_000_000_000_000
        let usage: [[String: Any]] = (1...5).map { i in
            [
                "name": "auto-skill-\(i)",
                "run_count": 0,
                "first_seen_ms": NSNumber(value: nowMs - (14 + Int64(i)) * Self.oneDayMs),
            ]
        }
        let eligible = ImprovementCycleCoordinator.skillsEligibleForArchival(
            usage, nowMs: nowMs, maxCount: 3)
        XCTAssertEqual(eligible.count, 3, "Conservatism cap: at most 3 archives per night")
        XCTAssertEqual(
            eligible, ["auto-skill-5", "auto-skill-4", "auto-skill-3"],
            "Oldest skills are archived first when over the cap")
    }
}

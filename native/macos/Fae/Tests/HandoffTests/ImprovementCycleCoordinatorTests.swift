import XCTest
@testable import Fae

final class ImprovementCycleCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempStore() async throws -> ImprovementStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("improvement.db")
        let store = ImprovementStore()
        try await store.open(at: url)
        return store
    }

    private func makeCoordinator(store: ImprovementStore) -> ImprovementCycleCoordinator {
        ImprovementCycleCoordinator(store: store)
    }

    /// A measured improvement delta (all +5pp). Drives the P9/C4 gate to PASS in
    /// tests that exercise the proposing/deploy path, standing in for a real
    /// FaeBenchmark result until W7 wires the `AdapterEvaluator`.
    private func measuredImprovement() -> EvalDelta {
        EvalDelta(
            toolCallingDelta: 5.0, faeCapabilityDelta: 5.0,
            assistantFitDelta: 5.0, serializationDelta: 5.0, throughputDelta: 1.0
        )
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
        // P9/C4: a real measured improvement is required to pass the gate.
        await coordinator.setInjectedMeasuredDelta(measuredImprovement())
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
        try await store.ensureStateRow()
        // P9/C4 (W3): seed a pending candidate (as the training step would) so the
        // approve path has something to promote to currentAdapterPath.
        var seed = try await store.readState()
        seed.currentAdapterPath = "/tmp/prior_deployed"
        seed.pendingAdapterPath = "/tmp/candidate_adapter"
        try await store.writeState(seed)
        let coordinator = makeCoordinator(store: store)

        // Manually drive to proposing state (simulates end of runCycle).
        for state in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: state)
        }
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
        XCTAssertEqual(storeState.currentAdapterPath, "/tmp/candidate_adapter", "Candidate promoted to deployed")
        XCTAssertEqual(storeState.previousAdapterPath, "/tmp/prior_deployed", "Prior becomes rollback target")
        XCTAssertNil(storeState.pendingAdapterPath, "Pending cleared after deploy")
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
        // P9/C4 (W1): a measured delta is required to reach the external review gate
        // (an unmeasured candidate is blocked before review).
        await coordinator.setInjectedMeasuredDelta(measuredImprovement())

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
        // P9/C4 (W1): reach the external review gate with a measured delta.
        await coordinator.setInjectedMeasuredDelta(measuredImprovement())

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
        // P9/C4 (W1): reach the external review gate with a measured delta.
        await coordinator.setInjectedMeasuredDelta(measuredImprovement())

        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        // With 0 user-approved cycles, should pause in proposing.
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .proposing, "PASS should continue to proposing")

        let storeState = try await store.readState()
        XCTAssertEqual(storeState.deferralCount, 0, "Deferrals should be reset on PASS")
    }

    /// Multiple CONCERN deferrals accumulate until max is reached.
    func testDeferralsAccumulateAcrossCycles() async throws {
        let store = try await makeTempStore()
        let gate = ExternalReviewGate()
        await gate.setDelegateAgentRunner { _ in
            "CONCERN: Minor issue detected."
        }
        let coordinator = ImprovementCycleCoordinator(store: store, reviewGate: gate)
        // P9/C4 (W1): reach the external review gate with a measured delta.
        await coordinator.setInjectedMeasuredDelta(measuredImprovement())

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
        // P9/C4 (W1): a measured delta is required to reach the review gate, where
        // the max-deferrals check then fires.
        await coordinator.setInjectedMeasuredDelta(measuredImprovement())
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
        // P9/C4 (W1): a real measured improvement is required to pass the review
        // gate and reach the shadow-eval step — where the baseWins scorer then
        // blocks the deployment.
        await coordinator.setInjectedMeasuredDelta(measuredImprovement())
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
        // P9/C4: a real measured improvement is required to pass the gate and
        // reach the shadow-eval step.
        await coordinator.setInjectedMeasuredDelta(measuredImprovement())
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
        // P9/C4: a real measured improvement is required to pass the gate.
        await coordinator.setInjectedMeasuredDelta(measuredImprovement())
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
        // P9/C4 (W1): a measured delta is required to reach the review gate (where
        // the security-log closure fires).
        await coordinator.setInjectedMeasuredDelta(measuredImprovement())

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
}

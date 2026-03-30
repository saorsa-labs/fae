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
        try await coordinator.transition(to: .training)

        let storeState = try await store.readState()
        XCTAssertNotNil(storeState.trainingStartedAt)
    }

    // MARK: - Approval Flow (Phase 2.3)

    /// approveDeployment() increments userApprovedCycles and returns to idle.
    func testApproveDeploymentIncrementsApprovedCycles() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        // Manually drive to proposing state (simulates end of runCycle).
        for state in [CycleState.collecting, .training, .evaluating, .proposing] {
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
    }

    /// rejectDeployment() returns to idle without incrementing userApprovedCycles.
    func testRejectDeploymentReturnsToIdleWithoutApproval() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        for state in [CycleState.collecting, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: state)
        }

        try await coordinator.rejectDeployment()

        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle)

        let storeState = try await store.readState()
        XCTAssertEqual(storeState.userApprovedCycles, 0, "Rejection must not increment userApprovedCycles")
        XCTAssertEqual(storeState.completedCycles, 1, "completedCycles should still increment")
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

    /// runCycle() pauses in proposing when userApprovedCycles < 5.
    func testRunCyclePausesInProposingBeforeEarningAutoDeploy() async throws {
        let store = try await makeTempStore()
        let coordinator = makeCoordinator(store: store)
        try await seedSufficientData(store: store)

        try await coordinator.runCycle()

        // Should be paused in proposing (needs user approval).
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .proposing, "Cycle should pause in proposing until 5 approvals earned")
    }

    /// runCycle() auto-deploys when userApprovedCycles >= 5.
    func testRunCycleAutoDeploysAfterFiveApprovedCycles() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        let coordinator = makeCoordinator(store: store)

        // Seed 5 prior approved cycles to earn auto-deploy.
        var state = try await store.readState()
        state.userApprovedCycles = 5
        try await store.writeState(state)

        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        // Should complete without pausing in proposing.
        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle, "Auto-deploy should return to idle without user input")
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
        // No delegate runner → falls through to internal review with neutral deltas → PASS.
        // But first we set deferralCount to 3 (the max) to trigger maxDeferralsReached.
        var storeState = try await store.readState()
        storeState.deferralCount = ExternalReviewGate.maxDeferrals
        try await store.writeState(storeState)

        let coordinator = ImprovementCycleCoordinator(store: store, reviewGate: gate)
        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle, "Max deferrals should abort to idle")

        let finalStoreState = try await store.readState()
        XCTAssertEqual(finalStoreState.deferralCount, 0, "Deferrals should be reset after max reached")
        XCTAssertEqual(finalStoreState.lastCycleError, "max_deferrals_reached")
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

        try await seedSufficientData(store: store)
        try await coordinator.runCycle()

        XCTAssertTrue(logCalled, "SecurityEventLogger closure should be called during cycle review")
    }
}

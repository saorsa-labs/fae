import XCTest
@testable import Fae

/// Integration tests for the full autonomous self-improvement loop.
///
/// These tests exercise end-to-end paths across multiple subsystems:
/// - ImprovementStore CRUD
/// - ImprovementCycleCoordinator state machine
/// - DirectiveFastTuner pattern detection + amendment
/// - ShadowEvaluator episode replay + promotion gate
/// - ExternalReviewGate fallback chain
final class ImprovementLoopIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempStore() async throws -> ImprovementStore {
        let store = ImprovementStore()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("integration_test_\(UUID().uuidString).db")
        try await store.open(at: url)
        try await store.ensureStateRow()
        return store
    }

    private func makeEvent(signalType: String, fingerprint: String) -> FeedbackEvent {
        FeedbackEvent(
            id: nil,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            signalType: signalType,
            turnFingerprint: fingerprint,
            userInput: "user input",
            assistantOutput: "assistant output",
            sentimentScore: nil,
            consumed: false
        )
    }

    private func seedEvents(store: ImprovementStore, corrections: Int, reasksAndOthers: Int) async throws {
        for i in 0..<corrections {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "correction", fingerprint: "c-\(i)"
            ))
        }
        for i in 0..<reasksAndOthers {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "re_ask", fingerprint: "r-\(i)"
            ))
        }
    }

    // MARK: - Feedback → Store → Cycle Round-Trip

    func testFeedbackEventsAccumulateAndCycleConsumesTool() async throws {
        let store = try await makeTempStore()

        // Seed more than minimum thresholds (20 events, 5 corrections).
        try await seedEvents(store: store, corrections: 8, reasksAndOthers: 15)

        let pending = try await store.pendingFeedbackEvents()
        XCTAssertGreaterThanOrEqual(pending.count, 20)
        XCTAssertGreaterThanOrEqual(
            pending.filter { $0.signalType == "correction" }.count, 5
        )

        let coordinator = ImprovementCycleCoordinator(store: store)
        try await coordinator.runCycle()

        // After cycle runs, events should be consumed.
        let remaining = try await store.pendingFeedbackEvents()
        XCTAssertLessThan(
            remaining.count,
            pending.count,
            "Cycle should have consumed feedback events"
        )
    }

    func testCycleStateTransitionsInOrder() async throws {
        let store = try await makeTempStore()
        try await seedEvents(store: store, corrections: 8, reasksAndOthers: 15)

        let coordinator = ImprovementCycleCoordinator(store: store)

        // P9/C4 (W1): with no evaluator wired, the cycle is fail-closed (unmeasured
        // ⇒ blocked before review) and ends in .idle — NOT proposing. This exact
        // assertion would catch a regression where an unmeasured cycle reaches
        // proposing again.
        try await coordinator.runCycle()
        let finalState = try await coordinator.currentState()
        XCTAssertEqual(finalState, .idle, "Unmeasured cycle must fail closed to idle, not proposing")
    }

    // MARK: - Directive Tuning Round-Trip

    func testDirectiveTuningCycleAmendsThenRollback() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()

        // Set completedCycles = 7 to trigger directive tuning.
        var state = try await store.readState()
        state.completedCycles = 7
        try await store.writeState(state)

        var writtenText = ""
        var rollbackText = ""

        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setDirectiveReader { "My original directive." }
        await coordinator.setDirectiveWriter { text in writtenText = text }

        // Seed enough corrections (>= 5) and re_asks to meet thresholds.
        for i in 0..<10 {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "correction", fingerprint: "corr-\(i)"
            ))
        }
        for i in 0..<15 {
            _ = try await store.appendFeedbackEvent(makeEvent(
                signalType: "re_ask", fingerprint: "reask-\(i)"
            ))
        }

        try await coordinator.runCycle()

        // An amendment should have been applied.
        XCTAssertFalse(writtenText.isEmpty, "Directive writer should have been called")

        // Now rollback — directive should be restored to "My original directive."
        await coordinator.setDirectiveWriter { text in rollbackText = text }
        try await coordinator.rollbackDirective()

        XCTAssertEqual(rollbackText, "My original directive.", "Rollback should restore original directive")
    }

    // MARK: - Shadow Eval Round-Trip

    func testShadowEvalEpisodesStoredAndReplayed() async throws {
        let store = try await makeTempStore()

        // Record 5 episodes.
        for i in 0..<5 {
            let episode = ShadowEvalEpisode(
                id: nil,
                recordedAt: ISO8601DateFormatter().string(from: Date()),
                conversationJSON: "[{\"role\":\"user\",\"content\":\"question \(i)\"}]",
                actualResponse: "response \(i)",
                receptionScore: nil,
                evaluated: false,
                evalOutcome: nil
            )
            _ = try await store.appendShadowEpisode(episode)
        }

        let unevaluated = try await store.unevaluatedEpisodes(limit: 10)
        XCTAssertEqual(unevaluated.count, 5, "All 5 unevaluated episodes should be returned")

        // Run shadow evaluation — adapter wins all.
        let evaluator = ShadowEvaluator(store: store)
        await evaluator.setResponseGenerator { _, adapterPath in
            adapterPath == nil ? "long base response here" : "short adapter"
        }
        // Force adapter wins via injected scorer.
        await evaluator.setScorer { _, _, _ in .adapterWins }

        let result = try await evaluator.runEvaluation(ignoreWindow: true)

        XCTAssertEqual(result.episodesEvaluated, 5)
        XCTAssertEqual(result.adapterWinRate, 1.0, accuracy: 0.01)
        XCTAssertTrue(result.promotionGatePassed)

        // All episodes should now be marked evaluated.
        let remaining = try await store.unevaluatedEpisodes(limit: 10)
        XCTAssertEqual(remaining.count, 0, "All episodes should be marked evaluated")

        let counts = try await store.shadowEvalCounts()
        XCTAssertEqual(counts.adapterWins, 5)
    }

    // MARK: - External Review Gate Round-Trip

    func testReviewGateWithDelegate() async throws {
        let gate = ExternalReviewGate()
        await gate.setDelegateAgentRunner { _ in "PASS: all metrics improved" }

        let evalDelta = EvalDelta(
            toolCallingDelta: 2.0,
            faeCapabilityDelta: 1.5,
            assistantFitDelta: 3.0,
            serializationDelta: 0.5,
            throughputDelta: nil
        )

        let result = try await gate.review(evalDelta: evalDelta, currentDeferralCount: 0)
        XCTAssertEqual(result.verdict, .pass)
        XCTAssertEqual(result.provider, .codex)
    }

    func testReviewGateFallsBackToInternalOnError() async throws {
        let gate = ExternalReviewGate()
        // No delegate agent runner → falls through to internal review.

        let evalDelta = EvalDelta(
            toolCallingDelta: 1.0,
            faeCapabilityDelta: 1.0,
            assistantFitDelta: 1.0,
            serializationDelta: 0.0,
            throughputDelta: nil
        )

        let result = try await gate.review(evalDelta: evalDelta, currentDeferralCount: 0)
        XCTAssertEqual(result.provider, .internalSelfReview)
        XCTAssertEqual(result.verdict, .pass)
    }

    // MARK: - Adapter Path State Persistence

    func testAdapterPathPersistedThroughApproveAndRollback() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()

        // Post-training proposing state (P9/C4 W3): a deployed adapter in
        // currentAdapterPath + the candidate in pendingAdapterPath. A real cycle can
        // only produce a pending via the training bridge (W7/W8), so set it up
        // directly here and exercise the approve → rollback lineage.
        var state = try await store.readState()
        state.currentAdapterPath = "/tmp/old_adapter"
        state.pendingAdapterPath = "/tmp/new_candidate"
        try await store.writeState(state)

        var patchedPath: String? = "not-called"
        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setAdapterPatchCallback { path in patchedPath = path }
        for s in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: s)
        }

        try await coordinator.approveDeployment()

        // After approval: candidate promoted to current, prior is the rollback target,
        // pending cleared, pipeline notified.
        let deployed = try await store.readState()
        XCTAssertEqual(deployed.currentAdapterPath, "/tmp/new_candidate", "Candidate promoted on deploy")
        XCTAssertEqual(deployed.previousAdapterPath, "/tmp/old_adapter", "Prior is the rollback target")
        XCTAssertNil(deployed.pendingAdapterPath, "Pending cleared after deploy")
        XCTAssertEqual(patchedPath, "/tmp/new_candidate", "Pipeline notified of the deployed adapter")

        // Rollback returns to the prior deployed adapter (lineage preserved — the W3
        // split fixed the bug where previous was set to the candidate itself).
        try await coordinator.rollback()
        let rolledBack = try await store.readState()
        XCTAssertEqual(rolledBack.currentAdapterPath, "/tmp/old_adapter", "Rollback restores the prior deployed adapter")
        XCTAssertEqual(rolledBack.previousAdapterPath, "/tmp/new_candidate", "Swap is symmetric")
    }

    // MARK: - isDirectiveTuningCycle Logic

    func testDirectiveTuningCycleIntervalIsCorrect() {
        XCTAssertEqual(
            ImprovementCycleCoordinator.directiveTuningInterval,
            7,
            "Directive tuning should run every 7th cycle"
        )
    }

    func testDirectiveTuningCycleMathAtVariousMultiples() async throws {
        let store = try await makeTempStore()

        let multiples = [7, 14, 21, 35]
        for count in multiples {
            var state = try await store.readState()
            state.completedCycles = count
            try await store.writeState(state)

            let coordinator = ImprovementCycleCoordinator(store: store)
            let result = try await coordinator.isDirectiveTuningCycle()
            XCTAssertTrue(result, "\(count) is a multiple of 7, should be directive cycle")
        }

        let nonMultiples = [1, 5, 6, 8, 13, 20]
        for count in nonMultiples {
            var state = try await store.readState()
            state.completedCycles = count
            try await store.writeState(state)

            let coordinator = ImprovementCycleCoordinator(store: store)
            let result = try await coordinator.isDirectiveTuningCycle()
            XCTAssertFalse(result, "\(count) is not a multiple of 7, should not be directive cycle")
        }
    }
}

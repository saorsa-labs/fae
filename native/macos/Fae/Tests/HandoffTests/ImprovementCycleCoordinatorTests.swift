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

        // Should be back to idle after completing the cycle.
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle)

        // Completed cycles should be incremented.
        let storeState = try await store.readState()
        XCTAssertEqual(storeState.completedCycles, 1)
        XCTAssertNotNil(storeState.lastCycleAt)

        // Events should be consumed.
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
}

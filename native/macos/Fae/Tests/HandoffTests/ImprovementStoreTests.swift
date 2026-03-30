import XCTest
@testable import Fae

final class ImprovementStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Create a fresh ImprovementStore backed by a temp database.
    private func makeTempStore() async throws -> (ImprovementStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("improvement.db")
        let store = ImprovementStore()
        try await store.open(at: url)
        return (store, url)
    }

    private func makeEvent(
        signalType: String = "correction",
        fingerprint: String = "abc123",
        consumed: Bool = false
    ) -> FeedbackEvent {
        FeedbackEvent(
            id: nil,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            signalType: signalType,
            turnFingerprint: fingerprint,
            userInput: "test input",
            assistantOutput: "test output",
            sentimentScore: 0.5,
            consumed: consumed
        )
    }

    // MARK: - Lifecycle

    func testOpenIsIdempotent() async throws {
        let (store, url) = try await makeTempStore()
        // Second open should be a no-op (guard db == nil).
        try await store.open(at: url)
        // If we got here without error, idempotency works.
    }

    // MARK: - FeedbackEvent CRUD

    func testAppendFeedbackEventReturnsID() async throws {
        let (store, _) = try await makeTempStore()
        let event = makeEvent()
        let stored = try await store.appendFeedbackEvent(event)
        XCTAssertNotNil(stored.id, "Inserted event should have a non-nil ID")
        XCTAssertGreaterThan(stored.id ?? 0, 0)
    }

    func testPendingFeedbackEventsReturnsOnlyUnconsumed() async throws {
        let (store, _) = try await makeTempStore()
        _ = try await store.appendFeedbackEvent(makeEvent(fingerprint: "a"))
        _ = try await store.appendFeedbackEvent(makeEvent(fingerprint: "b"))
        let consumed = makeEvent(fingerprint: "c")
        let storedConsumed = try await store.appendFeedbackEvent(consumed)
        try await store.markConsumed(ids: [storedConsumed.id ?? 0])

        let pending = try await store.pendingFeedbackEvents()
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy { !$0.consumed })
    }

    func testMarkConsumedFlipsFlag() async throws {
        let (store, _) = try await makeTempStore()
        let stored = try await store.appendFeedbackEvent(makeEvent())
        let eventID = stored.id ?? 0
        try await store.markConsumed(ids: [eventID])

        let pending = try await store.pendingFeedbackEvents()
        XCTAssertTrue(pending.isEmpty)
    }

    func testMarkConsumedWithEmptyArrayIsNoOp() async throws {
        let (store, _) = try await makeTempStore()
        _ = try await store.appendFeedbackEvent(makeEvent())
        try await store.markConsumed(ids: [])
        let pending = try await store.pendingFeedbackEvents()
        XCTAssertEqual(pending.count, 1)
    }

    func testPendingFeedbackCountReturnsCorrectCount() async throws {
        let (store, _) = try await makeTempStore()
        let initialCount = try await store.pendingFeedbackCount()
        XCTAssertEqual(initialCount, 0)
        _ = try await store.appendFeedbackEvent(makeEvent(fingerprint: "a"))
        _ = try await store.appendFeedbackEvent(makeEvent(fingerprint: "b"))
        let afterCount = try await store.pendingFeedbackCount()
        XCTAssertEqual(afterCount, 2)
    }

    // MARK: - ImprovementBaseline CRUD

    func testInsertBaselineReturnsID() async throws {
        let (store, _) = try await makeTempStore()
        let baseline = ImprovementBaseline(
            id: nil,
            measuredAt: ISO8601DateFormatter().string(from: Date()),
            modelID: "test-model",
            adapterPath: nil,
            adapterVersion: nil,
            toolCallingAccuracy: 95.0,
            faeCapabilityAccuracy: 90.0,
            assistantFitAccuracy: 85.0,
            serializationAccuracy: 100.0,
            avgThroughputTPS: 42.0,
            feedbackEventCount: 10
        )
        let stored = try await store.insertBaseline(baseline)
        XCTAssertNotNil(stored.id)
    }

    func testLatestBaselineReturnsMostRecent() async throws {
        let (store, _) = try await makeTempStore()
        let older = ImprovementBaseline(
            id: nil,
            measuredAt: "2026-01-01T00:00:00Z",
            modelID: "test-model",
            adapterPath: nil, adapterVersion: nil,
            toolCallingAccuracy: 80.0,
            faeCapabilityAccuracy: nil, assistantFitAccuracy: nil,
            serializationAccuracy: nil, avgThroughputTPS: nil,
            feedbackEventCount: 5
        )
        let newer = ImprovementBaseline(
            id: nil,
            measuredAt: "2026-03-30T00:00:00Z",
            modelID: "test-model",
            adapterPath: "/path/to/adapter", adapterVersion: "cycle-2",
            toolCallingAccuracy: 95.0,
            faeCapabilityAccuracy: nil, assistantFitAccuracy: nil,
            serializationAccuracy: nil, avgThroughputTPS: nil,
            feedbackEventCount: 20
        )
        _ = try await store.insertBaseline(older)
        _ = try await store.insertBaseline(newer)

        let latest = try await store.latestBaseline(for: "test-model")
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.toolCallingAccuracy, 95.0)
        XCTAssertEqual(latest?.adapterVersion, "cycle-2")
    }

    func testLatestBaselineReturnsNilForUnknownModel() async throws {
        let (store, _) = try await makeTempStore()
        let result = try await store.latestBaseline(for: "nonexistent-model")
        XCTAssertNil(result)
    }

    // MARK: - ImprovementState CRUD

    func testEnsureStateRowCreatesIdleSingleton() async throws {
        let (store, _) = try await makeTempStore()
        try await store.ensureStateRow()
        let state = try await store.readState()
        XCTAssertEqual(state.cycleState, "idle")
        XCTAssertEqual(state.completedCycles, 0)
        XCTAssertEqual(state.userApprovedCycles, 0)
        XCTAssertNil(state.currentAdapterPath)
    }

    func testEnsureStateRowIsIdempotent() async throws {
        let (store, _) = try await makeTempStore()
        try await store.ensureStateRow()
        try await store.ensureStateRow()
        // Should still have exactly one row -- no duplicates.
        let state = try await store.readState()
        XCTAssertEqual(state.cycleState, "idle")
    }

    func testWriteStatePersistsChanges() async throws {
        let (store, _) = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.cycleState = "training"
        state.completedCycles = 3
        state.currentAdapterPath = "/adapters/cycle-3"
        try await store.writeState(state)

        let reread = try await store.readState()
        XCTAssertEqual(reread.cycleState, "training")
        XCTAssertEqual(reread.completedCycles, 3)
        XCTAssertEqual(reread.currentAdapterPath, "/adapters/cycle-3")
    }

    func testWriteStateRoundTrip() async throws {
        let (store, _) = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.cycleState = "evaluating"
        state.userApprovedCycles = 5
        state.previousAdapterPath = "/adapters/old"
        state.trainingStartedAt = "2026-03-30T02:00:00Z"
        state.lastCycleError = "timeout"
        try await store.writeState(state)

        let roundTripped = try await store.readState()
        XCTAssertEqual(roundTripped.cycleState, "evaluating")
        XCTAssertEqual(roundTripped.userApprovedCycles, 5)
        XCTAssertEqual(roundTripped.previousAdapterPath, "/adapters/old")
        XCTAssertEqual(roundTripped.trainingStartedAt, "2026-03-30T02:00:00Z")
        XCTAssertEqual(roundTripped.lastCycleError, "timeout")
    }

    // MARK: - CapabilityGap CRUD

    func testInsertGapAndUnaddressedGapsPriorityOrdering() async throws {
        let (store, _) = try await makeTempStore()
        let low = CapabilityGap(
            id: nil, detectedAt: "2026-03-01T00:00:00Z",
            category: "tone", description: "Too formal",
            evidenceCount: 2, priority: "low", addressed: false
        )
        let high = CapabilityGap(
            id: nil, detectedAt: "2026-03-02T00:00:00Z",
            category: "tool_calling", description: "Wrong tool selected",
            evidenceCount: 8, priority: "high", addressed: false
        )
        let medium = CapabilityGap(
            id: nil, detectedAt: "2026-03-03T00:00:00Z",
            category: "memory", description: "Forgot user preference",
            evidenceCount: 4, priority: "medium", addressed: false
        )
        _ = try await store.insertGap(low)
        _ = try await store.insertGap(high)
        _ = try await store.insertGap(medium)

        let gaps = try await store.unaddressedGaps()
        XCTAssertEqual(gaps.count, 3)
        XCTAssertEqual(gaps[0].priority, "high")
        XCTAssertEqual(gaps[1].priority, "medium")
        XCTAssertEqual(gaps[2].priority, "low")
    }

    func testMarkGapAddressedExcludesFromUnaddressed() async throws {
        let (store, _) = try await makeTempStore()
        let gap = CapabilityGap(
            id: nil, detectedAt: "2026-03-01T00:00:00Z",
            category: "tone", description: "Too formal",
            evidenceCount: 2, priority: "medium", addressed: false
        )
        let stored = try await store.insertGap(gap)
        try await store.markGapAddressed(id: stored.id ?? 0)

        let unaddressed = try await store.unaddressedGaps()
        XCTAssertTrue(unaddressed.isEmpty)
    }

    // MARK: - ShadowEvalEpisode CRUD

    func testAppendShadowEpisodeStoresEpisode() async throws {
        let (store, _) = try await makeTempStore()
        let episode = ShadowEvalEpisode(
            id: nil,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            conversationJSON: "[{\"role\":\"user\",\"content\":\"hello\"}]",
            actualResponse: "Hi there!",
            receptionScore: 0.8,
            evaluated: false,
            evalOutcome: nil
        )
        let stored = try await store.appendShadowEpisode(episode)
        XCTAssertNotNil(stored.id)
    }

    func testUnevaluatedEpisodesRespectsLimit() async throws {
        let (store, _) = try await makeTempStore()
        for i in 0..<5 {
            let episode = ShadowEvalEpisode(
                id: nil,
                recordedAt: "2026-03-30T0\(i):00:00Z",
                conversationJSON: "[]",
                actualResponse: "response \(i)",
                receptionScore: nil,
                evaluated: false,
                evalOutcome: nil
            )
            _ = try await store.appendShadowEpisode(episode)
        }

        let limited = try await store.unevaluatedEpisodes(limit: 3)
        XCTAssertEqual(limited.count, 3)
    }

    func testRecordEvalOutcomeMarksEvaluated() async throws {
        let (store, _) = try await makeTempStore()
        let episode = ShadowEvalEpisode(
            id: nil,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            conversationJSON: "[]",
            actualResponse: "test",
            receptionScore: nil,
            evaluated: false,
            evalOutcome: nil
        )
        let stored = try await store.appendShadowEpisode(episode)
        let episodeID = stored.id ?? 0
        try await store.recordEvalOutcome(id: episodeID, outcome: "adapter_wins")

        let unevaluated = try await store.unevaluatedEpisodes()
        XCTAssertTrue(unevaluated.isEmpty)
    }

    func testShadowEvalCountsReturnCorrectValues() async throws {
        let (store, _) = try await makeTempStore()
        for outcome in ["base_wins", "base_wins", "adapter_wins", "tie"] {
            let episode = ShadowEvalEpisode(
                id: nil,
                recordedAt: ISO8601DateFormatter().string(from: Date()),
                conversationJSON: "[]",
                actualResponse: "test",
                receptionScore: nil,
                evaluated: false,
                evalOutcome: nil
            )
            let stored = try await store.appendShadowEpisode(episode)
            try await store.recordEvalOutcome(id: stored.id ?? 0, outcome: outcome)
        }

        let counts = try await store.shadowEvalCounts()
        XCTAssertEqual(counts.baseWins, 2)
        XCTAssertEqual(counts.adapterWins, 1)
        XCTAssertEqual(counts.ties, 1)
    }

    // MARK: - Error Paths

    func testOperationsBeforeOpenThrowNotOpen() async throws {
        let store = ImprovementStore()
        // Should throw notOpen since we never called open().
        do {
            _ = try await store.pendingFeedbackEvents()
            XCTFail("Expected notOpen error")
        } catch let error as ImprovementStoreError {
            if case .notOpen = error {
                // Expected.
            } else {
                XCTFail("Expected .notOpen, got \(error)")
            }
        }
    }

    func testReadStateBeforeEnsureStateRowThrows() async throws {
        let (store, _) = try await makeTempStore()
        do {
            _ = try await store.readState()
            XCTFail("Expected stateNotInitialised error")
        } catch let error as ImprovementStoreError {
            if case .stateNotInitialised = error {
                // Expected.
            } else {
                XCTFail("Expected .stateNotInitialised, got \(error)")
            }
        }
    }

    func testCloseAndReopenPreservesData() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("improvement.db")

        // Open, insert data, close.
        let store1 = ImprovementStore()
        try await store1.open(at: url)
        _ = try await store1.appendFeedbackEvent(makeEvent(fingerprint: "persist-test"))
        await store1.close()

        // Reopen same database.
        let store2 = ImprovementStore()
        try await store2.open(at: url)
        let events = try await store2.pendingFeedbackEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.turnFingerprint, "persist-test")
    }

    func testEmptyDatabaseReturnsEmptyArraysAndZeroCounts() async throws {
        let (store, _) = try await makeTempStore()
        let events = try await store.pendingFeedbackEvents()
        XCTAssertTrue(events.isEmpty)
        let count = try await store.pendingFeedbackCount()
        XCTAssertEqual(count, 0)
        let gaps = try await store.unaddressedGaps()
        XCTAssertTrue(gaps.isEmpty)
        let episodes = try await store.unevaluatedEpisodes()
        XCTAssertTrue(episodes.isEmpty)
        let counts = try await store.shadowEvalCounts()
        XCTAssertEqual(counts.baseWins, 0)
        XCTAssertEqual(counts.adapterWins, 0)
        XCTAssertEqual(counts.ties, 0)
    }
}

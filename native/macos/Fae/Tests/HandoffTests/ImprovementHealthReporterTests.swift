import XCTest
@testable import Fae

final class ImprovementHealthReporterTests: XCTestCase {

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

    // MARK: - Basic Report Generation

    func testGenerateReportReturnsDefaultsForFreshStore() async throws {
        let store = try await makeTempStore()
        let report = try await ImprovementHealthReporter.generateReport(store: store)

        XCTAssertEqual(report.cycleState, "idle")
        XCTAssertEqual(report.completedCycles, 0)
        XCTAssertEqual(report.userApprovedCycles, 0)
        XCTAssertEqual(report.deferralCount, 0)
        XCTAssertNil(report.lastCycleAt)
        XCTAssertNil(report.lastCycleError)
        XCTAssertEqual(report.pendingFeedbackCount, 0)
        XCTAssertEqual(report.pendingCorrectionCount, 0)
        XCTAssertFalse(report.autoDeployEarned)
        XCTAssertNil(report.currentAdapterPath)
        XCTAssertFalse(report.directiveRollbackAvailable)
    }

    func testGenerateReportReflectsStoreState() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()

        // Update state with some values.
        var state = try await store.readState()
        state.completedCycles = 10
        state.userApprovedCycles = 6
        state.deferralCount = 2
        state.lastCycleAt = "2026-03-30T02:00:00Z"
        state.lastCycleError = "review_concern_deferred"
        state.currentAdapterPath = "/adapters/v3"
        state.previousDirective = "Old directive"
        try await store.writeState(state)

        // Add some feedback events.
        for _ in 0..<5 {
            _ = try await store.appendFeedbackEvent(FeedbackEvent(
                id: nil,
                recordedAt: ISO8601DateFormatter().string(from: Date()),
                signalType: "correction",
                turnFingerprint: UUID().uuidString,
                userInput: "test",
                assistantOutput: "test",
                sentimentScore: nil,
                consumed: false
            ))
        }
        for _ in 0..<3 {
            _ = try await store.appendFeedbackEvent(FeedbackEvent(
                id: nil,
                recordedAt: ISO8601DateFormatter().string(from: Date()),
                signalType: "re_ask",
                turnFingerprint: UUID().uuidString,
                userInput: "test",
                assistantOutput: "test",
                sentimentScore: nil,
                consumed: false
            ))
        }

        let report = try await ImprovementHealthReporter.generateReport(store: store)

        XCTAssertEqual(report.completedCycles, 10)
        XCTAssertEqual(report.userApprovedCycles, 6)
        XCTAssertEqual(report.deferralCount, 2)
        XCTAssertEqual(report.lastCycleAt, "2026-03-30T02:00:00Z")
        XCTAssertEqual(report.lastCycleError, "review_concern_deferred")
        XCTAssertEqual(report.pendingFeedbackCount, 8)
        XCTAssertEqual(report.pendingCorrectionCount, 5)
        XCTAssertTrue(report.autoDeployEarned, "6 >= 5 approved cycles → auto-deploy earned")
        XCTAssertEqual(report.currentAdapterPath, "/adapters/v3")
        XCTAssertTrue(report.directiveRollbackAvailable)
    }

    // MARK: - Shadow Eval Stats

    func testGenerateReportIncludesShadowEvalStats() async throws {
        let store = try await makeTempStore()

        _ = try await store.appendShadowEpisode(ShadowEvalEpisode(
            id: nil, recordedAt: "2026-03-30T02:00:00Z",
            conversationJSON: "[]", actualResponse: "test",
            receptionScore: nil, evaluated: true, evalOutcome: "adapter_wins"
        ))
        _ = try await store.appendShadowEpisode(ShadowEvalEpisode(
            id: nil, recordedAt: "2026-03-30T02:01:00Z",
            conversationJSON: "[]", actualResponse: "test",
            receptionScore: nil, evaluated: true, evalOutcome: "base_wins"
        ))
        _ = try await store.appendShadowEpisode(ShadowEvalEpisode(
            id: nil, recordedAt: "2026-03-30T02:02:00Z",
            conversationJSON: "[]", actualResponse: "test",
            receptionScore: nil, evaluated: true, evalOutcome: "tie"
        ))

        let report = try await ImprovementHealthReporter.generateReport(store: store)

        XCTAssertEqual(report.shadowEvalStats.adapterWins, 1)
        XCTAssertEqual(report.shadowEvalStats.baseWins, 1)
        XCTAssertEqual(report.shadowEvalStats.ties, 1)
    }

    // MARK: - Dictionary Formatting

    func testFormatAsDictionaryContainsAllKeys() async throws {
        let store = try await makeTempStore()
        let report = try await ImprovementHealthReporter.generateReport(store: store)
        let dict = ImprovementHealthReporter.formatAsDictionary(report)

        XCTAssertEqual(dict["cycle_state"], "idle")
        XCTAssertEqual(dict["completed_cycles"], "0")
        XCTAssertEqual(dict["auto_deploy_earned"], "no")
        XCTAssertEqual(dict["directive_rollback"], "none")
        XCTAssertNotNil(dict["shadow_eval"])
        XCTAssertNotNil(dict["pending_feedback"])
    }

    func testFormatAsDictionaryIncludesOptionalFields() async throws {
        let store = try await makeTempStore()
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.lastCycleAt = "2026-03-30T02:00:00Z"
        state.lastCycleError = "test_error"
        state.currentAdapterPath = "/adapters/v1"
        try await store.writeState(state)

        let report = try await ImprovementHealthReporter.generateReport(store: store)
        let dict = ImprovementHealthReporter.formatAsDictionary(report)

        XCTAssertEqual(dict["last_cycle_at"], "2026-03-30T02:00:00Z")
        XCTAssertEqual(dict["last_cycle_error"], "test_error")
        XCTAssertEqual(dict["current_adapter"], "/adapters/v1")
    }
}

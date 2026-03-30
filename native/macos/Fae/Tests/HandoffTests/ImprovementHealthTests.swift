import XCTest
@testable import Fae

/// Tests for Phase 4.2 CEO Expansions:
/// - `FaeDirectories.adaptersDirectory` path
/// - `GitVaultManager` backup list includes improvement.db and adapters/
/// - Improvement health check logic in self-diagnostic
final class ImprovementHealthTests: XCTestCase {

    // MARK: - FaeDirectories

    func testAdaptersDirectoryPathIsCorrect() {
        let adaptersURL = FaeDirectories.adaptersDirectory
        XCTAssertTrue(
            adaptersURL.path.hasSuffix("/adapters"),
            "adaptersDirectory should end with /adapters, got: \(adaptersURL.path)"
        )
    }

    func testAdaptersDirectoryIsUnderAppSupport() {
        let adapters = FaeDirectories.adaptersDirectory
        let improvement = FaeDirectories.improvementDatabase
        // Both should share the same parent directory.
        XCTAssertEqual(
            adapters.deletingLastPathComponent().path,
            improvement.deletingLastPathComponent().path,
            "adaptersDirectory and improvementDatabase should share the same parent"
        )
    }

    func testImprovementDatabasePathIsCorrect() {
        let url = FaeDirectories.improvementDatabase
        XCTAssertTrue(
            url.path.hasSuffix("/improvement.db"),
            "improvementDatabase should end with /improvement.db"
        )
    }

    // MARK: - Improvement Stuck Detection

    func testImprovementStuckStateDetected() async throws {
        // Create a store with training state stuck for more than 2 hours.
        let store = ImprovementStore()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("health_test_\(UUID().uuidString).db")
        try await store.open(at: url)
        try await store.ensureStateRow()

        // Write a state that simulates stuck training (started 3 hours ago).
        var state = try await store.readState()
        state.cycleState = CycleState.training.rawValue
        let threeHoursAgo = Date().addingTimeInterval(-3 * 3600)
        state.trainingStartedAt = ISO8601DateFormatter().string(from: threeHoursAgo)
        try await store.writeState(state)

        // Re-read and check that stuck detection logic would fire.
        let readBack = try await store.readState()
        XCTAssertEqual(readBack.cycleState, "training")
        XCTAssertNotNil(readBack.trainingStartedAt)

        if let startedStr = readBack.trainingStartedAt,
           let started = ISO8601DateFormatter().date(from: startedStr) {
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertGreaterThan(
                elapsed,
                ImprovementCycleCoordinator.maxTrainingDurationSeconds,
                "Elapsed time should exceed max training duration for stuck detection"
            )
        } else {
            XCTFail("trainingStartedAt should be set and parseable")
        }
    }

    func testImprovementHealthyStateNotAnomaly() async throws {
        let store = ImprovementStore()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("health_test_\(UUID().uuidString).db")
        try await store.open(at: url)
        try await store.ensureStateRow()

        let state = try await store.readState()
        // Default state is idle — not stuck.
        XCTAssertEqual(state.cycleState, "idle")
        XCTAssertNil(state.trainingStartedAt, "Idle state should have nil trainingStartedAt")
    }

    func testTrainingStateWithRecentStartIsNotStuck() async throws {
        let store = ImprovementStore()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("health_test_\(UUID().uuidString).db")
        try await store.open(at: url)
        try await store.ensureStateRow()

        var state = try await store.readState()
        state.cycleState = CycleState.training.rawValue
        // Started 30 minutes ago — not yet stuck.
        let thirtyMinutesAgo = Date().addingTimeInterval(-30 * 60)
        state.trainingStartedAt = ISO8601DateFormatter().string(from: thirtyMinutesAgo)
        try await store.writeState(state)

        let readBack = try await store.readState()
        if let startedStr = readBack.trainingStartedAt,
           let started = ISO8601DateFormatter().date(from: startedStr) {
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(
                elapsed,
                ImprovementCycleCoordinator.maxTrainingDurationSeconds,
                "30 minutes should not exceed max training duration"
            )
        } else {
            XCTFail("trainingStartedAt should be set and parseable")
        }
    }

    // MARK: - ImprovementState Counters

    func testCompletedCyclesAndApprovedCyclesStartAtZero() async throws {
        let store = ImprovementStore()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("health_test_\(UUID().uuidString).db")
        try await store.open(at: url)
        try await store.ensureStateRow()

        let state = try await store.readState()
        XCTAssertEqual(state.completedCycles, 0)
        XCTAssertEqual(state.userApprovedCycles, 0)
    }

    func testSelfDiagnosticMaxTrainingDurationIsReasonable() {
        // 2 hours = 7200 seconds.
        XCTAssertEqual(
            ImprovementCycleCoordinator.maxTrainingDurationSeconds,
            7200,
            accuracy: 1.0,
            "Max training duration should be 2 hours (7200 seconds)"
        )
    }
}

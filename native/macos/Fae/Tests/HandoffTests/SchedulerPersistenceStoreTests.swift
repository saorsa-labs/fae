import XCTest
@testable import Fae

final class SchedulerPersistenceStoreTests: XCTestCase {

    private func makeTempStore() throws -> SchedulerPersistenceStore {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return try SchedulerPersistenceStore(
            path: tmpDir.appendingPathComponent("scheduler.db").path
        )
    }

    func testInsertAndQueryRun() async throws {
        let store = try makeTempStore()
        let record = TaskRunRecord(
            taskID: "t1", idempotencyKey: "k1",
            state: .success, attempt: 0,
            updatedAt: Date(), lastError: nil
        )
        try await store.insertRun(record)
        let latest = try await store.latestRun(taskID: "t1")
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.idempotencyKey, "k1")
        XCTAssertEqual(latest?.state, .success)
    }

    func testIdempotencyKeyRejection() async throws {
        let store = try makeTempStore()
        let r1 = TaskRunRecord(
            taskID: "t1", idempotencyKey: "k1",
            state: .running, attempt: 0,
            updatedAt: Date(), lastError: nil
        )
        try await store.insertRun(r1)
        let seen = try await store.hasSeenKey("k1")
        XCTAssertTrue(seen)
        let notSeen = try await store.hasSeenKey("k2")
        XCTAssertFalse(notSeen)
    }

    func testDisabledTaskPersistence() async throws {
        let store = try makeTempStore()
        try await store.setTaskEnabled(id: "memory_gc", enabled: false)
        let disabled = try await store.loadDisabledTaskIDs()
        XCTAssertTrue(disabled.contains("memory_gc"))

        try await store.setTaskEnabled(id: "memory_gc", enabled: true)
        let disabled2 = try await store.loadDisabledTaskIDs()
        XCTAssertFalse(disabled2.contains("memory_gc"))
    }

    func testRunHistoryQuery() async throws {
        let store = try makeTempStore()
        for i in 0..<5 {
            let record = TaskRunRecord(
                taskID: "t1", idempotencyKey: "k\(i)",
                state: .success, attempt: 0,
                updatedAt: Date().addingTimeInterval(Double(i)),
                lastError: nil
            )
            try await store.insertRun(record)
        }
        let history = try await store.runHistory(taskID: "t1", limit: 3)
        XCTAssertEqual(history.count, 3)
    }

    func testPruneOldRuns() async throws {
        let store = try makeTempStore()
        let old = Date().addingTimeInterval(-86400 * 10)
        let recent = Date()
        try await store.insertRun(TaskRunRecord(
            taskID: "t1", idempotencyKey: "old1",
            state: .success, attempt: 0,
            updatedAt: old, lastError: nil
        ))
        try await store.insertRun(TaskRunRecord(
            taskID: "t1", idempotencyKey: "new1",
            state: .success, attempt: 0,
            updatedAt: recent, lastError: nil
        ))
        let pruned = try await store.pruneOldRuns(olderThan: Date().addingTimeInterval(-86400))
        XCTAssertEqual(pruned, 1)
        let remaining = try await store.recentRuns(taskID: "t1", limit: 10)
        XCTAssertEqual(remaining.count, 1)
    }

    func testPersistenceSurvivesReopen() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("scheduler.db").path

        // First open
        let store1 = try SchedulerPersistenceStore(path: dbPath)
        try await store1.setTaskEnabled(id: "task1", enabled: false)
        try await store1.insertRun(TaskRunRecord(
            taskID: "task1", idempotencyKey: "k1",
            state: .success, attempt: 0,
            updatedAt: Date(), lastError: nil
        ))

        // Second open — separate instance
        let store2 = try SchedulerPersistenceStore(path: dbPath)
        let disabled = try await store2.loadDisabledTaskIDs()
        XCTAssertTrue(disabled.contains("task1"))
        let latest = try await store2.latestRun(taskID: "task1")
        XCTAssertNotNil(latest)
    }

    func testUpdateRunState() async throws {
        let store = try makeTempStore()
        try await store.insertRun(TaskRunRecord(
            taskID: "t1", idempotencyKey: "k1",
            state: .running, attempt: 0,
            updatedAt: Date(), lastError: nil
        ))
        try await store.updateRunState(
            idempotencyKey: "k1", state: .failed, error: "timeout"
        )
        let latest = try await store.latestRun(taskID: "t1")
        XCTAssertEqual(latest?.state, .failed)
        XCTAssertEqual(latest?.lastError, "timeout")
    }

    func testRecentRunsOrdering() async throws {
        let store = try makeTempStore()
        for i in 0..<3 {
            try await store.insertRun(TaskRunRecord(
                taskID: "t1", idempotencyKey: "k\(i)",
                state: .success, attempt: 0,
                updatedAt: Date().addingTimeInterval(Double(i) * 10),
                lastError: nil
            ))
        }
        let runs = try await store.recentRuns(taskID: "t1", limit: 10)
        XCTAssertEqual(runs.count, 3)
        // Most recent first
        XCTAssertEqual(runs.first?.idempotencyKey, "k2")
    }
}

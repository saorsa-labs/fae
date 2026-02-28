import XCTest
@testable import Fae

final class TaskRunLedgerTests: XCTestCase {
    func testIdempotencyRejectsDuplicateKey() async {
        let ledger = TaskRunLedger()
        let a = await ledger.shouldRun(taskID: "t1", idempotencyKey: "k1")
        let b = await ledger.shouldRun(taskID: "t1", idempotencyKey: "k1")
        XCTAssertTrue(a)
        XCTAssertFalse(b)
    }

    func testMarkFailedAndLatest() async {
        let ledger = TaskRunLedger()
        await ledger.markRunning(taskID: "t2", idempotencyKey: "k2", attempt: 1)
        await ledger.markFailed(taskID: "t2", idempotencyKey: "k2", attempt: 1, error: "boom")
        let rec = await ledger.latest(taskID: "t2")
        XCTAssertEqual(rec?.state, .failed)
        XCTAssertEqual(rec?.attempt, 1)
    }

    func testPersistenceRoundtrip() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("scheduler.db").path
        let store = try SchedulerPersistenceStore(path: dbPath)

        // First ledger — mark success
        let ledger1 = TaskRunLedger(store: store)
        let shouldRun = await ledger1.shouldRun(taskID: "t1", idempotencyKey: "k1")
        XCTAssertTrue(shouldRun)
        await ledger1.markRunning(taskID: "t1", idempotencyKey: "k1", attempt: 0)
        await ledger1.markSuccess(taskID: "t1", idempotencyKey: "k1", attempt: 0)

        // Second ledger with same store — should find the record
        let ledger2 = TaskRunLedger(store: store)
        let rec = await ledger2.latest(taskID: "t1")
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.state, .success)
    }

    func testHistoryAccumulation() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = try SchedulerPersistenceStore(
            path: tmpDir.appendingPathComponent("scheduler.db").path
        )
        let ledger = TaskRunLedger(store: store)

        for i in 0..<5 {
            let key = "k\(i)"
            _ = await ledger.shouldRun(taskID: "t1", idempotencyKey: key)
            await ledger.markRunning(taskID: "t1", idempotencyKey: key, attempt: 0)
            await ledger.markSuccess(taskID: "t1", idempotencyKey: key, attempt: 0)
        }

        let history = await ledger.recentHistory(taskID: "t1", limit: 10)
        XCTAssertEqual(history.count, 5)
    }

    func testOldRecordPruning() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = try SchedulerPersistenceStore(
            path: tmpDir.appendingPathComponent("scheduler.db").path
        )

        // Insert an old record directly via store
        let old = Date().addingTimeInterval(-86400 * 10)
        try await store.insertRun(TaskRunRecord(
            taskID: "t1", idempotencyKey: "old1",
            state: .success, attempt: 0,
            updatedAt: old, lastError: nil
        ))
        try await store.insertRun(TaskRunRecord(
            taskID: "t1", idempotencyKey: "new1",
            state: .success, attempt: 0,
            updatedAt: Date(), lastError: nil
        ))

        let pruned = try await store.pruneOldRuns(olderThan: Date().addingTimeInterval(-86400))
        XCTAssertEqual(pruned, 1)
    }
}

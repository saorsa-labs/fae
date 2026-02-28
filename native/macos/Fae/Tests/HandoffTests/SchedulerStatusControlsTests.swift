import XCTest
@testable import Fae

final class SchedulerStatusControlsTests: XCTestCase {
    func testEnableDisableReflectsStatus() async {
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        await scheduler.setTaskEnabled(id: "memory_gc", enabled: false)
        let s1 = await scheduler.status(taskID: "memory_gc")
        XCTAssertEqual(s1["enabled"] as? Bool, false)

        await scheduler.setTaskEnabled(id: "memory_gc", enabled: true)
        let s2 = await scheduler.status(taskID: "memory_gc")
        XCTAssertEqual(s2["enabled"] as? Bool, true)
    }

    func testDisabledStatePersistedAcrossRestart() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("scheduler.db").path

        // First scheduler — disable a task
        let store1 = try SchedulerPersistenceStore(path: dbPath)
        let s1 = FaeScheduler(eventBus: FaeEventBus())
        await s1.configurePersistence(store: store1)
        await s1.setTaskEnabled(id: "memory_gc", enabled: false)

        // Second scheduler — should load disabled state
        let store2 = try SchedulerPersistenceStore(path: dbPath)
        let s2 = FaeScheduler(eventBus: FaeEventBus())
        await s2.configurePersistence(store: store2)

        let enabled = await s2.isTaskEnabled(id: "memory_gc")
        XCTAssertFalse(enabled, "Task should still be disabled after restart")
    }

    func testRunHistoryPersistedAcrossRestart() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("scheduler.db").path

        // First scheduler — run a task
        let store1 = try SchedulerPersistenceStore(path: dbPath)
        let s1 = FaeScheduler(eventBus: FaeEventBus())
        await s1.configurePersistence(store: store1)
        await s1.executeReliably(taskID: "memory_gc") { }

        // Second scheduler — should find run history
        let store2 = try SchedulerPersistenceStore(path: dbPath)
        let s2 = FaeScheduler(eventBus: FaeEventBus())
        await s2.configurePersistence(store: store2)

        let rec = await s2.latestRunRecord(taskID: "memory_gc")
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.state, .success)
    }

    func testStatusAllIncludesPersistedDisabledTasks() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = try SchedulerPersistenceStore(
            path: tmpDir.appendingPathComponent("scheduler.db").path
        )
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        await scheduler.configurePersistence(store: store)
        await scheduler.setTaskEnabled(id: "morning_briefing", enabled: false)

        let all = await scheduler.statusAll()
        let morningTask = all.first { ($0["id"] as? String) == "morning_briefing" }
        XCTAssertNotNil(morningTask)
        XCTAssertEqual(morningTask?["enabled"] as? Bool, false)
    }
}

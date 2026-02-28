import XCTest
@testable import Fae

final class SchedulerUnifiedSourceOfTruthTests: XCTestCase {
    func testSchedulerAndToolsAgreeOnEnabledState() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = try SchedulerPersistenceStore(
            path: tmpDir.appendingPathComponent("scheduler.db").path
        )
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        await scheduler.configurePersistence(store: store)

        // Disable via scheduler directly (simulates FaeCore routing)
        await scheduler.setTaskEnabled(id: "memory_gc", enabled: false)
        let fromScheduler = await scheduler.isTaskEnabled(id: "memory_gc")
        XCTAssertFalse(fromScheduler)

        // Verify persistence store agrees
        let disabled = try await store.loadDisabledTaskIDs()
        XCTAssertTrue(disabled.contains("memory_gc"))

        // Re-enable
        await scheduler.setTaskEnabled(id: "memory_gc", enabled: true)
        let reenabled = await scheduler.isTaskEnabled(id: "memory_gc")
        XCTAssertTrue(reenabled)

        let disabled2 = try await store.loadDisabledTaskIDs()
        XCTAssertFalse(disabled2.contains("memory_gc"))
    }
}

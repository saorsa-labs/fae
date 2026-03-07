import XCTest
@testable import Fae

final class EndToEndSchedulerPersistenceStressTests: XCTestCase {
    private actor DispatchCapture {
        private(set) var taskIDs: [String] = []

        func record(taskID: String) {
            taskIDs.append(taskID)
        }

        func snapshot() -> [String] {
            taskIDs
        }
    }

    private var tempDirectory: URL!
    private var schedulerStoreURL: URL!
    private var originalSchedulerOverride: URL?

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-scheduler-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        schedulerStoreURL = tempDirectory.appendingPathComponent("scheduler.db")
        originalSchedulerOverride = schedulerFileURLOverride
        schedulerFileURLOverride = tempDirectory.appendingPathComponent("scheduler.json")
    }

    override func tearDownWithError() throws {
        schedulerFileURLOverride = originalSchedulerOverride
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testRepeatedSchedulerReloadsPreserveUserTaskRunHistory() async throws {
        let task = SchedulerTask(
            id: "user_persistence_replay",
            name: "Persistence replay",
            kind: "user",
            enabled: true,
            scheduleType: "interval",
            scheduleParams: ["hours": "6"],
            action: "Create a concise digest.",
            nextRun: nil,
            allowedTools: ["notes"]
        )
        try writeSchedulerTasks([task])

        let capture = DispatchCapture()

        for iteration in 1...3 {
            let store = try SchedulerPersistenceStore(path: schedulerStoreURL.path)
            let scheduler = FaeScheduler(eventBus: FaeEventBus())
            await scheduler.configurePersistence(store: store)
            await scheduler.setProactiveQueryHandler { _, _, taskID, _, _ in
                await capture.record(taskID: taskID)
            }

            await scheduler.triggerTask(id: task.id)

            let history = await scheduler.history(taskID: task.id, limit: 10)
            XCTAssertEqual(history.count, iteration)
            let capturedTaskIDs = await capture.snapshot()
            XCTAssertEqual(capturedTaskIDs.count, iteration)

            if iteration < 3 {
                try await Task.sleep(nanoseconds: 1_100_000_000)
            }
        }

        let reloadedStore = try SchedulerPersistenceStore(path: schedulerStoreURL.path)
        let reloadedScheduler = FaeScheduler(eventBus: FaeEventBus())
        await reloadedScheduler.configurePersistence(store: reloadedStore)

        let persistedHistory = await reloadedScheduler.history(taskID: task.id, limit: 10)
        XCTAssertEqual(persistedHistory.count, 3)
        XCTAssertEqual(readSchedulerTasks().first?.id, task.id)
        XCTAssertNotNil(readSchedulerTasks().first?.nextRun)
    }

    func testDisabledStateSurvivesReloadAndBlocksReplayUntilReenabled() async throws {
        let task = SchedulerTask(
            id: "user_reload_gate",
            name: "Reload gate",
            kind: "user",
            enabled: true,
            scheduleType: "interval",
            scheduleParams: ["hours": "2"],
            action: "Review today’s notes.",
            nextRun: nil,
            allowedTools: ["notes"]
        )
        try writeSchedulerTasks([task])

        let initialStore = try SchedulerPersistenceStore(path: schedulerStoreURL.path)
        let initialScheduler = FaeScheduler(eventBus: FaeEventBus())
        await initialScheduler.configurePersistence(store: initialStore)
        await initialScheduler.setTaskEnabled(id: task.id, enabled: false)

        let disabledStore = try SchedulerPersistenceStore(path: schedulerStoreURL.path)
        let disabledScheduler = FaeScheduler(eventBus: FaeEventBus())
        await disabledScheduler.configurePersistence(store: disabledStore)

        let blockedDispatch = expectation(description: "disabled task should stay blocked after reload")
        blockedDispatch.isInverted = true
        await disabledScheduler.setProactiveQueryHandler { _, _, _, _, _ in
            blockedDispatch.fulfill()
        }

        let disabledState = await disabledScheduler.isTaskEnabled(id: task.id)
        XCTAssertFalse(disabledState)
        await disabledScheduler.triggerTask(id: task.id)
        await fulfillment(of: [blockedDispatch], timeout: 0.2)
        let blockedHistory = await disabledScheduler.history(taskID: task.id)
        XCTAssertTrue(blockedHistory.isEmpty)

        await disabledScheduler.setTaskEnabled(id: task.id, enabled: true)

        let enabledStore = try SchedulerPersistenceStore(path: schedulerStoreURL.path)
        let enabledScheduler = FaeScheduler(eventBus: FaeEventBus())
        await enabledScheduler.configurePersistence(store: enabledStore)

        let capture = DispatchCapture()
        let dispatched = expectation(description: "reenabled task dispatches after reload")
        await enabledScheduler.setProactiveQueryHandler { _, _, taskID, _, _ in
            await capture.record(taskID: taskID)
            dispatched.fulfill()
        }

        let enabledState = await enabledScheduler.isTaskEnabled(id: task.id)
        XCTAssertTrue(enabledState)
        await enabledScheduler.triggerTask(id: task.id)
        await fulfillment(of: [dispatched], timeout: 1.0)
        let capturedTaskIDs = await capture.snapshot()
        XCTAssertEqual(capturedTaskIDs, [task.id])
    }
}

import XCTest
@testable import Fae

final class EndToEndSchedulerAutonomyTests: XCTestCase {
    private actor DispatchCapture {
        private(set) var prompts: [String] = []
        private(set) var taskIDs: [String] = []
        private(set) var allowedToolsSnapshots: [Set<String>] = []
        private(set) var consentSnapshots: [Bool] = []

        func record(prompt: String, taskID: String, allowedTools: Set<String>, consentGranted: Bool) {
            prompts.append(prompt)
            taskIDs.append(taskID)
            allowedToolsSnapshots.append(allowedTools)
            consentSnapshots.append(consentGranted)
        }

        func snapshot() -> (prompts: [String], taskIDs: [String], allowedToolsSnapshots: [Set<String>], consentSnapshots: [Bool]) {
            (prompts, taskIDs, allowedToolsSnapshots, consentSnapshots)
        }
    }

    private var tempDirectory: URL!
    private var originalSchedulerOverride: URL?

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-e2e-scheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        originalSchedulerOverride = schedulerFileURLOverride
        schedulerFileURLOverride = tempDirectory.appendingPathComponent("scheduler.json")
    }

    override func tearDownWithError() throws {
        schedulerFileURLOverride = originalSchedulerOverride
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testUserTaskWithoutExplicitAllowedToolsFallsBackToDefaultAutonomousSet() async throws {
        let task = SchedulerTask(
            id: "user_default_tools",
            name: "Default tools",
            kind: "user",
            enabled: true,
            scheduleType: "interval",
            scheduleParams: ["hours": "6"],
            action: "Prepare a quiet digest.",
            nextRun: nil,
            allowedTools: nil
        )
        try writeSchedulerTasks([task])

        let capture = DispatchCapture()
        let dispatched = expectation(description: "default allowed tools dispatch")
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        await scheduler.setProactiveQueryHandler { prompt, _, taskID, allowedTools, consentGranted in
            await capture.record(prompt: prompt, taskID: taskID, allowedTools: allowedTools, consentGranted: consentGranted)
            dispatched.fulfill()
        }

        await scheduler.triggerTask(id: "user_default_tools")
        await fulfillment(of: [dispatched], timeout: 1.0)

        let snapshot = await capture.snapshot()
        XCTAssertEqual(snapshot.taskIDs, ["user_default_tools"])
        XCTAssertEqual(snapshot.allowedToolsSnapshots.first, defaultAutonomousSchedulerTools)
        XCTAssertEqual(snapshot.consentSnapshots, [true])
        XCTAssertTrue(snapshot.prompts.first?.contains("USER SCHEDULED TASK") == true)
    }

    func testDisabledUserTaskDoesNotDispatchProactiveHandler() async throws {
        let task = SchedulerTask(
            id: "user_disabled",
            name: "Disabled task",
            kind: "user",
            enabled: false,
            scheduleType: "interval",
            scheduleParams: ["hours": "6"],
            action: "This should never run.",
            nextRun: nil,
            allowedTools: ["notes"]
        )
        try writeSchedulerTasks([task])

        let neverDispatches = expectation(description: "disabled task should not dispatch")
        neverDispatches.isInverted = true

        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        await scheduler.setProactiveQueryHandler { _, _, _, _, _ in
            neverDispatches.fulfill()
        }

        await scheduler.triggerTask(id: "user_disabled")
        await fulfillment(of: [neverDispatches], timeout: 0.2)

        let history = await scheduler.history(taskID: "user_disabled")
        XCTAssertTrue(history.isEmpty)
    }
}

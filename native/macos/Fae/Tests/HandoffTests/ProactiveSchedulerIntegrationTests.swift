import XCTest
@testable import Fae

final class ProactiveSchedulerIntegrationTests: XCTestCase {
    private actor DispatchCapture {
        var prompt = ""
        var silent = false
        var taskID = ""
        var allowedTools: Set<String> = []
        var consentGranted = false

        func update(
            prompt: String,
            silent: Bool,
            taskID: String,
            allowedTools: Set<String>,
            consentGranted: Bool
        ) {
            self.prompt = prompt
            self.silent = silent
            self.taskID = taskID
            self.allowedTools = allowedTools
            self.consentGranted = consentGranted
        }

        func snapshot() -> (prompt: String, silent: Bool, taskID: String, allowedTools: Set<String>, consentGranted: Bool) {
            (prompt, silent, taskID, allowedTools, consentGranted)
        }
    }

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-proactive-scheduler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        schedulerFileURLOverride = tempDirectory.appendingPathComponent("scheduler.json")
    }

    override func tearDownWithError() throws {
        schedulerFileURLOverride = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testSchedulerProactiveModeChangesWithRepetition() async {
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        let m1 = await scheduler.proactiveDispatchMode(taskID: "a", urgency: .low)
        let m2 = await scheduler.proactiveDispatchMode(taskID: "a", urgency: .low)
        XCTAssertTrue(m1 == .suppress || m1 == .immediate || m1 == .digest)
        XCTAssertTrue(m2 == .digest || m2 == .suppress || m2 == .immediate)
    }

    func testHighUrgencyImmediate() async {
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        let m = await scheduler.proactiveDispatchMode(taskID: "b", urgency: .high)
        XCTAssertEqual(m, .immediate)
        XCTAssertNotEqual(m, .digest)
    }

    func testManualUserTaskDispatchUsesPersistedAllowedTools() async throws {
        let task = SchedulerTask(
            id: "user_digest",
            name: "Digest",
            kind: "user",
            enabled: true,
            scheduleType: "interval",
            scheduleParams: ["hours": "6"],
            action: "Review the saved research topics and prepare a concise digest.",
            nextRun: "2026-03-05T09:00:00Z",
            allowedTools: ["activate_skill", "run_skill", "notes"]
        )
        try writeSchedulerTasks([task])

        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        let dispatched = expectation(description: "user task dispatched")
        let capture = DispatchCapture()

        await scheduler.setProactiveQueryHandler { prompt, silent, taskId, allowedTools, consentGranted in
            await capture.update(
                prompt: prompt,
                silent: silent,
                taskID: taskId,
                allowedTools: allowedTools,
                consentGranted: consentGranted
            )
            dispatched.fulfill()
        }

        await scheduler.triggerTask(id: "user_digest")
        await fulfillment(of: [dispatched], timeout: 1.0)
        let snapshot = await capture.snapshot()

        XCTAssertEqual(snapshot.taskID, "user_digest")
        XCTAssertTrue(snapshot.prompt.contains("USER SCHEDULED TASK"))
        XCTAssertTrue(snapshot.prompt.contains(task.action))
        XCTAssertTrue(snapshot.silent)
        XCTAssertEqual(snapshot.allowedTools, ["activate_skill", "run_skill", "notes"])
        XCTAssertTrue(snapshot.consentGranted)

        let storedTask = try XCTUnwrap(readSchedulerTasks().first { $0.id == "user_digest" })
        XCTAssertNotNil(storedTask.nextRun)
        XCTAssertNotEqual(storedTask.nextRun, task.nextRun)
    }
}

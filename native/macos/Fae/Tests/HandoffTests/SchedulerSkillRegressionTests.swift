import XCTest
@testable import Fae

final class SchedulerSkillRegressionTests: XCTestCase {
    private var tempDirectory: URL!
    private var originalSchedulerOverride: URL?

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-scheduler-skill-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testSchedulerCreatePersistsNormalizedAllowedToolsAndNextRun() async throws {
        let result = try await SchedulerCreateTool().execute(input: [
            "name": "Daily research",
            "schedule_type": "daily",
            "schedule_params": ["hour": "8", "minute": "30"],
            "action": "Research my saved topics",
            "allowed_tools": ["run_skill", "mail", "invalid_tool", "run_skill"],
        ])

        XCTAssertFalse(result.isError)
        let created = try XCTUnwrap(readSchedulerTasks().first { $0.kind == "user" })
        XCTAssertEqual(created.name, "Daily research")
        XCTAssertEqual(created.allowedTools, ["mail", "run_skill"])
        XCTAssertNotNil(created.nextRun)
    }

    func testSchedulerUpdatePostsNotificationAndPersistsChanges() async throws {
        let original = SchedulerTask(
            id: "user_task",
            name: "Follow up",
            kind: "user",
            enabled: true,
            scheduleType: "interval",
            scheduleParams: ["hours": "6"],
            action: "Follow up with notes",
            nextRun: nil,
            allowedTools: ["web_search"]
        )
        try writeSchedulerTasks([original])

        let expectation = self.expectation(forNotification: .faeSchedulerUpdate, object: nil) { notification in
            notification.userInfo?["id"] as? String == "user_task"
                && notification.userInfo?["enabled"] as? Bool == false
        }

        let result = try await SchedulerUpdateTool().execute(input: [
            "id": "user_task",
            "enabled": false,
            "schedule_type": "daily",
            "schedule_params": ["hour": "9", "minute": "15"],
            "allowed_tools": ["fetch_url", "bad"],
        ])

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertFalse(result.isError)

        let updated = try XCTUnwrap(readSchedulerTasks().first { $0.id == "user_task" })
        XCTAssertFalse(updated.enabled)
        XCTAssertEqual(updated.scheduleType, "daily")
        XCTAssertEqual(updated.scheduleParams, ["hour": "9", "minute": "15"])
        XCTAssertEqual(updated.allowedTools, ["fetch_url"])
        XCTAssertNotNil(updated.nextRun)
    }

    func testSchedulerDeleteRejectsBuiltinAndDeletesUserTasks() async throws {
        let builtinResult = try await SchedulerDeleteTool().execute(input: ["id": "memory_gc"])
        XCTAssertTrue(builtinResult.isError)
        XCTAssertTrue(builtinResult.output.contains("Cannot delete builtin task"))

        let userTask = SchedulerTask(
            id: "user_delete_me",
            name: "Delete me",
            kind: "user",
            enabled: true,
            scheduleType: "interval",
            scheduleParams: ["hours": "1"],
            action: "Do thing",
            nextRun: nil,
            allowedTools: ["scheduler_list"]
        )
        try writeSchedulerTasks(defaultBuiltinTasksForTesting() + [userTask])

        let deleted = try await SchedulerDeleteTool().execute(input: ["id": "user_delete_me"])
        XCTAssertFalse(deleted.isError)
        XCTAssertNil(readSchedulerTasks().first { $0.id == "user_delete_me" })
    }

    func testSchedulerTriggerPostsNotificationForExistingTask() async throws {
        let task = SchedulerTask(
            id: "user_trigger",
            name: "Trigger me",
            kind: "user",
            enabled: true,
            scheduleType: "interval",
            scheduleParams: ["hours": "1"],
            action: "Do thing",
            nextRun: nil,
            allowedTools: nil
        )
        try writeSchedulerTasks([task])

        let expectation = self.expectation(forNotification: .faeSchedulerTrigger, object: nil) { notification in
            notification.userInfo?["id"] as? String == "user_trigger"
        }

        let result = try await SchedulerTriggerTool().execute(input: ["id": "user_trigger"])

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Trigger me"))
    }

    func testSkillManagerCreateUpdateActivateAndDeleteRoundTrip() async throws {
        let manager = SkillManager()
        let skillName = "regression_skill_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let skillDirectory = SkillManager.skillsDirectory.appendingPathComponent(skillName)
        defer { try? FileManager.default.removeItem(at: skillDirectory) }

        let created = try await manager.createSkill(
            name: skillName,
            description: "A regression test skill for focused planning.",
            body: "When asked, provide the latest project status and next two actions."
        )
        XCTAssertEqual(created.name, skillName)
        XCTAssertEqual(created.tier, .personal)

        let initialBody = await manager.activate(skillName: skillName)
        XCTAssertTrue(initialBody?.contains("latest project status") == true)

        let updated = try await manager.updateSkill(
            name: skillName,
            description: "An updated regression test skill for focused planning.",
            body: "When asked, provide the latest project status, the blocker, and the next two actions."
        )
        XCTAssertEqual(updated.description, "An updated regression test skill for focused planning.")

        let refreshedBody = await manager.activate(skillName: skillName)
        XCTAssertTrue(refreshedBody?.contains("the blocker") == true)
        let activatedNames = await manager.activatedSkillNames()
        XCTAssertTrue(activatedNames.contains(skillName))

        try await manager.deleteSkill(name: skillName)
        let discoveredAfterDelete = await manager.discoverSkills()
        XCTAssertFalse(discoveredAfterDelete.contains { $0.name == skillName })
        let activatedAfterDelete = await manager.activate(skillName: skillName)
        XCTAssertNil(activatedAfterDelete)
    }

    private func defaultBuiltinTasksForTesting() -> [SchedulerTask] {
        readSchedulerTasks().filter { $0.kind == "builtin" }
    }
}

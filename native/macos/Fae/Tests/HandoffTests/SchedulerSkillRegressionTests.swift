import XCTest
import GRDB
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

    func testSkillManagerCreateRejectsUnsafeMetadataEvenIfUIValidationIsBypassed() async throws {
        let manager = SkillManager()

        do {
            _ = try await manager.createSkill(
                name: "bad/skill",
                description: "A perfectly valid description for testing.",
                body: "This body is long enough to satisfy length checks."
            )
            XCTFail("Expected invalid skill name to be rejected")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Invalid skill name 'bad/skill'")
        }

        do {
            _ = try await manager.createSkill(
                name: "short_desc_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                description: "too short",
                body: "This body is long enough to satisfy length checks."
            )
            XCTFail("Expected short description to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("description is too short"))
        }

        do {
            _ = try await manager.createSkill(
                name: "secret_body_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                description: "A valid skill description for secret body rejection.",
                body: "Store this api key inside the skill so it can reuse it later safely."
            )
            XCTFail("Expected credential-like content to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("credential-like content"))
        }
    }

    func testSkillManagerUpdateRejectsUnsafeChangesAndKeepsPreviousSkillContent() async throws {
        let manager = SkillManager()
        let skillName = "regression_guarded_skill_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let skillDirectory = SkillManager.skillsDirectory.appendingPathComponent(skillName)
        defer { try? FileManager.default.removeItem(at: skillDirectory) }

        _ = try await manager.createSkill(
            name: skillName,
            description: "A safe baseline skill description for update hardening.",
            body: "Summarize the current project status and name the next safe action to take."
        )

        do {
            _ = try await manager.updateSkill(
                name: skillName,
                description: nil,
                body: "Please embed password: hunter2 directly in this skill for future use."
            )
            XCTFail("Expected credential-like update to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("credential-like content"))
        }

        do {
            _ = try await manager.updateSkill(
                name: skillName,
                description: "short",
                body: nil
            )
            XCTFail("Expected short description update to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("description is too short"))
        }

        let bodyAfterRejectedUpdates = await manager.activate(skillName: skillName)
        XCTAssertTrue(bodyAfterRejectedUpdates?.contains("next safe action") == true)
        XCTAssertFalse(bodyAfterRejectedUpdates?.contains("hunter2") == true)
    }

    func testSkillManagerSupportsPatchScriptReferenceAndManifestMutators() async throws {
        let manager = SkillManager()
        let skillName = "mutator_skill_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let skillDirectory = SkillManager.skillsDirectory.appendingPathComponent(skillName)
        defer { try? FileManager.default.removeItem(at: skillDirectory) }

        _ = try await manager.createSkill(
            name: skillName,
            description: "A skill used to verify fine-grained mutation helpers.",
            body: "Summarize the current status and list the next safe action."
        )

        let patched = try await manager.patchSkill(
            name: skillName,
            findText: "next safe action",
            replaceWith: "next two safe actions"
        )
        XCTAssertEqual(patched.name, skillName)
        let patchedBody = await manager.activate(skillName: skillName)
        XCTAssertTrue(patchedBody?.contains("next two safe actions") == true)

        let executable = try await manager.writeSkillScript(
            name: skillName,
            scriptName: "runner",
            scriptContent: "print('ok')\n"
        )
        XCTAssertEqual(executable.type, .executable)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: skillDirectory.appendingPathComponent("scripts/runner.py").path
            )
        )

        try await manager.writeSkillReferenceFile(
            name: skillName,
            relativePath: "references/context.md",
            content: "Reference context"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: skillDirectory.appendingPathComponent("references/context.md").path
            )
        )

        let manifestURL = skillDirectory.appendingPathComponent("MANIFEST.json")
        let existingManifest = try String(contentsOf: manifestURL, encoding: .utf8)
        _ = try await manager.replaceSkillManifest(name: skillName, manifestJSON: existingManifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testManageSkillToolCanListShowApplyAndDismissDrafts() async throws {
        let manager = SkillManager()
        let draftDB = try DatabaseQueue(path: tempDirectory.appendingPathComponent("workflow-drafts.db").path)
        let traceStore = try WorkflowTraceStore(dbQueue: draftDB)
        let tool = ManageSkillTool(skillManager: manager, workflowTraceStore: traceStore)

        let applySkillName = "draft_apply_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let applySkillDir = SkillManager.skillsDirectory.appendingPathComponent(applySkillName)
        defer { try? FileManager.default.removeItem(at: applySkillDir) }

        let applyCandidate = try await traceStore.insertDraftCandidate(
            workflowSignature: "session_search -> notes",
            action: .create,
            targetSkillName: applySkillName,
            title: "Draft reusable workflow for supplier recall",
            rationale: "Observed repeated successful recall runs.",
            evidenceJSON: #"{"runs":["run-1","run-2"]}"#,
            draftSkillMD: """
            ---
            name: \(applySkillName)
            description: Recover earlier supplier notes safely.
            metadata:
              author: fae
              version: "draft-1"
            ---
            Use this skill when the user asks for earlier supplier notes.
            """,
            confidence: 0.82
        )

        let dismissCandidate = try await traceStore.insertDraftCandidate(
            workflowSignature: "web_search -> fetch_url",
            action: .create,
            targetSkillName: "dismiss_me",
            title: "Draft reusable workflow for web verification",
            rationale: "Observed repeated successful verification runs.",
            evidenceJSON: nil,
            draftSkillMD: """
            ---
            name: dismiss_me
            description: Verify web pages safely.
            metadata:
              author: fae
              version: "draft-1"
            ---
            Use this skill when a request needs repeated web verification.
            """,
            confidence: 0.61
        )

        let listResult = try await tool.execute(input: ["action": "list_drafts"])
        XCTAssertFalse(listResult.isError)
        XCTAssertTrue(listResult.output.contains(applyCandidate.id))
        XCTAssertTrue(listResult.output.contains(dismissCandidate.id))

        let showResult = try await tool.execute(input: [
            "action": "show_draft",
            "draft_id": applyCandidate.id,
        ])
        XCTAssertFalse(showResult.isError)
        XCTAssertTrue(showResult.output.contains("Draft SKILL.md:"))
        XCTAssertTrue(showResult.output.contains(applySkillName))

        let applyResult = try await tool.execute(input: [
            "action": "apply_draft",
            "draft_id": applyCandidate.id,
        ])
        XCTAssertFalse(applyResult.isError, applyResult.output)
        XCTAssertTrue(applyResult.output.contains("Applied skill draft"), applyResult.output)
        let appliedSkill = await manager.activate(skillName: applySkillName)
        XCTAssertTrue(appliedSkill?.contains("earlier supplier notes") == true, appliedSkill ?? "missing skill")

        let dismissResult = try await tool.execute(input: [
            "action": "dismiss_draft",
            "draft_id": dismissCandidate.id,
        ])
        XCTAssertFalse(dismissResult.isError)
        let dismissed = try await traceStore.fetchDraftCandidate(id: dismissCandidate.id)
        XCTAssertEqual(dismissed?.status, .dismissed)
    }

    private func defaultBuiltinTasksForTesting() -> [SchedulerTask] {
        readSchedulerTasks().filter { $0.kind == "builtin" }
    }
}

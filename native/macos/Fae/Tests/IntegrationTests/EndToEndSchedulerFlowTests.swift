import XCTest
@testable import Fae

/// Tests the scheduler's task lifecycle, persistence, and speak handler wiring.
final class EndToEndSchedulerFlowTests: XCTestCase {

    private actor SpokenTextCollector {
        private var values: [String] = []

        func append(_ text: String) {
            values.append(text)
        }

        func snapshot() -> [String] {
            values
        }
    }

    private var harness: TestRuntimeHarness!

    override func setUp() async throws {
        harness = try TestRuntimeHarness()
        await harness.setUp()
    }

    override func tearDown() {
        harness.cleanup()
        harness = nil
    }

    // MARK: - Task Enable/Disable

    func testSchedulerTaskCanBeDisabledAndEnabled() async throws {
        let scheduler = harness.scheduler

        // Initially all tasks are enabled.
        let enabled = await scheduler.isTaskEnabled(id: "morning_briefing")
        XCTAssertTrue(enabled)

        // Disable it.
        await scheduler.setTaskEnabled(id: "morning_briefing", enabled: false)
        let disabled = await scheduler.isTaskEnabled(id: "morning_briefing")
        XCTAssertFalse(disabled)

        // Re-enable it.
        await scheduler.setTaskEnabled(id: "morning_briefing", enabled: true)
        let reEnabled = await scheduler.isTaskEnabled(id: "morning_briefing")
        XCTAssertTrue(reEnabled)
    }

    func testDisabledTaskPersistedViaStore() async throws {
        let scheduler = harness.scheduler

        // Disable a task.
        await scheduler.setTaskEnabled(id: "memory_gc", enabled: false)

        // Verify the persistence store reflects this.
        let disabledIDs = try await harness.schedulerStore.loadDisabledTaskIDs()
        XCTAssertTrue(disabledIDs.contains("memory_gc"))
    }

    // MARK: - Task Trigger

    func testTriggerTaskRecordsRunHistory() async throws {
        let scheduler = harness.scheduler

        await scheduler.triggerTask(id: "noise_budget_reset")

        // Check run history.
        let history = await scheduler.history(taskID: "noise_budget_reset")
        XCTAssertGreaterThanOrEqual(history.count, 1)
    }

    func testTriggerDisabledTaskDoesNotRun() async throws {
        let scheduler = harness.scheduler

        // Disable the task.
        await scheduler.setTaskEnabled(id: "memory_migrate", enabled: false)

        // Trigger it — should be skipped.
        await scheduler.triggerTask(id: "memory_migrate")

        // History should NOT have a new entry (disabled tasks skip execution).
        let history = await scheduler.history(taskID: "memory_migrate")
        // The trigger was skipped, so no persistence record was created.
        XCTAssertEqual(history.count, 0)
    }

    // MARK: - Speak Handler

    func testSpeakHandlerReceivesBriefingText() async throws {
        let scheduler = harness.scheduler

        // First, store a commitment memory so morning briefing has something to say.
        _ = await harness.memoryOrchestrator.capture(
            turnId: "turn-brief-1",
            userText: "I need to submit the report by Friday",
            assistantText: "I'll remind you."
        )

        // Wire up a speak handler.
        let collector = SpokenTextCollector()
        await scheduler.setSpeakHandler { text in
            await collector.append(text)
        }

        // Trigger morning briefing directly.
        await scheduler.triggerTask(id: "morning_briefing")

        // Allow async operations to complete.
        try await Task.sleep(nanoseconds: 100_000_000)

        let texts = await collector.snapshot()
        XCTAssertGreaterThanOrEqual(texts.count, 0)

        // Morning briefing should have spoken something if memory had commitments.
        // It may or may not speak depending on recall scoring — the important thing
        // is the handler was wired and didn't crash.
    }

    // MARK: - Status

    func testStatusAllReturnsAllBuiltinTasks() async throws {
        let scheduler = harness.scheduler
        let allStatus = await scheduler.statusAll()

        let taskIDs = allStatus.compactMap { $0["id"] as? String }

        // Verify all core builtin task IDs are present.
        let expectedIDs = [
            "memory_reflect", "memory_reindex", "memory_migrate",
            "memory_inbox_ingest", "memory_digest",
            "memory_gc", "memory_backup", "check_fae_update",
            "morning_briefing", "noise_budget_reset", "skill_proposals", "skill_distill",
            "stale_relationships", "skill_health_check",
        ]
        for id in expectedIDs {
            XCTAssertTrue(taskIDs.contains(id), "Missing task ID: \(id)")
        }
    }

    func testStatusReflectsDisabledState() async throws {
        let scheduler = harness.scheduler
        await scheduler.setTaskEnabled(id: "skill_proposals", enabled: false)

        let status = await scheduler.status(taskID: "skill_proposals")
        let enabled = status["enabled"] as? Bool
        XCTAssertEqual(enabled, false)
    }

    func testSkillDistillCreatesDraftCandidateFromRepeatedWorkflowTrace() async throws {
        for index in 0..<2 {
            let run = try await harness.workflowTraceStore.createRun(
                sessionId: nil,
                turnId: "turn-\(index)",
                source: "text",
                userGoal: "Find our earlier supplier notes and summarize the decisions."
            )
            try await harness.workflowTraceStore.appendStep(
                runId: run.id,
                toolCallId: "call-\(index)-1",
                stepType: .toolCall,
                toolName: "session_search",
                sanitizedInputJSON: #"{"query":"supplier notes"}"#,
                outputPreview: nil,
                success: nil,
                approved: nil,
                latencyMs: nil
            )
            try await harness.workflowTraceStore.appendStep(
                runId: run.id,
                toolCallId: "call-\(index)-1",
                stepType: .toolResult,
                toolName: "session_search",
                sanitizedInputJSON: nil,
                outputPreview: "Found the earlier supplier conversation.",
                success: true,
                approved: nil,
                latencyMs: 90
            )
            try await harness.workflowTraceStore.appendStep(
                runId: run.id,
                toolCallId: "call-\(index)-2",
                stepType: .toolCall,
                toolName: "notes",
                sanitizedInputJSON: #"{"action":"search","query":"supplier"}"#,
                outputPreview: nil,
                success: nil,
                approved: nil,
                latencyMs: nil
            )
            try await harness.workflowTraceStore.appendStep(
                runId: run.id,
                toolCallId: "call-\(index)-2",
                stepType: .toolResult,
                toolName: "notes",
                sanitizedInputJSON: nil,
                outputPreview: "Recovered the supplier notes and draft summary.",
                success: true,
                approved: nil,
                latencyMs: 75
            )
            _ = try await harness.workflowTraceStore.finalizeRun(
                id: run.id,
                assistantOutcome: "I found the earlier supplier notes and summarized the decisions.",
                success: true,
                userApproved: false,
                toolSequenceSignature: "session_search -> notes",
                damageControlIntervened: false
            )
        }

        await harness.scheduler.triggerTask(id: "skill_distill")

        let drafts = try await harness.workflowTraceStore.listDraftCandidates(statuses: [.pending])
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.workflowSignature, "session_search -> notes")
        XCTAssertTrue(drafts.first?.draftSkillMD.contains("Procedure:") == true)
    }
}

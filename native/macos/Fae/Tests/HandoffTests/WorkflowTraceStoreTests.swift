import XCTest
import GRDB
@testable import Fae

final class WorkflowTraceStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var dbQueue: DatabaseQueue!
    private var store: WorkflowTraceStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-workflow-trace-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: tempDirectory.appendingPathComponent("fae.db").path)
        _ = try SessionStore(dbQueue: dbQueue)
        store = try WorkflowTraceStore(dbQueue: dbQueue)
    }

    override func tearDownWithError() throws {
        store = nil
        dbQueue = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testWorkflowRunRoundTripAppearsInRecentSuccessfulRuns() async throws {
        let run = try await store.createRun(
            sessionId: nil,
            turnId: "turn-1",
            source: "text",
            userGoal: "Find our earlier supplier conversation and summarize the notes."
        )

        try await store.appendStep(
            runId: run.id,
            toolCallId: "call-1",
            stepType: .toolCall,
            toolName: "session_search",
            sanitizedInputJSON: #"{"query":"supplier conversation"}"#,
            outputPreview: nil,
            success: nil,
            approved: nil,
            latencyMs: nil
        )
        try await store.appendStep(
            runId: run.id,
            toolCallId: "call-1",
            stepType: .toolResult,
            toolName: "session_search",
            sanitizedInputJSON: nil,
            outputPreview: "Found two earlier transcript matches.",
            success: true,
            approved: nil,
            latencyMs: 83
        )
        let finalized = try await store.finalizeRun(
            id: run.id,
            assistantOutcome: "I found the earlier supplier conversation and summarized the decisions.",
            success: true,
            userApproved: false,
            toolSequenceSignature: "session_search",
            damageControlIntervened: false
        )

        XCTAssertEqual(finalized?.status, .completed)
        XCTAssertEqual(finalized?.stepCount, 2)
        XCTAssertEqual(finalized?.toolSequenceSignature, "session_search")

        let recent = try await store.recentSuccessfulRuns(
            since: Date().addingTimeInterval(-300),
            minimumStepCount: 2
        )
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.id, run.id)

        let steps = try await store.steps(runId: run.id)
        XCTAssertEqual(steps.map(\.stepType), [.toolCall, .toolResult])
        XCTAssertEqual(steps.last?.success, true)
    }

    func testDraftCandidateLifecycleRoundTrip() async throws {
        let candidate = try await store.insertDraftCandidate(
            workflowSignature: "session_search -> notes",
            action: .create,
            targetSkillName: "supplier-notes",
            title: "Draft reusable workflow for supplier notes",
            rationale: "Observed repeated successful runs for supplier note recovery.",
            evidenceJSON: #"{"runs":["run-1","run-2"]}"#,
            draftSkillMD: """
            ---
            name: supplier-notes
            description: Recover earlier supplier notes.
            metadata:
              author: fae
              version: "draft-1"
            ---
            Use this skill when the user asks about earlier supplier notes.
            """,
            confidence: 0.81
        )

        let pending = try await store.listDraftCandidates(statuses: [.pending])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, candidate.id)

        let fetched = try await store.fetchDraftCandidate(id: candidate.id)
        XCTAssertEqual(fetched?.workflowSignature, "session_search -> notes")
        XCTAssertEqual(fetched?.status, .pending)

        let updated = try await store.updateDraftCandidateStatus(id: candidate.id, status: .applied)
        XCTAssertEqual(updated?.status, .applied)
        let hasActive = try await store.hasActiveCandidate(forWorkflowSignature: "session_search -> notes")
        XCTAssertTrue(hasActive)
    }
}

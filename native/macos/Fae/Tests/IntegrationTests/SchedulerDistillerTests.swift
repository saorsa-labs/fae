import XCTest
@testable import Fae

/// Tests for the pure static distillation helpers inside FaeScheduler.
/// These are accessible via @testable despite being private static.
final class SchedulerDistillerTests: XCTestCase {

    // MARK: - derivedDistilledSkillName

    func testDerivedDistilledSkillNameFromGoals() {
        let name = FaeScheduler.derivedDistilledSkillName(
            userGoals: ["search the web for weather", "find weather forecast"],
            signature: "web_search -> fetch_url"
        )
        XCTAssertFalse(name.isEmpty)
    }

    func testDerivedDistilledSkillNameFromSignatureFallback() {
        let name = FaeScheduler.derivedDistilledSkillName(
            userGoals: ["a", "b"], // too short tokens → filtered out
            signature: "web_search -> fetch_url"
        )
        XCTAssertEqual(name, "web-search-fetch-url")
    }

    func testDerivedDistilledSkillNameUUIDFallback() {
        let name = FaeScheduler.derivedDistilledSkillName(
            userGoals: [],
            signature: ""
        )
        XCTAssertTrue(name.hasPrefix("workflow-"))
    }

    // MARK: - distilledSkillDescription

    func testDistilledSkillDescriptionWithExample() {
        let desc = FaeScheduler.distilledSkillDescription(
            skillName: "weather-check",
            userGoals: ["search for weather in London"],
            signature: "web_search -> fetch_url"
        )
        XCTAssertTrue(desc.contains("Reusable workflow"))
        XCTAssertTrue(desc.contains("London"))
    }

    func testDistilledSkillDescriptionWithoutExample() {
        let desc = FaeScheduler.distilledSkillDescription(
            skillName: "generic-task",
            userGoals: ["", "  "],
            signature: "read -> write"
        )
        XCTAssertTrue(desc.contains("Reusable workflow"))
    }

    // MARK: - distilledSkillBody

    func testDistilledSkillBody() {
        let body = FaeScheduler.distilledSkillBody(
            userGoals: ["search weather", "check forecast"],
            signature: "web_search -> fetch_url",
            outcomes: ["Got London weather"]
        )
        XCTAssertTrue(body.contains("Procedure:"))
        XCTAssertTrue(body.contains("Safety constraints:"))
        XCTAssertTrue(body.contains("Observed successful outcomes:"))
    }

    func testDistilledSkillBodyEmptyTools() {
        let body = FaeScheduler.distilledSkillBody(
            userGoals: [],
            signature: "",
            outcomes: []
        )
        XCTAssertTrue(body.contains("Procedure:"))
        XCTAssertTrue(body.contains("Clarify the user's goal"))
    }

    // MARK: - distilledInstruction

    func testDistilledInstructionWebSearch() {
        let instr = FaeScheduler.distilledInstruction(for: "web_search")
        XCTAssertTrue(instr.contains("web_search"))
        XCTAssertTrue(instr.contains("verify time-sensitive facts"))
    }

    func testDistilledInstructionSessionSearch() {
        let instr = FaeScheduler.distilledInstruction(for: "session_search")
        XCTAssertTrue(instr.contains("session_search"))
        XCTAssertTrue(instr.contains("prior transcript"))
    }

    func testDistilledInstructionUnknownTool() {
        let instr = FaeScheduler.distilledInstruction(for: "unknown_tool_xyz")
        XCTAssertTrue(instr.contains("unknown_tool_xyz"))
    }

    // MARK: - distilledSkillRationale

    func testDistilledSkillRationaleNoFindings() {
        let now = Date()
        let runs = [
            makeRun(id: "r1", goal: "search weather", outcome: "done", completedAt: now),
            makeRun(id: "r2", goal: "check forecast", outcome: "done", completedAt: now),
        ]
        let rationale = FaeScheduler.distilledSkillRationale(
            runs: runs, signature: "web_search -> fetch_url", findings: []
        )
        XCTAssertTrue(rationale.contains("2 successful runs"))
    }

    func testDistilledSkillRationaleWithFindings() {
        let now = Date()
        let runs = [
            makeRun(id: "r1", goal: "search weather", outcome: "done", completedAt: now),
        ]
        let findings = [
            SkillSecurityReviewFinding(severity: .warning, title: "Minor issue", detail: "some detail"),
        ]
        let rationale = FaeScheduler.distilledSkillRationale(
            runs: runs, signature: "web_search", findings: findings
        )
        XCTAssertTrue(rationale.contains("Reviewer findings"))
    }

    // MARK: - distilledEvidenceJSON

    func testDistilledEvidenceJSON() {
        let now = Date()
        let runs = [
            makeRun(id: "r1", goal: "search weather", outcome: "done", completedAt: now),
        ]
        let json = FaeScheduler.distilledEvidenceJSON(
            runs: runs, signature: "web_search", findings: []
        )
        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("workflow_signature"))
    }

    func testDistilledEvidenceJSONWithFindings() {
        let now = Date()
        let runs = [
            makeRun(id: "r1", goal: "search weather", outcome: "done", completedAt: now),
        ]
        let findings = [
            SkillSecurityReviewFinding(severity: .critical, title: "Critical issue", detail: "details"),
        ]
        let json = FaeScheduler.distilledEvidenceJSON(
            runs: runs, signature: "web_search", findings: findings
        )
        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("findings"))
    }

    // MARK: - Helpers

    private func makeRun(id: String, goal: String, outcome: String?, completedAt: Date?) -> WorkflowRunRecord {
        WorkflowRunRecord(
            id: id,
            sessionId: nil,
            turnId: nil,
            source: "test",
            userGoal: goal,
            assistantOutcome: outcome,
            toolSequenceSignature: nil,
            stepCount: 1,
            success: true,
            userApproved: true,
            damageControlIntervened: false,
            status: .completed,
            createdAt: Date(),
            updatedAt: Date(),
            completedAt: completedAt
        )
    }

    // MARK: - renderDistilledSkillMarkdown

    func testRenderDistilledSkillMarkdown() {
        let md = FaeScheduler.renderDistilledSkillMarkdown(
            name: "test-skill",
            description: "A test skill",
            body: "Do something useful"
        )
        XCTAssertTrue(md.contains("---"))
        XCTAssertTrue(md.contains("name: test-skill"))
        XCTAssertTrue(md.contains("author: fae"))
    }

    // MARK: - distilledConfidence

    func testDistilledConfidenceBase() {
        let conf = FaeScheduler.distilledConfidence(runCount: 2, findings: [])
        XCTAssertEqual(conf, 0.55, accuracy: 0.01)
    }

    func testDistilledConfidenceWithMoreRuns() {
        let conf = FaeScheduler.distilledConfidence(runCount: 10, findings: [])
        XCTAssertGreaterThan(conf, 0.55)
        XCTAssertLessThan(conf, 1.0)
    }

    func testDistilledConfidenceCriticalPenalty() {
        let findings = [SkillSecurityReviewFinding(severity: .critical, title: "Bad", detail: "")]
        let conf = FaeScheduler.distilledConfidence(runCount: 5, findings: findings)
        XCTAssertLessThan(conf, 0.70) // base ~0.79 - 0.20 penalty
    }

    func testDistilledConfidenceWarningPenalty() {
        let findings = [SkillSecurityReviewFinding(severity: .warning, title: "Minor", detail: "")]
        let conf = FaeScheduler.distilledConfidence(runCount: 5, findings: findings)
        XCTAssertLessThan(conf, 0.80)
    }

    func testDistilledConfidenceMinimum() {
        // Even with many penalties, confidence stays above 0.2
        let findings = [SkillSecurityReviewFinding(severity: .critical, title: "Bad", detail: "")]
        let conf = FaeScheduler.distilledConfidence(runCount: 2, findings: findings)
        XCTAssertGreaterThanOrEqual(conf, 0.2)
    }


}

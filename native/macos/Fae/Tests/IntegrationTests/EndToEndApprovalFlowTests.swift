import XCTest
@testable import Fae

/// Tests the tool approval flow using ToolRiskPolicy and VoiceIdentityPolicy.
///
/// These tests verify the decision-making logic that determines whether a tool
/// execution should proceed, require approval, or be denied. The actual UI
/// approval overlay is not tested here (requires a running app).
final class EndToEndApprovalFlowTests: XCTestCase {

    // MARK: - Risk Policy Decisions

    func testMediumRiskToolRequestsApproval() async throws {
        let tool = MockTool(name: "write", riskLevel: .medium, requiresApproval: false)
        let decision = ToolRiskPolicy.decision(for: tool)

        if case .requireApproval(let reason) = decision {
            XCTAssertTrue(reason.contains("medium"), "Reason should mention risk level")
        } else {
            XCTFail("Medium-risk tool should require approval")
        }
    }

    func testHighRiskToolRequestsApproval() async throws {
        let tool = MockTool(name: "bash", riskLevel: .high, requiresApproval: false)
        let decision = ToolRiskPolicy.decision(for: tool)

        if case .requireApproval(let reason) = decision {
            XCTAssertTrue(reason.contains("high"), "Reason should mention risk level")
        } else {
            XCTFail("High-risk tool should require approval")
        }
    }

    func testLowRiskToolWithExplicitApprovalRequiresIt() async throws {
        let tool = MockTool(name: "special_read", riskLevel: .low, requiresApproval: true)
        let decision = ToolRiskPolicy.decision(for: tool)

        if case .requireApproval = decision {
            // Expected — explicit requiresApproval overrides risk level
        } else {
            XCTFail("Tool with requiresApproval=true should require approval")
        }
    }

    // MARK: - Combined Voice + Risk

    func testNonOwnerMediumRiskRequiresBothPolicies() async throws {
        let config = FaeConfig.SpeakerConfig()
        // requireOwnerForTools defaults to true

        let voiceDecision = VoiceIdentityPolicy.evaluateSensitiveAction(
            config: config,
            isOwner: false,
            risk: .medium,
            toolName: "write"
        )

        let tool = MockTool(name: "write", riskLevel: .medium, requiresApproval: false)
        let riskDecision = ToolRiskPolicy.decision(for: tool)

        // Voice policy should require step-up.
        if case .requireStepUp = voiceDecision {
            // Expected
        } else {
            XCTFail("Voice policy should require step-up for non-owner + medium risk")
        }

        // Risk policy should also require approval.
        if case .requireApproval = riskDecision {
            // Expected
        } else {
            XCTFail("Risk policy should require approval for medium-risk tool")
        }
    }

    func testOwnerLowRiskPassesBothPolicies() async throws {
        let config = FaeConfig.SpeakerConfig()

        let voiceDecision = VoiceIdentityPolicy.evaluateSensitiveAction(
            config: config,
            isOwner: true,
            risk: .low,
            toolName: "read"
        )

        let tool = MockTool(name: "read", riskLevel: .low, requiresApproval: false)
        let riskDecision = ToolRiskPolicy.decision(for: tool)

        XCTAssertEqual(voiceDecision, .allow)
        if case .allow = riskDecision {
            // Expected
        } else {
            XCTFail("Low-risk tool from owner should be allowed")
        }
    }

    // MARK: - Event Bus Approval Events

    func testApprovalEventsEmittedOnBus() async throws {
        let bus = FaeEventBus()
        let collector = EventCollector()
        await collector.start(bus: bus)

        // Simulate approval request event.
        bus.send(.approvalRequested(id: 1, toolName: "bash", input: "{\"command\": \"ls\"}"))

        // Simulate approval resolution.
        bus.send(.approvalResolved(id: 1, approved: true, source: "user"))

        // Allow Combine delivery.
        try await Task.sleep(nanoseconds: 50_000_000)

        let events = await collector.allEvents()

        let requested = events.compactMap { event -> String? in
            if case .approvalRequested(_, let name, _) = event { return name }
            return nil
        }
        let resolved = events.compactMap { event -> Bool? in
            if case .approvalResolved(_, let approved, _) = event { return approved }
            return nil
        }

        XCTAssertEqual(requested, ["bash"])
        XCTAssertEqual(resolved, [true])
    }

    func testDeniedApprovalEmitsCorrectEvent() async throws {
        let bus = FaeEventBus()
        let collector = EventCollector()
        await collector.start(bus: bus)

        bus.send(.approvalRequested(id: 2, toolName: "write", input: "{}"))
        bus.send(.approvalResolved(id: 2, approved: false, source: "timeout"))

        try await Task.sleep(nanoseconds: 50_000_000)

        let events = await collector.allEvents()
        let resolved = events.compactMap { event -> (Bool, String)? in
            if case .approvalResolved(_, let approved, let source) = event {
                return (approved, source)
            }
            return nil
        }
        XCTAssertEqual(resolved.count, 1)
        XCTAssertFalse(resolved.first!.0)
        XCTAssertEqual(resolved.first!.1, "timeout")
    }
}

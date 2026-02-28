import XCTest
@testable import Fae

/// Tests the voice identity and tool risk policy decision matrix.
///
/// Verifies that VoiceIdentityPolicy and ToolRiskPolicy work together correctly
/// to gate tool access based on speaker identity and tool risk level.
final class EndToEndVoiceIdentityTests: XCTestCase {

    private var harness: TestRuntimeHarness!

    override func setUp() async throws {
        harness = try TestRuntimeHarness()
        await harness.setUp()
    }

    override func tearDown() {
        harness.cleanup()
        harness = nil
    }

    // MARK: - Owner Access

    func testOwnerCanAccessAllRiskLevels() async throws {
        let config = harness.config.speaker
        let isOwner = true

        for risk in [ToolRiskLevel.low, .medium, .high] {
            let decision = VoiceIdentityPolicy.evaluateSensitiveAction(
                config: config,
                isOwner: isOwner,
                risk: risk,
                toolName: "test_\(risk.rawValue)"
            )
            XCTAssertEqual(decision, .allow, "Owner should be allowed for \(risk.rawValue) risk")
        }
    }

    // MARK: - Non-Owner Access

    func testNonOwnerDeniedHighRisk() async throws {
        let config = harness.config.speaker

        let decision = VoiceIdentityPolicy.evaluateSensitiveAction(
            config: config,
            isOwner: false,
            risk: .high,
            toolName: "bash"
        )
        if case .deny = decision {
            // Expected
        } else {
            XCTFail("Non-owner should be denied high-risk tool, got \(decision)")
        }
    }

    func testNonOwnerRequiresStepUpForMediumRisk() async throws {
        let config = harness.config.speaker

        let decision = VoiceIdentityPolicy.evaluateSensitiveAction(
            config: config,
            isOwner: false,
            risk: .medium,
            toolName: "write"
        )
        if case .requireStepUp = decision {
            // Expected
        } else {
            XCTFail("Non-owner should require step-up for medium-risk tool, got \(decision)")
        }
    }

    func testNonOwnerAllowedLowRisk() async throws {
        let config = harness.config.speaker

        let decision = VoiceIdentityPolicy.evaluateSensitiveAction(
            config: config,
            isOwner: false,
            risk: .low,
            toolName: "read"
        )
        XCTAssertEqual(decision, .allow)
    }

    // MARK: - Gating Disabled

    func testGatingDisabledAllowsNonOwner() async throws {
        var config = harness.config.speaker
        config.requireOwnerForTools = false

        for risk in [ToolRiskLevel.low, .medium, .high] {
            let decision = VoiceIdentityPolicy.evaluateSensitiveAction(
                config: config,
                isOwner: false,
                risk: risk,
                toolName: "test_\(risk.rawValue)"
            )
            XCTAssertEqual(decision, .allow,
                "With gating disabled, non-owner should be allowed for \(risk.rawValue)")
        }
    }

    // MARK: - Tool Risk Policy Integration

    func testToolRiskPolicyAllowsLowRisk() async throws {
        let tool = MockTool(name: "read", riskLevel: .low, requiresApproval: false)
        let decision = ToolRiskPolicy.decision(for: tool)
        if case .allow = decision {
            // Expected
        } else {
            XCTFail("Low-risk tool without approval should be allowed")
        }
    }

    func testToolRiskPolicyRequiresApprovalForMediumRisk() async throws {
        let tool = MockTool(name: "write", riskLevel: .medium, requiresApproval: false)
        let decision = ToolRiskPolicy.decision(for: tool)
        if case .requireApproval = decision {
            // Expected
        } else {
            XCTFail("Medium-risk tool should require approval")
        }
    }

    func testToolRiskPolicyRequiresApprovalWhenExplicit() async throws {
        let tool = MockTool(name: "special", riskLevel: .low, requiresApproval: true)
        let decision = ToolRiskPolicy.decision(for: tool)
        if case .requireApproval = decision {
            // Expected
        } else {
            XCTFail("Tool with requiresApproval should require approval regardless of risk")
        }
    }

    // MARK: - Combined Decision Matrix

    func testFullDecisionMatrix() async throws {
        let config = harness.config.speaker
        let matrix: [(isOwner: Bool, risk: ToolRiskLevel, expected: String)] = [
            (true, .low, "allow"),
            (true, .medium, "allow"),
            (true, .high, "allow"),
            (false, .low, "allow"),
            (false, .medium, "stepUp"),
            (false, .high, "deny"),
        ]

        for entry in matrix {
            let decision = VoiceIdentityPolicy.evaluateSensitiveAction(
                config: config,
                isOwner: entry.isOwner,
                risk: entry.risk,
                toolName: "test"
            )
            let actual: String
            switch decision {
            case .allow: actual = "allow"
            case .requireStepUp: actual = "stepUp"
            case .deny: actual = "deny"
            }
            XCTAssertEqual(actual, entry.expected,
                "owner=\(entry.isOwner) risk=\(entry.risk.rawValue): expected \(entry.expected), got \(actual)")
        }
    }
}

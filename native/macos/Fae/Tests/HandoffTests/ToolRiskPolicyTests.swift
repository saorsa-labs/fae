import XCTest
@testable import Fae

final class ToolRiskPolicyTests: XCTestCase {
    struct StubTool: Tool {
        let name: String
        let description: String
        let parametersSchema: String
        let requiresApproval: Bool
        let riskLevel: ToolRiskLevel

        func execute(input: [String: Any]) async throws -> ToolResult {
            .success("ok")
        }
    }

    func testLowRiskNoApprovalAllows() {
        let tool = StubTool(
            name: "stub",
            description: "stub",
            parametersSchema: "{}",
            requiresApproval: false,
            riskLevel: .low
        )

        let decision = ToolRiskPolicy.decision(for: tool)
        if case .allow = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected allow")
        }
    }

    func testMediumRiskRequiresApproval() {
        let tool = StubTool(
            name: "stub",
            description: "stub",
            parametersSchema: "{}",
            requiresApproval: false,
            riskLevel: .medium
        )

        let decision = ToolRiskPolicy.decision(for: tool)
        if case .requireApproval = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected requireApproval")
        }
    }

    func testExplicitApprovalRequirementWins() {
        let tool = StubTool(
            name: "stub",
            description: "stub",
            parametersSchema: "{}",
            requiresApproval: true,
            riskLevel: .low
        )

        let decision = ToolRiskPolicy.decision(for: tool)
        if case .requireApproval = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected requireApproval")
        }
    }
}

import XCTest
@testable import Fae

final class AgentLoopRiskEnforcementTests: XCTestCase {
    func testToolRegistrySchemasIncludeRiskLine() {
        let registry = ToolRegistry(tools: [ReadTool(), WriteTool()])
        let schemas = registry.toolSchemas

        XCTAssertTrue(schemas.contains("Risk: low") || schemas.contains("Risk: medium") || schemas.contains("Risk: high"))
        XCTAssertTrue(schemas.contains("## read"))
        XCTAssertTrue(schemas.contains("## write"))
    }
}

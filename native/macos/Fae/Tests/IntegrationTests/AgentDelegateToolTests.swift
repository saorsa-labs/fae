import XCTest
@testable import Fae

final class AgentDelegateToolTests: XCTestCase {

    // MARK: - bestEffortOutput

    func testBestEffortOutputStdout() {
        let output = AgentDelegateTool.bestEffortOutput(stdout: "result", stderr: "error")
        XCTAssertEqual(output, "result")
    }

    func testBestEffortOutputEmptyStdout() {
        let output = AgentDelegateTool.bestEffortOutput(stdout: "  \n", stderr: "fallback error")
        XCTAssertEqual(output, "fallback error")
    }

    func testBestEffortOutputBothEmpty() {
        let output = AgentDelegateTool.bestEffortOutput(stdout: "", stderr: "")
        XCTAssertEqual(output, "")
    }

    // MARK: - isSafeEnvironmentVariableName

    func testIsSafeEnvVarValid() {
        XCTAssertTrue(AgentDelegateTool.isSafeEnvironmentVariableName("API_KEY"))
    }

    func testIsSafeEnvVarLowercase() {
        XCTAssertFalse(AgentDelegateTool.isSafeEnvironmentVariableName("api_key"))
    }

    func testIsSafeEnvVarTooShort() {
        XCTAssertFalse(AgentDelegateTool.isSafeEnvironmentVariableName("A"))
    }

    func testIsSafeEnvVarSpecialChars() {
        XCTAssertFalse(AgentDelegateTool.isSafeEnvironmentVariableName("API-KEY"))
    }
}

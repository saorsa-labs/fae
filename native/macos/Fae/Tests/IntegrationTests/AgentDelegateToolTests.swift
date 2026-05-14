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

    // MARK: - buildPrompt

    func testBuildPromptReadOnly() {
        let prompt = AgentDelegateTool.buildPrompt(prompt: "fix this", mode: .readOnly, appendSystemPrompt: nil)
        XCTAssertTrue(prompt.contains("read-only"))
    }

    func testBuildPromptReadWrite() {
        let prompt = AgentDelegateTool.buildPrompt(prompt: "fix this", mode: .readWrite, appendSystemPrompt: nil)
        XCTAssertTrue(prompt.contains("modify files"))
    }

    func testBuildPromptWithAppendSystemPrompt() {
        let prompt = AgentDelegateTool.buildPrompt(prompt: "fix this", mode: .readOnly, appendSystemPrompt: "extra context")
        XCTAssertTrue(prompt.contains("extra context"))
    }
}

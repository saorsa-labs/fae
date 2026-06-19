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

    // MARK: - shouldUseDaemon (gap A1 lane selection)

    func testShouldUseDaemonRejectsModelOverride() {
        // The daemon `agent.run` does not yet forward a provider-specific model,
        // so a model override must stay on the subprocess path that honors it.
        XCTAssertFalse(
            AgentDelegateTool.shouldUseDaemon(model: "gpt-5", secretBindings: [:]))
    }

    func testShouldUseDaemonRejectsSecretBindings() {
        // Secret env injection is a subprocess-only feature today.
        XCTAssertFalse(
            AgentDelegateTool.shouldUseDaemon(model: nil, secretBindings: ["API_KEY": "k"]))
    }

    func testShouldUseDaemonDefaultsToDaemon() {
        // Default lane is the daemon — only meaningful when the force-subprocess
        // override is not set in this process's environment.
        if ProcessInfo.processInfo.environment["FAE_AGENT_SUBPROCESS"] == nil {
            XCTAssertTrue(
                AgentDelegateTool.shouldUseDaemon(model: nil, secretBindings: [:]))
        }
    }

    // MARK: - A3 permission-card option selection

    func testFirstAllowOptionPrefersAllowKind() {
        let options: [[String: Any]] = [
            ["id": "reject", "name": "Reject", "kind": "RejectOnce"],
            ["id": "ok", "name": "Allow once", "kind": "AllowOnce"],
        ]
        XCTAssertEqual(DaemonAgentClient.firstAllowOption(options), "ok")
    }

    func testFirstAllowOptionFallsBackToFirst() {
        // No "allow" option → fall back to the first offered option.
        let options: [[String: Any]] = [
            ["id": "a", "name": "Proceed", "kind": "Proceed"],
            ["id": "b", "name": "Stop", "kind": "Stop"],
        ]
        XCTAssertEqual(DaemonAgentClient.firstAllowOption(options), "a")
        XCTAssertNil(DaemonAgentClient.firstAllowOption([]))
    }
}

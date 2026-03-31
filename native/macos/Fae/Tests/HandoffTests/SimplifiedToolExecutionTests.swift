import XCTest
@testable import Fae

/// Verify the simplified 3-step tool execution flow:
///
/// 1. Registry lookup (tool exists + mode allows it)
/// 2. DamageControlPolicy evaluate (bash patterns, path rules)
/// 3. Execute
///
/// Owner hits zero gates for all registered tools in "full" mode.
final class SimplifiedToolExecutionTests: XCTestCase {

    // MARK: - Test Doubles

    private struct PassthroughTool: Tool {
        let name: String
        let description: String = "stub"
        let parametersSchema: String = "{}"
        let riskLevel: ToolRiskLevel = .low
        let requiresApproval: Bool = false

        func execute(input: [String: Any]) async throws -> ToolResult {
            .success("ok:\(name)")
        }
    }

    // MARK: - Helpers

    private func makeExecutor(toolNames: [String]) -> ToolExecutor {
        let tools: [any Tool] = toolNames.map { PassthroughTool(name: $0) }
        return ToolExecutor(
            registry: ToolRegistry(tools: tools),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared
        )
    }

    private func ownerContext() -> ToolExecutorContext {
        ToolExecutorContext(
            toolMode: "full",
            privacyMode: "local_preferred",
            modelLocality: .local,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            speakerId: "owner-123",
            actionSource: .voice,
            proactiveContext: nil,
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil
        )
    }

    private let noopCallbacks = ToolExecutorCallbacks(
        onApprovalPending: { _, _ in },
        onVisionAutoEnabled: { },
        onComputerUseStep: { 0 }
    )

    // MARK: - Owner Gets Zero Gates

    /// All 37 built-in tool names should execute without any gate blocking the owner.
    /// We register stub tools with each name and verify they all succeed.
    func testOwnerExecutesAllToolsWithZeroGates() async {
        let allToolNames = [
            "read", "write", "edit", "bash", "self_config", "channel_setup",
            "window_control", "session_search", "web_search", "fetch_url",
            "activate_skill", "run_skill", "manage_skill",
            "delegate_agent", "agent_session",
            "input_request",
            "calendar", "reminders", "contacts", "mail", "notes",
            "scheduler_list", "scheduler_create", "scheduler_update",
            "scheduler_delete", "scheduler_trigger",
            "roleplay",
            "screenshot", "camera", "read_screen",
            "click", "type_text", "scroll", "find_element",
            "till_done",
            "voice_identity",
            "plugin_manage",
        ]
        let executor = makeExecutor(toolNames: allToolNames)
        let context = ownerContext()

        for toolName in allToolNames {
            let call = ToolCall(name: toolName, arguments: [:])
            let result = await executor.execute(call, context: context, callbacks: noopCallbacks)
            XCTAssertFalse(
                result.result.isError,
                "Owner should execute '\(toolName)' without gates, but got error: \(result.result.output)"
            )
            XCTAssertFalse(result.damageControlIntervened, "No damage control for '\(toolName)' with safe args")
            XCTAssertTrue(result.result.output.contains("ok:\(toolName)"), "Expected stub output for '\(toolName)'")
        }
    }

    // MARK: - Registry Lookup (Step 1)

    func testUnregisteredToolRejected() async {
        let executor = makeExecutor(toolNames: ["read"])
        let context = ownerContext()
        let call = ToolCall(name: "nonexistent_tool", arguments: [:])

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError)
        XCTAssertTrue(result.result.output.contains("not available"))
    }

    func testToolModeOffBlocksAll() async {
        let executor = makeExecutor(toolNames: ["bash"])
        let context = ToolExecutorContext(
            toolMode: "off",
            privacyMode: "local_preferred",
            modelLocality: .local,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            speakerId: nil,
            actionSource: .voice,
            proactiveContext: nil,
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil
        )
        let call = ToolCall(name: "bash", arguments: [:])

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError)
        XCTAssertTrue(result.result.output.contains("not available"))
    }

    // MARK: - DamageControlPolicy (Step 2) Passes for Safe Commands

    func testOwnerRunsSafeBashCommandsUnblocked() async {
        let executor = makeExecutor(toolNames: ["bash"])
        let context = ownerContext()
        let safeBashCommands = [
            "ls -la",
            "echo hello",
            "swift build",
            "git status",
            "cat /tmp/test.txt",
        ]

        for command in safeBashCommands {
            let call = ToolCall(name: "bash", arguments: ["command": command])
            let result = await executor.execute(call, context: context, callbacks: noopCallbacks)
            XCTAssertFalse(result.result.isError, "Safe bash '\(command)' should succeed for owner")
            XCTAssertFalse(result.damageControlIntervened, "No DCP intervention for '\(command)'")
        }
    }

    // MARK: - Successful Execution Returns Metadata

    func testSuccessfulExecutionReturnsLatency() async {
        let executor = makeExecutor(toolNames: ["read"])
        let context = ownerContext()
        let call = ToolCall(name: "read", arguments: [:])

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertFalse(result.result.isError)
        XCTAssertNotNil(result.latencyMs)
        XCTAssertGreaterThanOrEqual(result.latencyMs ?? -1, 0)
    }

    // MARK: - Read-Only Mode Allows Read Tools

    func testReadOnlyModeAllowsReadTools() async {
        let readTools = ["read", "web_search", "calendar", "contacts"]
        let executor = makeExecutor(toolNames: readTools)
        let context = ToolExecutorContext(
            toolMode: "read_only",
            privacyMode: "local_preferred",
            modelLocality: .local,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            speakerId: nil,
            actionSource: .voice,
            proactiveContext: nil,
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil
        )

        for toolName in readTools {
            let call = ToolCall(name: toolName, arguments: [:])
            let result = await executor.execute(call, context: context, callbacks: noopCallbacks)
            XCTAssertFalse(result.result.isError, "Read-only mode should allow '\(toolName)'")
        }
    }

    func testReadOnlyModeBlocksWriteTools() async {
        let writeTools = ["write", "edit", "bash"]
        let executor = makeExecutor(toolNames: writeTools)
        let context = ToolExecutorContext(
            toolMode: "read_only",
            privacyMode: "local_preferred",
            modelLocality: .local,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            speakerId: nil,
            actionSource: .voice,
            proactiveContext: nil,
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil
        )

        for toolName in writeTools {
            let call = ToolCall(name: toolName, arguments: [:])
            let result = await executor.execute(call, context: context, callbacks: noopCallbacks)
            XCTAssertTrue(result.result.isError, "Read-only mode should block '\(toolName)'")
        }
    }
}

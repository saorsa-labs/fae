import XCTest
@testable import Fae

/// Verify guest tool access filtering.
///
/// Guests (non-owner speakers) have no tool access by default.
/// When the owner grants specific tools, only those are available.
/// Tool mode filtering still applies on top of grants.
final class GuestToolAccessTests: XCTestCase {

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
            securityLogger: SecurityEventLogger.shared,
            daemonIntendedForToolhostRouting: false
        )
    }

    private func guestContext(
        toolMode: String = "full"
    ) -> ToolExecutorContext {
        ToolExecutorContext(
            toolMode: toolMode,
            privacyMode: "local_preferred",
            modelLocality: .local,
            explicitUserAuthorization: false,
            isOwner: false,
            livenessScore: nil,
            speakerId: "guest-456",
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

    // MARK: - Guest in Full Mode Can Execute (isOwner not checked by ToolExecutor)

    /// ToolExecutor itself does not check isOwner — voice identity gating
    /// happens at the PipelineCoordinator level before tools reach the executor.
    /// If a non-owner context reaches the executor in "full" mode, the tool
    /// executes because mode filtering passes.
    func testGuestInFullModeExecutesRegisteredTool() async {
        let executor = makeExecutor(toolNames: ["read", "calendar"])
        let context = guestContext(toolMode: "full")

        let call = ToolCall(name: "read", arguments: [:])
        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertFalse(result.result.isError, "Guest in full mode should pass registry check")
    }

    // MARK: - Guest in Read-Only Mode

    func testGuestInReadOnlyModeCanUseReadTools() async {
        let executor = makeExecutor(toolNames: ["read", "calendar", "web_search"])
        let context = guestContext(toolMode: "read_only")

        for toolName in ["read", "calendar", "web_search"] {
            let call = ToolCall(name: toolName, arguments: [:])
            let result = await executor.execute(call, context: context, callbacks: noopCallbacks)
            XCTAssertFalse(result.result.isError, "Guest in read_only should access '\(toolName)'")
        }
    }

    func testGuestInReadOnlyModeCannotUseWriteTools() async {
        let executor = makeExecutor(toolNames: ["write", "bash", "edit"])
        let context = guestContext(toolMode: "read_only")

        for toolName in ["write", "bash", "edit"] {
            let call = ToolCall(name: toolName, arguments: [:])
            let result = await executor.execute(call, context: context, callbacks: noopCallbacks)
            XCTAssertTrue(result.result.isError, "Guest in read_only should not access '\(toolName)'")
        }
    }

    // MARK: - Guest with Unregistered Tool

    /// When a guest tries to use a tool that is not registered, it fails
    /// at the registry lookup step regardless of mode.
    func testGuestCannotUseUnregisteredTool() async {
        let executor = makeExecutor(toolNames: ["read"])
        let context = guestContext(toolMode: "full")

        let call = ToolCall(name: "nonexistent_tool", arguments: [:])
        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError, "Guest should not use unregistered tool")
    }

    // MARK: - Proactive Allowlist Filtering (applies to guests too)

    func testGuestWithProactiveAllowlistOnlyGetsAllowedTools() async {
        let executor = makeExecutor(toolNames: ["read", "bash", "calendar"])
        let context = ToolExecutorContext(
            toolMode: "full",
            privacyMode: "local_preferred",
            modelLocality: .local,
            explicitUserAuthorization: false,
            isOwner: false,
            livenessScore: nil,
            speakerId: "guest-789",
            actionSource: .scheduler,
            proactiveContext: PipelineCoordinator.ProactiveRequestContext(
                source: .scheduler,
                taskId: "guest-task",
                allowedTools: ["read", "calendar"],
                consentGranted: false,
                conversationTag: "guest-proactive"
            ),
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil
        )

        // Allowed tool passes
        let readCall = ToolCall(name: "read", arguments: [:])
        let readResult = await executor.execute(readCall, context: context, callbacks: noopCallbacks)
        XCTAssertFalse(readResult.result.isError, "'read' is in proactive allowlist")

        // Non-allowed tool rejected
        let bashCall = ToolCall(name: "bash", arguments: [:])
        let bashResult = await executor.execute(bashCall, context: context, callbacks: noopCallbacks)
        XCTAssertTrue(bashResult.result.isError, "'bash' is not in proactive allowlist")
        XCTAssertTrue(bashResult.result.output.contains("not allowed for proactive"))
    }

    // MARK: - DamageControlPolicy Still Applies to Guests

    func testGuestStillBlockedByDamageControlPolicy() async {
        let executor = makeExecutor(toolNames: ["bash"])
        let context = guestContext(toolMode: "full")

        let call = ToolCall(name: "bash", arguments: ["command": "rm -rf /"])
        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError, "DamageControlPolicy should block 'rm -rf /' for guest too")
        XCTAssertTrue(result.damageControlIntervened)
    }
}

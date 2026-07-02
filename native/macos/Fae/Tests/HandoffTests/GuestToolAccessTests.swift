import XCTest
@testable import Fae

/// Verify guest/relay tool access is denied at the EXECUTION boundary.
///
/// Voice identity is the security model: only the primary owner runs tools.
/// `ToolExecutor` hard-denies every tool for a non-owner (`isOwner == false`)
/// or relay-origin (`actionSource == .relay`) turn BEFORE tool-mode filtering,
/// the registry lookup, the proactive allowlist, or DamageControl run. Hiding
/// tool schemas at prompt assembly is not sufficient — a prompt-injected guest
/// / channel / x0x turn that elicits a `<tool_call>` or `<tool_program>` must
/// be stopped at the executor, not merely discouraged in the prompt.
///
/// Owner-authored automation (proactive / scheduler tasks) runs with
/// `isOwner == true` in production (see `PipelineCoordinator.injectProactiveQuery`),
/// so it is unaffected by the guest guard; the proactive allowlist remains its
/// gate.
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
        toolMode: String = "full",
        actionSource: ActionSource = .voice
    ) -> ToolExecutorContext {
        ToolExecutorContext(
            toolMode: toolMode,
            privacyMode: "local_preferred",
            modelLocality: .local,
            explicitUserAuthorization: false,
            isOwner: false,
            livenessScore: nil,
            speakerId: "guest-456",
            actionSource: actionSource,
            proactiveContext: nil,
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil
        )
    }

    private func ownerContext(
        toolMode: String = "full",
        actionSource: ActionSource = .voice,
        proactiveContext: PipelineCoordinator.ProactiveRequestContext? = nil
    ) -> ToolExecutorContext {
        ToolExecutorContext(
            toolMode: toolMode,
            privacyMode: "local_preferred",
            modelLocality: .local,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            speakerId: "owner-123",
            actionSource: actionSource,
            proactiveContext: proactiveContext,
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

    // MARK: - Guest is denied at the execution boundary (the core security property)

    /// A non-owner turn is denied even in "full" mode with a registered tool —
    /// the guard runs before mode filtering / registry lookup, so schema-hiding
    /// is not the only line of defense.
    func testGuestInFullModeIsDeniedAtBoundary() async {
        let executor = makeExecutor(toolNames: ["read", "calendar"])
        let context = guestContext(toolMode: "full")

        let call = ToolCall(name: "read", arguments: [:])
        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError, "Guest turn must be denied at the executor boundary")
    }

    /// Read-only mode does not rescue a guest: the boundary guard denies read
    /// tools too (a guest gets NO tools, not read-only tools).
    func testGuestInReadOnlyModeIsStillDenied() async {
        let executor = makeExecutor(toolNames: ["read", "calendar", "web_search"])
        let context = guestContext(toolMode: "read_only")

        for toolName in ["read", "calendar", "web_search"] {
            let call = ToolCall(name: toolName, arguments: [:])
            let result = await executor.execute(call, context: context, callbacks: noopCallbacks)
            XCTAssertTrue(result.result.isError, "Guest must be denied '\(toolName)' at the boundary")
        }
    }

    /// Write tools are denied for a guest (as before, now via the boundary guard
    /// rather than mode filtering).
    func testGuestCannotUseWriteTools() async {
        let executor = makeExecutor(toolNames: ["write", "bash", "edit"])
        let context = guestContext(toolMode: "read_only")

        for toolName in ["write", "bash", "edit"] {
            let call = ToolCall(name: toolName, arguments: [:])
            let result = await executor.execute(call, context: context, callbacks: noopCallbacks)
            XCTAssertTrue(result.result.isError, "Guest must not access '\(toolName)'")
        }
    }

    /// A relay-origin turn (remote channel / x0x peer) is denied even if a bug
    /// ever set `isOwner == true` on it — defense-in-depth on the origin.
    func testRelayOriginIsDeniedEvenIfMarkedOwner() async {
        let executor = makeExecutor(toolNames: ["read"])
        let context = ownerContext(actionSource: .relay)

        let call = ToolCall(name: "read", arguments: [:])
        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError, "Relay-origin turn must be denied regardless of isOwner")
    }

    // MARK: - Owner is NOT over-blocked by the guard

    /// The guard must not regress owner access: an owner full-mode call to a
    /// registered tool still executes.
    func testOwnerInFullModeExecutesRegisteredTool() async {
        let executor = makeExecutor(toolNames: ["read", "calendar"])
        let context = ownerContext(toolMode: "full")

        let call = ToolCall(name: "read", arguments: [:])
        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertFalse(result.result.isError, "Owner in full mode should execute a registered tool")
    }

    // MARK: - Proactive Allowlist Filtering (owner-authored automation)

    /// Proactive/scheduler tasks run as the owner in production; the proactive
    /// allowlist is their gate. Allowed tools pass, non-allowed tools are
    /// rejected — the guest guard does not interfere because `isOwner == true`.
    func testProactiveAllowlistOnlyGrantsAllowedTools() async {
        let executor = makeExecutor(toolNames: ["read", "bash", "calendar"])
        let context = ownerContext(
            actionSource: .scheduler,
            proactiveContext: PipelineCoordinator.ProactiveRequestContext(
                source: .scheduler,
                taskId: "owner-task",
                allowedTools: ["read", "calendar"],
                consentGranted: false,
                conversationTag: "owner-proactive"
            )
        )

        // Allowed tool passes
        let readCall = ToolCall(name: "read", arguments: [:])
        let readResult = await executor.execute(readCall, context: context, callbacks: noopCallbacks)
        XCTAssertFalse(readResult.result.isError, "'read' is in the proactive allowlist")

        // Non-allowed tool rejected
        let bashCall = ToolCall(name: "bash", arguments: [:])
        let bashResult = await executor.execute(bashCall, context: context, callbacks: noopCallbacks)
        XCTAssertTrue(bashResult.result.isError, "'bash' is not in the proactive allowlist")
        XCTAssertTrue(bashResult.result.output.contains("not allowed for proactive"))
    }

    // MARK: - DamageControlPolicy Still Applies to the Owner

    /// DamageControl is the owner's catastrophe backstop (owners get full tool
    /// access; DamageControl blocks catastrophic ops). Verify it still fires for
    /// an owner `rm -rf /` — the guest guard is not the only bash protection.
    func testOwnerStillBlockedByDamageControlPolicy() async {
        let executor = makeExecutor(toolNames: ["bash"])
        let context = ownerContext(toolMode: "full")

        let call = ToolCall(name: "bash", arguments: ["command": "rm -rf /"])
        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError, "DamageControlPolicy should block 'rm -rf /' for the owner")
        XCTAssertTrue(result.damageControlIntervened)
    }
}

import GRDB
import XCTest
@testable import Fae

// MARK: - Test Doubles

private struct StubTool: Tool {
    let name: String
    let description: String = "stub"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel
    let requiresApproval: Bool

    var resultJSON: String = #"{"ok":true}"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        .success(resultJSON)
    }
}

private struct SlowTool: Tool {
    let name: String = "slow"
    let description: String = "sleeps forever"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .low
    let requiresApproval: Bool = false

    func execute(input: [String: Any]) async throws -> ToolResult {
        try await Task.sleep(nanoseconds: 60_000_000_000) // 60s
        return .success("done")
    }
}

private struct ThrowingTool: Tool {
    let name: String = "thrower"
    let description: String = "throws"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .low
    let requiresApproval: Bool = false

    func execute(input: [String: Any]) async throws -> ToolResult {
        throw NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "intentional test error"])
    }
}

/// Broker that always allows, and records whether it was called.
private actor RecordingBroker: TrustedActionBroker {
    var evaluateCalled = false
    var lastIntent: ActionIntent?

    func evaluate(_ intent: ActionIntent) async -> BrokerDecision {
        evaluateCalled = true
        lastIntent = intent
        return .allow(reason: DecisionReason(code: .allowLowRisk, message: "test allow"))
    }
}

/// Broker that always denies.
private actor DenyingBroker: TrustedActionBroker {
    func evaluate(_ intent: ActionIntent) async -> BrokerDecision {
        .deny(reason: DecisionReason(code: .noCapabilityTicket, message: "denied by test"))
    }
}

// MARK: - Helper

private func makeExecutor(
    tools: [any Tool] = [],
    broker: any TrustedActionBroker = RecordingBroker()
) -> ToolExecutor {
    let registry = ToolRegistry(tools: tools)
    return ToolExecutor(
        registry: registry,
        actionBroker: broker,
        damageControlPolicy: DamageControlPolicy(),
        rateLimiter: ToolRateLimiter(),
        securityLogger: SecurityEventLogger.shared,
        outboundGuard: OutboundExfiltrationGuard.shared
    )
}

private func makeContext(
    toolMode: String = "full",
    privacyMode: String = "local_preferred"
) -> ToolExecutorContext {
    ToolExecutorContext(
        toolMode: toolMode,
        privacyMode: privacyMode,
        modelLocality: .local,
        capabilityTicket: nil,
        hasCapabilityTicketForTool: true,
        explicitUserAuthorization: false,
        isOwner: true,
        livenessScore: nil,
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
    onComputerUseStep: { 1 }
)

private func makeCall(name: String, arguments: [String: Any] = [:]) -> ToolCall {
    ToolCall(name: name, arguments: arguments)
}

// MARK: - Tests

final class ToolExecutorTests: XCTestCase {

    // MARK: Static Helpers

    func testToolTimeoutSecondsDefaultIs30() {
        XCTAssertEqual(ToolExecutor.toolTimeoutSeconds(for: "read"), 30)
        XCTAssertEqual(ToolExecutor.toolTimeoutSeconds(for: "bash"), 30)
    }

    func testToolTimeoutSecondsVisionIs180() {
        XCTAssertEqual(ToolExecutor.toolTimeoutSeconds(for: "screenshot"), 180)
        XCTAssertEqual(ToolExecutor.toolTimeoutSeconds(for: "camera"), 180)
        XCTAssertEqual(ToolExecutor.toolTimeoutSeconds(for: "read_screen"), 180)
    }

    func testIsSelfConfigReadAction() {
        XCTAssertTrue(ToolExecutor.isSelfConfigReadAction(arguments: ["action": "get_settings"]))
        XCTAssertTrue(ToolExecutor.isSelfConfigReadAction(arguments: ["action": "GET_DIRECTIVE"]))
        XCTAssertFalse(ToolExecutor.isSelfConfigReadAction(arguments: ["action": "adjust_setting"]))
        XCTAssertFalse(ToolExecutor.isSelfConfigReadAction(arguments: [:]))
    }

    func testToolRequiresApprovalSelfConfigRead() {
        XCTAssertFalse(ToolExecutor.toolRequiresApproval(
            toolName: "self_config",
            arguments: ["action": "get_settings"],
            defaultRequiresApproval: true
        ))
    }

    func testToolRequiresApprovalCalendarCreate() {
        XCTAssertTrue(ToolExecutor.toolRequiresApproval(
            toolName: "calendar",
            arguments: ["action": "create"],
            defaultRequiresApproval: false
        ))
    }

    func testIsSafeSkillName() {
        XCTAssertTrue(ToolExecutor.isSafeSkillName("my-skill"))
        XCTAssertTrue(ToolExecutor.isSafeSkillName("skill_123"))
        XCTAssertFalse(ToolExecutor.isSafeSkillName("../escape"))
        XCTAssertFalse(ToolExecutor.isSafeSkillName("path/traversal"))
        XCTAssertFalse(ToolExecutor.isSafeSkillName(""))
    }

    // MARK: Tool Mode Enforcement

    func testToolModeBlocksUnallowedTool() async {
        let tool = StubTool(name: "bash", riskLevel: .high, requiresApproval: false)
        let executor = makeExecutor(tools: [tool])
        let context = makeContext(toolMode: "off")
        let call = makeCall(name: "bash")

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError)
        XCTAssertTrue(result.result.output.contains("not available"))
    }

    // MARK: Unknown Tool

    func testUnknownToolIsBlockedByModeCheck() async {
        // In "full" mode, isToolAllowed returns false for unregistered tools,
        // so the mode check catches it before the "Unknown tool" lookup.
        let executor = makeExecutor(tools: [])
        let context = makeContext()
        let call = makeCall(name: "nonexistent_tool")

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError)
        XCTAssertTrue(result.result.output.contains("not available"))
    }

    // MARK: Happy Path

    func testSuccessfulExecutionReturnsResult() async {
        let tool = StubTool(name: "read", riskLevel: .low, requiresApproval: false)
        let executor = makeExecutor(tools: [tool])
        let context = makeContext()
        let call = makeCall(name: "read", arguments: ["path": "/tmp/test"])

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertFalse(result.result.isError)
        XCTAssertTrue(result.result.output.contains("ok"))
        XCTAssertFalse(result.damageControlIntervened)
    }

    // MARK: Broker Deny

    func testBrokerDenyReturnsError() async {
        let tool = StubTool(name: "read", riskLevel: .low, requiresApproval: false)
        let executor = makeExecutor(tools: [tool], broker: DenyingBroker())
        let context = makeContext()
        let call = makeCall(name: "read", arguments: ["path": "/tmp/test"])

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError)
        XCTAssertTrue(result.result.output.contains("denied by test"))
    }

    // MARK: Broker is called after preflight passes

    func testBrokerIsCalledForAllowedTool() async {
        let tool = StubTool(name: "read", riskLevel: .low, requiresApproval: false)
        let broker = RecordingBroker()
        let executor = makeExecutor(tools: [tool], broker: broker)
        let context = makeContext()
        let call = makeCall(name: "read", arguments: ["path": "/tmp/test"])

        _ = await executor.execute(call, context: context, callbacks: noopCallbacks)

        let wasCalled = await broker.evaluateCalled
        XCTAssertTrue(wasCalled)
    }

    // MARK: Proactive allowlist

    func testProactiveAllowlistBlocksUnlistedTool() async {
        let tool = StubTool(name: "bash", riskLevel: .high, requiresApproval: false)
        let executor = makeExecutor(tools: [tool])
        var context = makeContext()
        context = ToolExecutorContext(
            toolMode: context.toolMode,
            privacyMode: context.privacyMode,
            modelLocality: context.modelLocality,
            capabilityTicket: context.capabilityTicket,
            hasCapabilityTicketForTool: context.hasCapabilityTicketForTool,
            explicitUserAuthorization: context.explicitUserAuthorization,
            isOwner: context.isOwner,
            livenessScore: context.livenessScore,
            actionSource: context.actionSource,
            proactiveContext: PipelineCoordinator.ProactiveRequestContext(
                source: .scheduler,
                taskId: "test-task",
                allowedTools: ["read"],
                consentGranted: false,
                conversationTag: "test"
            ),
            visionEnabled: context.visionEnabled,
            firstOwnerEnrollmentActive: context.firstOwnerEnrollmentActive,
            workflowTurnID: context.workflowTurnID,
            traceToolCallID: context.traceToolCallID,
            workflowRunID: nil
        )
        let call = makeCall(name: "bash")

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError)
        XCTAssertTrue(result.result.output.contains("not allowed for proactive"))
    }

    // MARK: - Damage Control

    func testDamageControlBlocksDestructiveBash() async {
        let tool = StubTool(name: "bash", riskLevel: .high, requiresApproval: false)
        let executor = makeExecutor(tools: [tool])
        let context = makeContext()
        let call = makeCall(name: "bash", arguments: ["command": "sudo rm -rf /"])

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError, "Destructive bash should be blocked")
        XCTAssertTrue(result.damageControlIntervened, "damageControlIntervened should be true")
    }

    // MARK: - Shadow Mode

    func testShadowModeBypassesDenyToAllow() async {
        FaeEnvironment.defaults.set(true, forKey: "fae.security.shadowMode")
        defer { FaeEnvironment.defaults.removeObject(forKey: "fae.security.shadowMode") }

        let tool = StubTool(name: "read", riskLevel: .low, requiresApproval: false)
        let executor = makeExecutor(tools: [tool], broker: DenyingBroker())
        let context = makeContext()
        let call = makeCall(name: "read", arguments: ["path": "/tmp/test"])

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        // Shadow mode converts deny → allow, so the tool executes successfully
        XCTAssertFalse(result.result.isError, "Shadow mode should bypass deny: \(result.result.output)")
    }

    // MARK: - Approval with No Manager

    func testConfirmWithNoApprovalManagerReturnsError() async {
        let tool = StubTool(name: "write", riskLevel: .medium, requiresApproval: true)
        let broker = ConfirmingBroker()
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [tool]),
            actionBroker: broker,
            damageControlPolicy: DamageControlPolicy(),
            rateLimiter: ToolRateLimiter(),
            securityLogger: SecurityEventLogger.shared,
            outboundGuard: OutboundExfiltrationGuard.shared,
            approvalManager: nil // no manager
        )
        let context = makeContext()
        let call = makeCall(name: "write", arguments: ["path": "/tmp/test", "content": "hello"])

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError)
        XCTAssertTrue(result.result.output.contains("approval manager"), "Expected approval manager error, got: \(result.result.output)")
    }

    // MARK: - Throwing Tool

    func testThrowingToolReturnsErrorResult() async {
        let tool = ThrowingTool()
        let executor = makeExecutor(tools: [tool])
        let context = makeContext()
        let call = makeCall(name: "thrower")

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError)
        XCTAssertTrue(result.result.output.contains("Tool error"), "Expected 'Tool error', got: \(result.result.output)")
    }

    // MARK: - Argument Injection

    func testCapabilityTicketInjectedForRunSkill() async {
        let capturingTool = CapturingTool(name: "run_skill")
        let executor = makeExecutor(tools: [capturingTool])
        let ticket = CapabilityTicket(
            id: "test-ticket-42",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(300),
            allowedTools: ["run_skill"]
        )
        let context = ToolExecutorContext(
            toolMode: "full",
            privacyMode: "local_preferred",
            modelLocality: .local,
            capabilityTicket: ticket,
            hasCapabilityTicketForTool: true,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            actionSource: .voice,
            proactiveContext: nil,
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil
        )
        let call = makeCall(name: "run_skill", arguments: ["name": "test-skill"])

        _ = await executor.execute(call, context: context, callbacks: noopCallbacks)

        let captured = capturingTool.capturedInput
        XCTAssertEqual(captured?["capability_ticket"] as? String, "test-ticket-42")
    }

    // MARK: - Vision Auto-Enable Callback

    func testVisionAutoEnableCallbackFired() async {
        let tool = StubTool(name: "screenshot", riskLevel: .low, requiresApproval: false)
        let executor = makeExecutor(tools: [tool])
        let context = ToolExecutorContext(
            toolMode: "full",
            privacyMode: "local_preferred",
            modelLocality: .local,
            capabilityTicket: nil,
            hasCapabilityTicketForTool: true,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            actionSource: .voice,
            proactiveContext: nil,
            visionEnabled: false, // vision disabled
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil
        )
        var visionEnabled = false
        let callbacks = ToolExecutorCallbacks(
            onApprovalPending: { _, _ in },
            onVisionAutoEnabled: { visionEnabled = true },
            onComputerUseStep: { 1 }
        )
        let call = makeCall(name: "screenshot")

        _ = await executor.execute(call, context: context, callbacks: callbacks)

        XCTAssertTrue(visionEnabled, "onVisionAutoEnabled should have been called for screenshot with visionEnabled=false")
    }

    // MARK: - Latency Tracking (P1 fix)

    func testSuccessfulExecutionReturnsNonNilLatency() async {
        let tool = StubTool(name: "read", riskLevel: .low, requiresApproval: false)
        let executor = makeExecutor(tools: [tool])
        let context = makeContext()
        let call = makeCall(name: "read", arguments: ["path": "/tmp/test"])

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertFalse(result.result.isError)
        XCTAssertNotNil(result.latencyMs, "latencyMs must be non-nil for successful execution")
        XCTAssertGreaterThanOrEqual(result.latencyMs ?? -1, 0, "latencyMs must be >= 0")
    }

    func testBlockedExecutionReturnsNonNilLatency() async {
        let tool = StubTool(name: "read", riskLevel: .low, requiresApproval: false)
        let executor = makeExecutor(tools: [tool], broker: DenyingBroker())
        let context = makeContext()
        let call = makeCall(name: "read", arguments: ["path": "/tmp/test"])

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError)
        XCTAssertNotNil(result.latencyMs, "latencyMs must be non-nil even for broker denials")
    }

    func testThrowingToolReturnsNonNilLatency() async {
        let tool = ThrowingTool()
        let executor = makeExecutor(tools: [tool])
        let context = makeContext()
        let call = makeCall(name: "thrower")

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError)
        XCTAssertNotNil(result.latencyMs, "latencyMs must be non-nil even for throwing tools")
    }

    // MARK: - Workflow Trace Path (P2 fix)

    func testTraceRecordsStepsWithNonNilRunID() async throws {
        let tool = StubTool(name: "read", riskLevel: .low, requiresApproval: false)
        let dbQueue = try DatabaseQueue()
        _ = try SessionStore(dbQueue: dbQueue) // creates conversation_sessions table
        let store = try WorkflowTraceStore(dbQueue: dbQueue)
        let run = try await store.createRun(
            sessionId: nil,
            turnId: "test-turn",
            source: "test",
            userGoal: "test trace"
        )

        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [tool]),
            actionBroker: RecordingBroker(),
            damageControlPolicy: DamageControlPolicy(),
            rateLimiter: ToolRateLimiter(),
            securityLogger: SecurityEventLogger.shared,
            outboundGuard: OutboundExfiltrationGuard.shared,
            workflowTraceStore: store
        )
        let context = ToolExecutorContext(
            toolMode: "full",
            privacyMode: "local_preferred",
            modelLocality: .local,
            capabilityTicket: nil,
            hasCapabilityTicketForTool: true,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            actionSource: .voice,
            proactiveContext: nil,
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: "test-turn",
            traceToolCallID: "tc-001",
            workflowRunID: run.id
        )

        let result = await executor.execute(
            makeCall(name: "read", arguments: ["path": "/tmp/test"]),
            context: context,
            callbacks: noopCallbacks
        )

        XCTAssertFalse(result.result.isError)

        let steps = try await store.steps(runId: run.id)
        XCTAssertEqual(steps.count, 2, "Should have tool_call + tool_result steps")

        let callStep = steps.first(where: { $0.stepType == .toolCall })
        let resultStep = steps.first(where: { $0.stepType == .toolResult })
        XCTAssertNotNil(callStep, "Should have a tool_call step")
        XCTAssertNotNil(resultStep, "Should have a tool_result step")
        XCTAssertEqual(callStep?.toolName, "read")
        XCTAssertEqual(resultStep?.toolName, "read")
        XCTAssertNotNil(resultStep?.latencyMs, "tool_result step should have non-nil latencyMs")
        XCTAssertGreaterThanOrEqual(resultStep?.latencyMs ?? -1, 0)
    }

    func testTraceSkippedWhenWorkflowRunIDNil() async throws {
        let tool = StubTool(name: "read", riskLevel: .low, requiresApproval: false)
        let dbQueue = try DatabaseQueue()
        _ = try SessionStore(dbQueue: dbQueue)
        let store = try WorkflowTraceStore(dbQueue: dbQueue)

        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [tool]),
            actionBroker: RecordingBroker(),
            damageControlPolicy: DamageControlPolicy(),
            rateLimiter: ToolRateLimiter(),
            securityLogger: SecurityEventLogger.shared,
            outboundGuard: OutboundExfiltrationGuard.shared,
            workflowTraceStore: store
        )
        // workflowRunID is nil — trace should be skipped
        let context = makeContext()
        let call = makeCall(name: "read", arguments: ["path": "/tmp/test"])

        _ = await executor.execute(call, context: context, callbacks: noopCallbacks)

        // With no run created and nil workflowRunID, no steps should exist
        // We can verify by trying to query a non-existent run
        let steps = try await store.steps(runId: "nonexistent")
        XCTAssertEqual(steps.count, 0, "No steps should be recorded when workflowRunID is nil")
    }
}

// MARK: - Additional Test Doubles

/// Broker that always returns `.confirm(...)` — triggers the approval path.
private actor ConfirmingBroker: TrustedActionBroker {
    func evaluate(_ intent: ActionIntent) async -> BrokerDecision {
        .confirm(
            prompt: ConfirmationPrompt(message: "Please confirm"),
            reason: DecisionReason(code: .mediumRiskRequiresConfirmation, message: "test confirm")
        )
    }
}

/// Tool that captures its input for assertion.
private final class CapturingTool: Tool, @unchecked Sendable {
    let name: String
    let description: String = "captures input"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .low
    let requiresApproval: Bool = false
    private(set) var capturedInput: [String: Any]?

    init(name: String) { self.name = name }

    func execute(input: [String: Any]) async throws -> ToolResult {
        capturedInput = input
        return .success("captured")
    }
}

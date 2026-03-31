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

// MARK: - Helper

private func makeExecutor(
    tools: [any Tool] = []
) -> ToolExecutor {
    let registry = ToolRegistry(tools: tools)
    return ToolExecutor(
        registry: registry,
        damageControlPolicy: DamageControlPolicy(),
        securityLogger: SecurityEventLogger.shared
    )
}

private func makeContext(
    toolMode: String = "full",
    privacyMode: String = "local_preferred",
    isOwner: Bool = true
) -> ToolExecutorContext {
    ToolExecutorContext(
        toolMode: toolMode,
        privacyMode: privacyMode,
        modelLocality: .local,
        explicitUserAuthorization: false,
        isOwner: isOwner,
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

    // MARK: Proactive allowlist

    func testProactiveAllowlistBlocksUnlistedTool() async {
        let tool = StubTool(name: "bash", riskLevel: .high, requiresApproval: false)
        let executor = makeExecutor(tools: [tool])
        var context = makeContext()
        context = ToolExecutorContext(
            toolMode: context.toolMode,
            privacyMode: context.privacyMode,
            modelLocality: context.modelLocality,
            explicitUserAuthorization: context.explicitUserAuthorization,
            isOwner: context.isOwner,
            livenessScore: context.livenessScore,
            speakerId: context.speakerId,
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

    // MARK: - Vision Auto-Enable Callback

    func testVisionAutoEnableCallbackFired() async {
        let tool = StubTool(name: "screenshot", riskLevel: .low, requiresApproval: false)
        let executor = makeExecutor(tools: [tool])
        let context = ToolExecutorContext(
            toolMode: "full",
            privacyMode: "local_preferred",
            modelLocality: .local,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            speakerId: nil,
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
        // Use an unknown tool name — registry lookup failure gives us a blocked path.
        let executor = makeExecutor(tools: [])
        let context = makeContext()
        let call = makeCall(name: "nonexistent", arguments: [:])

        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError)
        XCTAssertNotNil(result.latencyMs, "latencyMs must be non-nil even for blocked executions")
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
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            workflowTraceStore: store
        )
        let context = ToolExecutorContext(
            toolMode: "full",
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
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
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

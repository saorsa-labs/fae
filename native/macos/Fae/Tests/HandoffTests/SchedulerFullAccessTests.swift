import XCTest
@testable import Fae

/// Verify that scheduler tasks get full tool access without per-task allowlists
/// blocking them. The simplified model treats scheduler-originated tasks as
/// owner-initiated (isOwner=true set by PipelineCoordinator).
///
/// Key behaviors:
/// - Scheduler tasks with proactive context execute allowed tools
/// - Scheduler tasks auto-approve because isOwner=true in pipeline context
/// - DamageControlPolicy still catches catastrophic ops even for scheduler
final class SchedulerFullAccessTests: XCTestCase {

    // MARK: - Test Doubles

    private struct PassthroughTool: Tool {
        let name: String
        let description: String = "stub"
        let parametersSchema: String = "{}"
        let riskLevel: ToolRiskLevel
        let requiresApproval: Bool = false

        func execute(input: [String: Any]) async throws -> ToolResult {
            .success("ok:\(name)")
        }
    }

    // MARK: - Helpers

    private func makeExecutor(toolNames: [String]) -> ToolExecutor {
        let tools: [any Tool] = toolNames.map {
            PassthroughTool(name: $0, riskLevel: $0 == "bash" ? .high : .low)
        }
        return ToolExecutor(
            registry: ToolRegistry(tools: tools),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonIntendedForToolhostRouting: false
        )
    }

    private func schedulerContext(
        taskId: String,
        allowedTools: Set<String>
    ) -> ToolExecutorContext {
        ToolExecutorContext(
            toolMode: "full",
            privacyMode: "local_preferred",
            modelLocality: .local,
            explicitUserAuthorization: false,
            isOwner: true, // PipelineCoordinator sets isOwner=true for scheduler tasks
            livenessScore: nil,
            speakerId: nil,
            actionSource: .scheduler,
            proactiveContext: PipelineCoordinator.ProactiveRequestContext(
                source: .scheduler,
                taskId: taskId,
                allowedTools: allowedTools,
                consentGranted: false,
                conversationTag: "scheduler-\(taskId)"
            ),
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

    // MARK: - Scheduler Tool Access

    func testSchedulerTaskExecutesAllowedToolsWithoutGates() async {
        let executor = makeExecutor(toolNames: [
            "activate_skill", "run_skill", "self_config",
            "read", "write", "web_search",
        ])
        let context = schedulerContext(
            taskId: "improvement_cycle",
            allowedTools: ["activate_skill", "run_skill", "self_config", "read", "write", "web_search"]
        )

        for toolName in ["activate_skill", "run_skill", "self_config", "read"] {
            let call = ToolCall(name: toolName, arguments: [:])
            let result = await executor.execute(call, context: context, callbacks: noopCallbacks)
            XCTAssertFalse(
                result.result.isError,
                "Scheduler task should execute '\(toolName)' without gates, got: \(result.result.output)"
            )
            XCTAssertFalse(result.damageControlIntervened)
        }
    }

    func testSchedulerTaskBlockedByProactiveAllowlistForUnlistedTool() async {
        let executor = makeExecutor(toolNames: ["bash", "read", "self_config"])
        let context = schedulerContext(
            taskId: "memory_reflect",
            allowedTools: ["read", "self_config"]
        )

        let call = ToolCall(name: "bash", arguments: ["command": "echo test"])
        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError, "Scheduler task should not use tools outside its allowlist")
        XCTAssertTrue(result.result.output.contains("not allowed for proactive"))
    }

    // MARK: - DamageControlPolicy Still Active for Scheduler

    func testSchedulerTaskStillBlockedByDamageControl() async {
        let executor = makeExecutor(toolNames: ["bash"])
        let context = schedulerContext(
            taskId: "overnight_work",
            allowedTools: ["bash", "read", "write"]
        )

        let call = ToolCall(name: "bash", arguments: ["command": "rm -rf /"])
        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError, "DamageControlPolicy should block 'rm -rf /' even for scheduler")
        XCTAssertTrue(result.damageControlIntervened)
    }

    func testSchedulerTaskDiskFormatBlocked() async {
        let executor = makeExecutor(toolNames: ["bash"])
        let context = schedulerContext(
            taskId: "improvement_cycle",
            allowedTools: ["bash"]
        )

        let call = ToolCall(name: "bash", arguments: ["command": "mkfs.ext4 /dev/sda"])
        let result = await executor.execute(call, context: context, callbacks: noopCallbacks)

        XCTAssertTrue(result.result.isError, "DamageControlPolicy should block disk format for scheduler")
        XCTAssertTrue(result.damageControlIntervened)
    }

    // MARK: - Safe Bash Commands Pass for Scheduler

    func testSchedulerTaskRunsSafeBashCommands() async {
        let executor = makeExecutor(toolNames: ["bash"])
        let context = schedulerContext(
            taskId: "memory_backup",
            allowedTools: ["bash", "read"]
        )

        let safeCmds = ["echo hello", "ls -la /tmp", "swift build --version"]
        for cmd in safeCmds {
            let call = ToolCall(name: "bash", arguments: ["command": cmd])
            let result = await executor.execute(call, context: context, callbacks: noopCallbacks)
            XCTAssertFalse(
                result.result.isError,
                "Scheduler should run safe bash '\(cmd)', got: \(result.result.output)"
            )
        }
    }

    // MARK: - Owner Flag Verification

    func testSchedulerContextIsOwnerTrue() {
        let context = schedulerContext(taskId: "test", allowedTools: ["read"])
        XCTAssertTrue(context.isOwner, "Scheduler context must have isOwner=true")
        XCTAssertEqual(context.actionSource, .scheduler)
    }
}

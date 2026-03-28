import XCTest
@testable import Fae

// MARK: - Test Doubles

private struct CountingTool: Tool {
    let name: String
    let description: String = "counting tool"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .low
    let requiresApproval: Bool = false

    /// Shared counter to track actual executions.
    let counter: ExecutionCounter

    func execute(input: [String: Any]) async throws -> ToolResult {
        counter.increment()
        let count = counter.count
        return .success("{\"count\":\(count)}")
    }
}

private final class ExecutionCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fae.test.counter")
    private var _count = 0

    var count: Int { queue.sync { _count } }

    func increment() {
        queue.sync { _count += 1 }
    }

    func reset() {
        queue.sync { _count = 0 }
    }
}

private struct StatefulWriteTool: Tool {
    let name: String = "write"
    let description: String = "writes to a path"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .medium
    let requiresApproval: Bool = false

    let writtenPaths: WrittenPathsCollector

    func execute(input: [String: Any]) async throws -> ToolResult {
        if let path = input["path"] as? String {
            writtenPaths.add(path)
        }
        return .success("written")
    }
}

private final class WrittenPathsCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fae.test.paths")
    private var _paths: [String] = []

    var paths: [String] { queue.sync { _paths } }

    func add(_ path: String) {
        queue.sync { _paths.append(path) }
    }
}

private actor AllowBroker: TrustedActionBroker {
    func evaluate(_ intent: ActionIntent) async -> BrokerDecision {
        .allow(reason: DecisionReason(code: .allowLowRisk, message: "test allow"))
    }
}

private func makeRuntime(
    tools: [any Tool] = [],
    ticketManager: ScriptScopedTicketManager? = nil
) -> JSCRuntime {
    let registry = ToolRegistry(tools: tools)
    let executor = ToolExecutor(
        registry: registry,
        actionBroker: AllowBroker(),
        damageControlPolicy: DamageControlPolicy(),
        rateLimiter: ToolRateLimiter(),
        securityLogger: SecurityEventLogger.shared,
        outboundGuard: OutboundExfiltrationGuard.shared
    )

    return JSCRuntime(
        executor: executor,
        contextFactory: {
            ToolExecutorContext(
                toolMode: "full",
                privacyMode: "local_preferred",
                modelLocality: .local,
                capabilityTicket: nil,
                hasCapabilityTicketForTool: true,
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
        },
        callbacksFactory: {
            ToolExecutorCallbacks(
                onApprovalPending: { _, _ in },
                onVisionAutoEnabled: { },
                onComputerUseStep: { 1 }
            )
        },
        ticketManager: ticketManager
    )
}

// MARK: - End-to-End Tests

final class JSCEndToEndTests: XCTestCase {

    // MARK: - Full Script Lifecycle

    func testScriptExecutesToolsAndReturnsCompositeResult() async {
        let counter = ExecutionCounter()
        let tool = CountingTool(name: "read", counter: counter)
        let runtime = makeRuntime(tools: [tool])

        let result = await runtime.run(script: """
            var r1 = await fae.tool('read', '{}');
            var r2 = await fae.tool('read', '{}');
            var r3 = await fae.tool('read', '{}');
            return 'total: ' + r1 + ',' + r2 + ',' + r3;
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(counter.count, 3, "Expected 3 actual tool executions")
        XCTAssertNotNil(result.value)
    }

    func testDryRunDoesNotExecuteTools() async {
        let counter = ExecutionCounter()
        let tool = CountingTool(name: "read", counter: counter)
        let runtime = makeRuntime(tools: [tool])

        let plan = await runtime.runDryRun(script: """
            var r1 = await fae.tool('read', '{}');
            var r2 = await fae.tool('read', '{}');
            return 'done';
        """)

        XCTAssertEqual(plan.intendedCalls.count, 2, "Dry run should record 2 calls")
        XCTAssertEqual(counter.count, 0, "Dry run should NOT execute tools")
        XCTAssertEqual(plan.scriptResult.status, .success)
    }

    func testRealRunAfterDryRunExecutesTools() async {
        let counter = ExecutionCounter()
        let tool = CountingTool(name: "read", counter: counter)
        let runtime = makeRuntime(tools: [tool])

        // Dry run first — should not execute.
        let plan = await runtime.runDryRun(script: """
            await fae.tool('read', '{}');
            return 'preview';
        """)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(plan.intendedCalls.count, 1)

        // Real run — should execute.
        let result = await runtime.run(script: """
            await fae.tool('read', '{}');
            return 'executed';
        """)
        XCTAssertEqual(counter.count, 1, "Real run should execute the tool")
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "executed")
    }

    // MARK: - Budget Enforcement E2E

    func testBudgetEnforcementPreventsExcessiveCalls() async {
        let counter = ExecutionCounter()
        let tool = CountingTool(name: "read", counter: counter)
        let runtime = makeRuntime(tools: [tool])

        let budget = ScriptBudget(maxToolCalls: 2, maxWallClockSeconds: 30, maxConcurrentToolCalls: 5)
        let result = await runtime.run(script: """
            try {
                await fae.tool('read', '{}');
                await fae.tool('read', '{}');
                await fae.tool('read', '{}');
                return 'should not reach';
            } catch(e) {
                return 'stopped: ' + e.message;
            }
        """, budget: budget)

        XCTAssertEqual(result.status, .success)
        XCTAssertTrue(result.value?.contains("stopped") == true)
        XCTAssertEqual(counter.count, 2, "Only 2 calls should execute before budget stops the 3rd")
    }

    // MARK: - Script Isolation

    func testConsecutiveRunsDoNotLeakState() async {
        let runtime = makeRuntime()

        let r1 = await runtime.run(script: """
            globalThis.__secret = 'sensitive_data';
            return 'set';
        """)
        XCTAssertEqual(r1.status, .success)

        let r2 = await runtime.run(script: """
            return typeof globalThis.__secret === 'undefined' ? 'clean' : 'leaked';
        """)
        XCTAssertEqual(r2.status, .success)
        XCTAssertEqual(r2.value, "clean", "State should not leak between runs")
    }

    func testDryRunDoesNotLeakToRealRun() async {
        let runtime = makeRuntime()

        // Dry run sets a global.
        let plan = await runtime.runDryRun(script: """
            globalThis.__dryRunFlag = true;
            return 'dry';
        """)
        XCTAssertEqual(plan.scriptResult.status, .success)

        // Real run should not see it.
        let result = await runtime.run(script: """
            return typeof globalThis.__dryRunFlag === 'undefined' ? 'isolated' : 'leaked';
        """)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "isolated")
    }

    // MARK: - Error Recovery

    func testScriptErrorDoesNotBreakSubsequentRuns() async {
        let runtime = makeRuntime()

        // First run throws.
        let r1 = await runtime.run(script: "throw new Error('boom');")
        XCTAssertEqual(r1.status, .failure)

        // Second run should work fine.
        let r2 = await runtime.run(script: "return 'recovered';")
        XCTAssertEqual(r2.status, .success)
        XCTAssertEqual(r2.value, "recovered")
    }

    func testToolErrorDoesNotBreakScript() async {
        let counter = ExecutionCounter()
        let tool = CountingTool(name: "read", counter: counter)
        let runtime = makeRuntime(tools: [tool])

        let result = await runtime.run(script: """
            try {
                await fae.tool('nonexistent_tool', '{}');
            } catch(e) {
                fae.log('caught: ' + e.message);
            }
            var r = await fae.tool('read', '{}');
            return 'ok: ' + r;
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(result.logs.first?.contains("caught") == true)
    }

    // MARK: - Cancellation E2E

    func testCancellationStopsScript() async {
        let counter = ExecutionCounter()
        let tool = CountingTool(name: "read", counter: counter)
        let runtime = makeRuntime(tools: [tool])

        async let resultTask = runtime.run(script: """
            await fae.tool('read', '{}');
            await fae.sleep(5000);
            await fae.tool('read', '{}');
            return 'should not complete';
        """, budget: ScriptBudget(maxToolCalls: 10, maxWallClockSeconds: 60, maxConcurrentToolCalls: 5))

        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
        await runtime.cancelCurrent()

        let result = await resultTask
        XCTAssertTrue(
            result.status == .cancelled || result.status == .budgetExceeded,
            "Expected cancelled status, got \(result.status)"
        )
    }

    // MARK: - Parsing + Execution Round-Trip

    func testParsedScriptBlockExecutesThroughRuntime() async {
        let text = """
        <tool_program>
        fae.log('hello from script');
        return 42;
        </tool_program>
        """

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)

        let runtime = makeRuntime()
        let result = await runtime.run(
            script: blocks[0].source,
            budget: blocks[0].budget ?? .default,
            allowedTools: blocks[0].allowedTools
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "42")
        XCTAssertEqual(result.logs, ["hello from script"])
    }

    func testParsedScriptWithMetaAppliesBudget() async {
        let text = """
        <tool_program_meta>{"max_tool_calls":1}</tool_program_meta>
        <tool_program>
        fae.log('starting');
        return 'ok';
        </tool_program>
        """

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].budget?.maxToolCalls, 1)

        let runtime = makeRuntime()
        let result = await runtime.run(
            script: blocks[0].source,
            budget: blocks[0].budget ?? .default,
            allowedTools: blocks[0].allowedTools
        )

        XCTAssertEqual(result.status, .success)
    }

    // MARK: - Dry Run Plan Summary E2E

    func testDryRunPlanSummaryIsReadable() async {
        let counter = ExecutionCounter()
        let tool = CountingTool(name: "read", counter: counter)
        let runtime = makeRuntime(tools: [tool])

        let plan = await runtime.runDryRun(script: """
            await fae.tool('read', '{"path":"/etc/hosts"}');
            await fae.tool('read', '{"path":"/tmp/data.json"}');
            return 'processed';
        """)

        let summary = plan.summary()
        XCTAssertTrue(summary.contains("2 tool calls"), "Summary: \(summary)")
        XCTAssertTrue(summary.contains("/etc/hosts"), "Summary should show path: \(summary)")
        XCTAssertTrue(summary.contains("/tmp/data.json"), "Summary should show path: \(summary)")

        let brief = plan.briefSummary()
        XCTAssertTrue(brief.contains("2 tool calls"), "Brief: \(brief)")
        XCTAssertTrue(brief.contains("read"), "Brief: \(brief)")
    }

    // MARK: - Write Tool Dry Run vs Real Run

    func testDryRunWriteToolDoesNotActuallyWrite() async {
        let paths = WrittenPathsCollector()
        let tool = StatefulWriteTool(writtenPaths: paths)
        let runtime = makeRuntime(tools: [tool])

        // Dry run.
        let plan = await runtime.runDryRun(script: """
            await fae.tool('write', '{"path":"/tmp/secret","content":"data"}');
            return 'planned';
        """)
        XCTAssertEqual(plan.intendedCalls.count, 1)
        XCTAssertTrue(paths.paths.isEmpty, "Dry run should not write")

        // Real run.
        let result = await runtime.run(script: """
            await fae.tool('write', '{"path":"/tmp/test","content":"data"}');
            return 'written';
        """)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(paths.paths, ["/tmp/test"], "Real run should write")
    }
}

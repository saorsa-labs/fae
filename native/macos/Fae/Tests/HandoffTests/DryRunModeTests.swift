import XCTest
@testable import Fae

// MARK: - Test Doubles

private struct EchoTool: Tool {
    let name: String
    let description: String = "echoes input"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .low
    let requiresApproval: Bool = false

    func execute(input: [String: Any]) async throws -> ToolResult {
        if let data = try? JSONSerialization.data(withJSONObject: input),
           let json = String(data: data, encoding: .utf8)
        {
            return .success(json)
        }
        return .success("{}")
    }
}

private func makeRuntime(tools: [any Tool] = []) -> JSCRuntime {
    let registry = ToolRegistry(tools: tools)
    let executor = ToolExecutor(
        registry: registry,
        damageControlPolicy: DamageControlPolicy(),
        securityLogger: SecurityEventLogger.shared,
        daemonIntendedForToolhostRouting: false
    )

    return JSCRuntime(
        executor: executor,
        contextFactory: {
            ToolExecutorContext(
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
                workflowTurnID: nil,
                traceToolCallID: nil,
                workflowRunID: nil
            )
        },
        callbacksFactory: {
            .noop
        }
    )
}

// MARK: - Dry-Run Mode Tests

final class DryRunModeTests: XCTestCase {

    // MARK: - Basic Dry-Run

    func testDryRunRecordsToolCallsWithoutExecuting() async {
        let runtime = makeRuntime(tools: [EchoTool(name: "read")])

        let plan = await runtime.runDryRun(script: """
            var r = await fae.tool('read', '{"path":"/tmp/test"}');
            return 'done';
        """)

        XCTAssertEqual(plan.intendedCalls.count, 1)
        XCTAssertEqual(plan.intendedCalls[0].toolName, "read")
        XCTAssertTrue(plan.intendedCalls[0].argumentsJSON.contains("/tmp/test"))
        XCTAssertEqual(plan.intendedCalls[0].callIndex, 0)
        XCTAssertEqual(plan.scriptResult.status, .success)
    }

    func testDryRunReturnsSyntheticResults() async {
        let runtime = makeRuntime()

        let plan = await runtime.runDryRun(script: """
            var r = await fae.tool('write', '{"path":"/tmp/out","content":"hello"}');
            fae.log('result: ' + r);
            return r;
        """)

        XCTAssertEqual(plan.scriptResult.status, .success)
        // Dry-run now returns a valid JSON envelope so typed adapters work.
        XCTAssertTrue(plan.scriptResult.value?.contains("dry-run") == true)
        XCTAssertTrue(plan.scriptResult.logs.first?.contains("dry-run") == true)
    }

    func testDryRunRecordsMultipleCallsInOrder() async {
        let runtime = makeRuntime()

        let plan = await runtime.runDryRun(script: """
            await fae.tool('read', '{"path":"a"}');
            await fae.tool('write', '{"path":"b","content":"x"}');
            await fae.tool('bash', '{"command":"echo hi"}');
            return 'done';
        """)

        XCTAssertEqual(plan.intendedCalls.count, 3)
        XCTAssertEqual(plan.intendedCalls[0].toolName, "read")
        XCTAssertEqual(plan.intendedCalls[0].callIndex, 0)
        XCTAssertEqual(plan.intendedCalls[1].toolName, "write")
        XCTAssertEqual(plan.intendedCalls[1].callIndex, 1)
        XCTAssertEqual(plan.intendedCalls[2].toolName, "bash")
        XCTAssertEqual(plan.intendedCalls[2].callIndex, 2)
    }

    func testDryRunDoesNotMutateState() async {
        // Verify that dry-run doesn't actually write files.
        let runtime = makeRuntime(tools: [EchoTool(name: "write")])

        let testPath = "/tmp/fae-dryrun-test-\(UUID().uuidString)"
        let plan = await runtime.runDryRun(script: """
            await fae.tool('write', '{"path":"\(testPath)","content":"should not exist"}');
            return 'done';
        """)

        XCTAssertEqual(plan.intendedCalls.count, 1)
        XCTAssertEqual(plan.scriptResult.status, .success)
        // The file should NOT exist because dry-run doesn't execute tools.
        XCTAssertFalse(FileManager.default.fileExists(atPath: testPath))
    }

    func testDryRunScriptErrorStillRecordsCalls() async {
        let runtime = makeRuntime()

        let plan = await runtime.runDryRun(script: """
            await fae.tool('read', '{"path":"before-error"}');
            throw new Error('planned error');
        """)

        // Should record the call made before the error.
        XCTAssertEqual(plan.intendedCalls.count, 1)
        XCTAssertEqual(plan.intendedCalls[0].toolName, "read")
        XCTAssertEqual(plan.scriptResult.status, .failure)
        XCTAssertTrue(plan.scriptResult.error?.contains("planned error") == true)
    }

    func testDryRunNoToolCalls() async {
        let runtime = makeRuntime()

        let plan = await runtime.runDryRun(script: """
            return 'just a value';
        """)

        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.scriptResult.status, .success)
        XCTAssertEqual(plan.scriptResult.value, "just a value")
    }

    func testDryRunSleepIsInstant() async {
        let runtime = makeRuntime()
        let start = Date()

        let plan = await runtime.runDryRun(script: """
            await fae.sleep(10000);
            return 'slept';
        """)

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(plan.scriptResult.status, .success)
        XCTAssertEqual(plan.scriptResult.value, "slept")
        // Sleep should be instant in dry-run mode (< 2s, not 10s).
        XCTAssertLessThan(elapsed, 2.0, "Sleep should be instant in dry-run, took \(elapsed)s")
    }

    // MARK: - DryRunPlan Properties

    func testDryRunPlanIsEmpty() {
        let empty = DryRunPlan(intendedCalls: [], scriptResult: .success(value: nil))
        XCTAssertTrue(empty.isEmpty)

        let nonEmpty = DryRunPlan(
            intendedCalls: [DryRunIntendedCall(toolName: "read", argumentsJSON: "{}", callIndex: 0)],
            scriptResult: .success(value: nil)
        )
        XCTAssertFalse(nonEmpty.isEmpty)
    }

    func testDryRunPlanUniqueToolCount() {
        let plan = DryRunPlan(
            intendedCalls: [
                DryRunIntendedCall(toolName: "read", argumentsJSON: "{}", callIndex: 0),
                DryRunIntendedCall(toolName: "write", argumentsJSON: "{}", callIndex: 1),
                DryRunIntendedCall(toolName: "read", argumentsJSON: "{}", callIndex: 2),
            ],
            scriptResult: .success(value: nil)
        )
        XCTAssertEqual(plan.uniqueToolCount, 2)
    }

    // MARK: - Plan Summary

    func testPlanSummaryWithCalls() {
        let plan = DryRunPlan(
            intendedCalls: [
                DryRunIntendedCall(toolName: "read", argumentsJSON: "{\"path\":\"/tmp/a\"}", callIndex: 0),
                DryRunIntendedCall(toolName: "bash", argumentsJSON: "{\"command\":\"echo hello\"}", callIndex: 1),
            ],
            scriptResult: .success(value: nil)
        )

        let summary = plan.summary()
        XCTAssertTrue(summary.contains("2 tool calls"), "Expected '2 tool calls' in: \(summary)")
        XCTAssertTrue(summary.contains("1. read: /tmp/a"), "Expected path preview in: \(summary)")
        XCTAssertTrue(summary.contains("2. bash: echo hello"), "Expected command preview in: \(summary)")
    }

    func testPlanSummaryWithNoCalls() {
        let plan = DryRunPlan(intendedCalls: [], scriptResult: .success(value: nil))
        let summary = plan.summary()
        XCTAssertTrue(summary.contains("not make any tool calls"), "Expected no-call message in: \(summary)")
    }

    func testPlanBriefSummary() {
        let plan = DryRunPlan(
            intendedCalls: [
                DryRunIntendedCall(toolName: "read", argumentsJSON: "{}", callIndex: 0),
                DryRunIntendedCall(toolName: "write", argumentsJSON: "{}", callIndex: 1),
                DryRunIntendedCall(toolName: "read", argumentsJSON: "{}", callIndex: 2),
            ],
            scriptResult: .success(value: nil)
        )

        let brief = plan.briefSummary()
        XCTAssertTrue(brief.contains("3 tool calls"), "Expected '3 tool calls' in: \(brief)")
        XCTAssertTrue(brief.contains("read"), "Expected 'read' in: \(brief)")
        XCTAssertTrue(brief.contains("write"), "Expected 'write' in: \(brief)")
    }

    func testPlanBriefSummaryNoCalls() {
        let plan = DryRunPlan(intendedCalls: [], scriptResult: .success(value: nil))
        let brief = plan.briefSummary()
        XCTAssertTrue(brief.contains("No tool calls planned"), "Expected no-call message in: \(brief)")
    }

    // MARK: - DryRunIntendedCall Equatable

    func testDryRunIntendedCallEquality() {
        let a = DryRunIntendedCall(toolName: "read", argumentsJSON: "{}", callIndex: 0)
        let b = DryRunIntendedCall(toolName: "read", argumentsJSON: "{}", callIndex: 0)
        let c = DryRunIntendedCall(toolName: "write", argumentsJSON: "{}", callIndex: 0)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testDryRunPlanEquality() {
        let a = DryRunPlan(intendedCalls: [], scriptResult: .success(value: "x"))
        let b = DryRunPlan(intendedCalls: [], scriptResult: .success(value: "x"))
        let c = DryRunPlan(intendedCalls: [], scriptResult: .failure(error: "e"))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Argument Preview in Summary

    func testPlanSummaryShowsQueryArgument() {
        let plan = DryRunPlan(
            intendedCalls: [
                DryRunIntendedCall(toolName: "web_search", argumentsJSON: "{\"query\":\"swift programming\"}", callIndex: 0),
            ],
            scriptResult: .success(value: nil)
        )

        let summary = plan.summary()
        XCTAssertTrue(summary.contains("swift programming"), "Expected query in: \(summary)")
    }

    func testPlanSummaryShowsActionArgument() {
        let plan = DryRunPlan(
            intendedCalls: [
                DryRunIntendedCall(toolName: "calendar", argumentsJSON: "{\"action\":\"list_today\"}", callIndex: 0),
            ],
            scriptResult: .success(value: nil)
        )

        let summary = plan.summary()
        XCTAssertTrue(summary.contains("list_today"), "Expected action in: \(summary)")
    }
}

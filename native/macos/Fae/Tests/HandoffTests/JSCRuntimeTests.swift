import XCTest
@testable import Fae

// MARK: - Test Doubles

/// A tool that succeeds with a fixed JSON result.
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

/// A tool that always returns an error.
private struct FailingTool: Tool {
    let name: String
    let description: String = "always fails"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .low
    let requiresApproval: Bool = false

    func execute(input: [String: Any]) async throws -> ToolResult {
        .error("tool_failed: intentional test error")
    }
}

/// A tool that sleeps for a configurable duration before returning.
private struct SlowTool: Tool {
    let name: String
    let description: String = "sleeps then succeeds"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .low
    let requiresApproval: Bool = false

    /// How long to sleep in seconds.
    let delaySeconds: TimeInterval

    func execute(input: [String: Any]) async throws -> ToolResult {
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        return .success("slow_done")
    }
}

/// Broker that always allows.
private actor AllowBroker: TrustedActionBroker {
    func evaluate(_ intent: ActionIntent) async -> BrokerDecision {
        .allow(reason: DecisionReason(code: .allowLowRisk, message: "test allow"))
    }
}

// MARK: - Helpers

private func makeRuntime(
    tools: [any Tool] = [],
    broker: any TrustedActionBroker = AllowBroker()
) -> JSCRuntime {
    let registry = ToolRegistry(tools: tools)
    let executor = ToolExecutor(
        registry: registry,
        actionBroker: broker,
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
        }
    )
}

// MARK: - Tests

final class JSCRuntimeTests: XCTestCase {

    // MARK: - Basic Script Execution

    func testSimpleReturnValue() async {
        let runtime = makeRuntime()
        let result = await runtime.run(script: "return 42;")

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "42")
        XCTAssertNil(result.error)
    }

    func testStringReturnValue() async {
        let runtime = makeRuntime()
        let result = await runtime.run(script: "return 'hello world';")

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "hello world")
    }

    func testUndefinedReturnValue() async {
        let runtime = makeRuntime()
        let result = await runtime.run(script: "// no return")

        XCTAssertEqual(result.status, .success)
        XCTAssertNil(result.value)
    }

    func testObjectReturnValue() async {
        let runtime = makeRuntime()
        let result = await runtime.run(script: "return { key: 'value', num: 123 };")

        XCTAssertEqual(result.status, .success)
        XCTAssertNotNil(result.value)
        // The value should be valid JSON.
        if let data = result.value?.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            XCTAssertEqual(parsed["key"] as? String, "value")
            XCTAssertEqual(parsed["num"] as? Int, 123)
        } else {
            XCTFail("Expected JSON object in result value, got: \(result.value ?? "nil")")
        }
    }

    // MARK: - Logging

    func testFaeLogCapturesMessages() async {
        let runtime = makeRuntime()
        let result = await runtime.run(script: """
            fae.log('first');
            fae.log('second');
            return 'done';
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.logs, ["first", "second"])
    }

    // MARK: - Script Errors

    func testSyntaxErrorReportsFailure() async {
        let runtime = makeRuntime()
        let result = await runtime.run(script: "function {{{ invalid")

        XCTAssertEqual(result.status, .failure)
        XCTAssertNotNil(result.error)
    }

    func testThrowReportsFailure() async {
        let runtime = makeRuntime()
        let result = await runtime.run(script: "throw new Error('test error');")

        XCTAssertEqual(result.status, .failure)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error?.contains("test error") == true, "Expected 'test error' in: \(result.error ?? "")")
    }

    // MARK: - Tool Calls via Bridge

    func testSuccessfulToolCall() async {
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo])

        let result = await runtime.run(script: """
            var res = await fae.tool('read', '{"path":"/tmp/test"}');
            fae.log('got: ' + res);
            return res;
        """)

        XCTAssertEqual(result.status, .success, "Script should succeed, error: \(result.error ?? "none")")
        XCTAssertNotNil(result.value)
        XCTAssertTrue(result.logs.first?.contains("got:") == true)
    }

    func testRejectedToolCallIsCatchable() async {
        let failing = FailingTool(name: "read")
        let runtime = makeRuntime(tools: [failing])

        let result = await runtime.run(script: """
            try {
                await fae.tool('read', '{"path":"/tmp/fail"}');
                return 'should not reach';
            } catch(e) {
                fae.log('caught: ' + e.message);
                return 'caught';
            }
        """)

        XCTAssertEqual(result.status, .success, "Script should succeed via catch, error: \(result.error ?? "none")")
        XCTAssertEqual(result.value, "caught")
        XCTAssertTrue(result.logs.first?.contains("caught:") == true)
    }

    func testUnknownToolRejectsPromise() async {
        let runtime = makeRuntime(tools: [])

        let result = await runtime.run(script: """
            try {
                await fae.tool('nonexistent', '{}');
                return 'should not reach';
            } catch(e) {
                return 'rejected';
            }
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "rejected")
    }

    // MARK: - Multiple Tool Calls

    func testSequentialToolCalls() async {
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo])

        let result = await runtime.run(script: """
            var r1 = await fae.tool('read', '{"path":"a"}');
            var r2 = await fae.tool('read', '{"path":"b"}');
            fae.log('calls done');
            return 'ok';
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "ok")
        XCTAssertEqual(result.logs, ["calls done"])
    }

    // MARK: - Sleep

    func testFaeSleepResolves() async {
        let runtime = makeRuntime()

        let result = await runtime.run(script: """
            await fae.sleep(10);
            return 'slept';
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "slept")
    }

    // MARK: - Runtime Isolation

    func testMultipleRunsAreIsolated() async {
        let runtime = makeRuntime()

        // First run sets a global variable.
        let r1 = await runtime.run(script: """
            globalThis.__test = 'leak';
            return 'set';
        """)
        XCTAssertEqual(r1.status, .success)

        // Second run should NOT see the variable from the first.
        let r2 = await runtime.run(script: """
            return typeof globalThis.__test === 'undefined' ? 'isolated' : 'leaked';
        """)
        XCTAssertEqual(r2.status, .success)
        XCTAssertEqual(r2.value, "isolated")
    }

    // MARK: - JSCScriptResult

    func testScriptResultFactories() {
        let success = JSCScriptResult.success(value: "42", logs: ["a"])
        XCTAssertEqual(success.status, .success)
        XCTAssertEqual(success.value, "42")
        XCTAssertEqual(success.logs, ["a"])
        XCTAssertNil(success.error)

        let failure = JSCScriptResult.failure(error: "boom", logs: ["b"])
        XCTAssertEqual(failure.status, .failure)
        XCTAssertNil(failure.value)
        XCTAssertEqual(failure.error, "boom")
        XCTAssertEqual(failure.logs, ["b"])

        let cancelled = JSCScriptResult.cancelled(logs: ["c"])
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertNil(cancelled.value)
        XCTAssertNotNil(cancelled.error)
        XCTAssertEqual(cancelled.logs, ["c"])
    }

    func testScriptResultEquality() {
        let a = JSCScriptResult.success(value: "42", logs: ["x"])
        let b = JSCScriptResult.success(value: "42", logs: ["x"])
        let c = JSCScriptResult.failure(error: "e")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testBudgetExceededResultFactory() {
        let result = JSCScriptResult.budgetExceeded(reason: "too many calls", logs: ["x"])
        XCTAssertEqual(result.status, .budgetExceeded)
        XCTAssertNil(result.value)
        XCTAssertEqual(result.error, "too many calls")
        XCTAssertEqual(result.logs, ["x"])
    }

    // MARK: - Script Budgets

    func testToolCallBudgetExceeded() async {
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo])

        // Budget allows only 2 tool calls, script tries 3.
        let budget = ScriptBudget(
            maxToolCalls: 2,
            maxWallClockSeconds: 30,
            maxConcurrentToolCalls: 5
        )

        let result = await runtime.run(script: """
            var results = [];
            try {
                results.push(await fae.tool('read', '{"n":1}'));
                results.push(await fae.tool('read', '{"n":2}'));
                results.push(await fae.tool('read', '{"n":3}'));
                return 'should not reach';
            } catch(e) {
                fae.log('budget error: ' + e.message);
                return 'caught';
            }
        """, budget: budget)

        // The script should catch the budget error from the 3rd call.
        XCTAssertEqual(result.status, .success, "Script catches budget error, error: \(result.error ?? "none")")
        XCTAssertEqual(result.value, "caught")
        XCTAssertTrue(
            result.logs.first?.contains("budget") == true || result.logs.first?.contains("tool-call") == true,
            "Expected budget error in logs, got: \(result.logs)"
        )
    }

    func testToolCallBudgetUncaughtSurfacesAsFailure() async {
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo])

        // Budget allows only 1 tool call, script makes 2 without catching.
        let budget = ScriptBudget(
            maxToolCalls: 1,
            maxWallClockSeconds: 30,
            maxConcurrentToolCalls: 5
        )

        let result = await runtime.run(script: """
            await fae.tool('read', '{"n":1}');
            await fae.tool('read', '{"n":2}');
            return 'should not reach';
        """, budget: budget)

        // Second call rejects, unhandled rejection causes script failure.
        XCTAssertEqual(result.status, .failure, "Uncaught budget error should fail the script")
        XCTAssertNotNil(result.error)
    }

    func testWallClockBudgetExceeded() async {
        let slow = SlowTool(name: "read", delaySeconds: 5)
        let runtime = makeRuntime(tools: [slow])

        // Budget allows only 1 second wall-clock time.
        let budget = ScriptBudget(
            maxToolCalls: 10,
            maxWallClockSeconds: 1,
            maxConcurrentToolCalls: 5
        )

        let result = await runtime.run(script: """
            fae.log('starting slow call');
            await fae.tool('read', '{}');
            return 'should not reach';
        """, budget: budget)

        // The runtime should detect the wall-clock expiry.
        XCTAssertEqual(result.status, .budgetExceeded, "Expected budgetExceeded, got \(result.status)")
        XCTAssertTrue(
            result.error?.contains("wall-clock") == true,
            "Expected wall-clock mention in error: \(result.error ?? "")"
        )
    }

    func testCooperativeCancellation() async {
        let slow = SlowTool(name: "read", delaySeconds: 10)
        let runtime = makeRuntime(tools: [slow])

        let budget = ScriptBudget(
            maxToolCalls: 10,
            maxWallClockSeconds: 60,
            maxConcurrentToolCalls: 5
        )

        // Launch the script and cancel it shortly after.
        async let resultTask = runtime.run(script: """
            fae.log('before slow call');
            await fae.tool('read', '{}');
            return 'should not reach';
        """, budget: budget)

        // Wait a short time, then signal cancellation.
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        await runtime.cancelCurrent()

        let result = await resultTask

        // Should be cancelled (cooperative cancellation detected by drain loop).
        XCTAssertTrue(
            result.status == .cancelled || result.status == .budgetExceeded,
            "Expected cancelled or budgetExceeded, got \(result.status)"
        )
    }

    func testConcurrencyLimitExceeded() async {
        let slow = SlowTool(name: "read", delaySeconds: 2)
        let runtime = makeRuntime(tools: [slow])

        // Allow only 1 concurrent tool call.
        let budget = ScriptBudget(
            maxToolCalls: 10,
            maxWallClockSeconds: 30,
            maxConcurrentToolCalls: 1
        )

        let result = await runtime.run(script: """
            // Launch two calls concurrently; second should be rejected.
            try {
                var results = await Promise.all([
                    fae.tool('read', '{"n":1}'),
                    fae.tool('read', '{"n":2}')
                ]);
                return 'both succeeded';
            } catch(e) {
                fae.log('concurrency error: ' + e.message);
                return 'caught';
            }
        """, budget: budget)

        // The second concurrent call should be rejected.
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "caught")
        XCTAssertTrue(
            result.logs.first?.contains("concurrent") == true,
            "Expected concurrency error in logs, got: \(result.logs)"
        )
    }

    func testDefaultBudgetAllowsNormalExecution() async {
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo])

        // Run with default budget — should succeed normally.
        let result = await runtime.run(script: """
            var r = await fae.tool('read', '{"path":"test"}');
            return 'ok';
        """)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "ok")
    }

    // MARK: - ScriptBudget

    func testScriptBudgetDefaults() {
        let d = ScriptBudget.default
        XCTAssertEqual(d.maxToolCalls, 20)
        XCTAssertEqual(d.maxWallClockSeconds, 120)
        XCTAssertEqual(d.maxConcurrentToolCalls, 5)

        let m = ScriptBudget.minimal
        XCTAssertEqual(m.maxToolCalls, 3)
        XCTAssertEqual(m.maxWallClockSeconds, 30)
        XCTAssertEqual(m.maxConcurrentToolCalls, 2)
    }

    func testScriptBudgetEquality() {
        let a = ScriptBudget(maxToolCalls: 5, maxWallClockSeconds: 10, maxConcurrentToolCalls: 2)
        let b = ScriptBudget(maxToolCalls: 5, maxWallClockSeconds: 10, maxConcurrentToolCalls: 2)
        let c = ScriptBudget(maxToolCalls: 3, maxWallClockSeconds: 10, maxConcurrentToolCalls: 2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - ScriptBudgetTracker

    func testBudgetTrackerToolCallCounting() {
        let budget = ScriptBudget(maxToolCalls: 2, maxWallClockSeconds: 60, maxConcurrentToolCalls: 5)
        let tracker = ScriptBudgetTracker(budget: budget)

        XCTAssertEqual(tracker.toolCallCount, 0)
        XCTAssertNil(tracker.tryStartToolCall())
        XCTAssertEqual(tracker.toolCallCount, 1)
        XCTAssertEqual(tracker.concurrentCount, 1)

        tracker.finishToolCall()
        XCTAssertEqual(tracker.concurrentCount, 0)

        XCTAssertNil(tracker.tryStartToolCall())
        XCTAssertEqual(tracker.toolCallCount, 2)

        // Third call should be rejected.
        let error = tracker.tryStartToolCall()
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("tool-call budget") == true, "Expected budget error, got: \(error ?? "")")
    }

    func testBudgetTrackerCancellation() {
        let budget = ScriptBudget(maxToolCalls: 10, maxWallClockSeconds: 60, maxConcurrentToolCalls: 5)
        let tracker = ScriptBudgetTracker(budget: budget)

        XCTAssertFalse(tracker.isCancelled)
        tracker.cancel()
        XCTAssertTrue(tracker.isCancelled)

        let error = tracker.tryStartToolCall()
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("cancelled") == true)
    }

    func testBudgetTrackerConcurrencyLimit() {
        let budget = ScriptBudget(maxToolCalls: 10, maxWallClockSeconds: 60, maxConcurrentToolCalls: 2)
        let tracker = ScriptBudgetTracker(budget: budget)

        XCTAssertNil(tracker.tryStartToolCall())
        XCTAssertNil(tracker.tryStartToolCall())

        // Third concurrent call should be rejected.
        let error = tracker.tryStartToolCall()
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("concurrent") == true, "Expected concurrency error, got: \(error ?? "")")

        // Finish one call, should allow another.
        tracker.finishToolCall()
        XCTAssertNil(tracker.tryStartToolCall())
    }
}

import XCTest
@testable import Fae

// MARK: - JSCExecutionLog Tests

final class JSCExecutionLogTests: XCTestCase {

    func testAppendAndSnapshot() {
        let log = JSCExecutionLog()
        log.log(.scriptStart, message: "start")
        log.log(.scriptEnd, message: "end", success: true)

        let entries = log.snapshot()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].kind, .scriptStart)
        XCTAssertEqual(entries[1].kind, .scriptEnd)
    }

    func testCount() {
        let log = JSCExecutionLog()
        XCTAssertEqual(log.count, 0)
        log.log(.logMessage, message: "hello")
        XCTAssertEqual(log.count, 1)
    }

    func testEntriesOfKind() {
        let log = JSCExecutionLog()
        log.log(.toolCallStart, message: "tool1", toolName: "read")
        log.log(.logMessage, message: "log line")
        log.log(.toolCallStart, message: "tool2", toolName: "write")
        log.log(.toolCallEnd, message: "done", toolName: "read")

        let toolStarts = log.entries(ofKind: .toolCallStart)
        XCTAssertEqual(toolStarts.count, 2)
        XCTAssertEqual(toolStarts[0].toolName, "read")
        XCTAssertEqual(toolStarts[1].toolName, "write")
    }

    func testToolCalls() {
        let log = JSCExecutionLog()
        log.log(.toolCallStart, message: "call", toolName: "read")
        log.log(.scriptStart, message: "start")

        XCTAssertEqual(log.toolCalls.count, 1)
        XCTAssertEqual(log.toolCalls[0].toolName, "read")
    }

    func testHasErrors() {
        let log = JSCExecutionLog()
        log.log(.scriptStart, message: "start")
        XCTAssertFalse(log.hasErrors)

        log.log(.jsException, message: "oops")
        XCTAssertTrue(log.hasErrors)
    }

    func testHasErrorsFromFailureFlag() {
        let log = JSCExecutionLog()
        log.log(.toolCallEnd, message: "failed", success: false)
        XCTAssertTrue(log.hasErrors)
    }

    func testHasErrorsFromCancellation() {
        let log = JSCExecutionLog()
        log.log(.cancellation, message: "cancelled")
        XCTAssertTrue(log.hasErrors)
    }

    func testFormatTimelineEmpty() {
        let log = JSCExecutionLog()
        XCTAssertEqual(log.formatTimeline(), "(empty execution log)")
    }

    func testFormatTimelineContainsKinds() {
        let log = JSCExecutionLog()
        log.log(.scriptStart, message: "begin")
        log.log(.toolCallStart, message: "calling read", toolName: "read")
        log.log(.scriptEnd, message: "done", success: true)

        let timeline = log.formatTimeline()
        XCTAssertTrue(timeline.contains("[scriptStart]"), "Timeline should contain scriptStart tag")
        XCTAssertTrue(timeline.contains("[toolCallStart]"), "Timeline should contain toolCallStart tag")
        XCTAssertTrue(timeline.contains("[scriptEnd]"), "Timeline should contain scriptEnd tag")
        XCTAssertTrue(timeline.contains("tool=read"), "Timeline should contain tool name")
        XCTAssertTrue(timeline.contains("success=true"), "Timeline should contain success flag")
    }

    func testFormatTimelineMetadata() {
        let log = JSCExecutionLog()
        log.log(.budgetCheck, message: "check", metadata: ["limit": "20", "current": "5"])

        let timeline = log.formatTimeline()
        XCTAssertTrue(timeline.contains("current=5"), "Timeline should contain metadata")
        XCTAssertTrue(timeline.contains("limit=20"), "Timeline should contain metadata")
    }

    func testEntryFactory() {
        let entry = JSCExecutionLogEntry.entry(
            .toolCallEnd,
            message: "done",
            toolName: "bash",
            success: true,
            durationMs: 42,
            metadata: ["key": "val"]
        )
        XCTAssertEqual(entry.kind, .toolCallEnd)
        XCTAssertEqual(entry.message, "done")
        XCTAssertEqual(entry.toolName, "bash")
        XCTAssertEqual(entry.success, true)
        XCTAssertEqual(entry.durationMs, 42)
        XCTAssertEqual(entry.metadata["key"], "val")
    }

    func testAllKindsCovered() {
        // Verify all Kind cases exist (compile-time check via CaseIterable).
        let kinds = JSCExecutionLogEntry.Kind.allCases
        XCTAssertTrue(kinds.count >= 11, "Expected at least 11 log entry kinds, got \(kinds.count)")
    }
}

// MARK: - JSCDeveloperHarness Tests

final class JSCDeveloperHarnessTests: XCTestCase {

    // MARK: - Basic Execution

    func testSimpleScriptReturnsValue() async {
        let harness = JSCDeveloperHarness()
        let result = await harness.run(script: "return 42;")

        XCTAssertEqual(result.scriptResult.status, .success)
        XCTAssertEqual(result.scriptResult.value, "42")
        XCTAssertFalse(result.hasErrors)
        XCTAssertTrue(result.totalDurationMs >= 0)
    }

    func testScriptWithLogging() async {
        let harness = JSCDeveloperHarness()
        let result = await harness.run(script: """
            fae.log('hello');
            fae.log('world');
            return 'done';
        """)

        XCTAssertEqual(result.scriptResult.status, .success)
        XCTAssertEqual(result.scriptResult.logs, ["hello", "world"])

        // Execution log should contain logMessage entries.
        let logEntries = result.executionLog.entries(ofKind: .logMessage)
        XCTAssertEqual(logEntries.count, 2, "Expected 2 logMessage entries, got \(logEntries.count)")
        XCTAssertEqual(logEntries[0].message, "hello")
        XCTAssertEqual(logEntries[1].message, "world")
    }

    func testTimelineIsNotEmpty() async {
        let harness = JSCDeveloperHarness()
        let result = await harness.run(script: "return 1;")

        XCTAssertFalse(result.timeline.isEmpty, "Timeline should not be empty")
        XCTAssertTrue(result.timeline.contains("[scriptStart]"), "Timeline should contain scriptStart")
        XCTAssertTrue(result.timeline.contains("[scriptEnd]"), "Timeline should contain scriptEnd")
    }

    // MARK: - Tool Calls via Harness

    func testMockToolCall() async {
        let readTool = MockTool(name: "read", response: #"{"content":"hello"}"#)
        let harness = JSCDeveloperHarness(tools: [readTool])

        let result = await harness.run(script: """
            var res = await fae.tool('read', '{"path":"/tmp/test"}');
            fae.log('got: ' + res);
            return res;
        """)

        XCTAssertEqual(result.scriptResult.status, .success, "Script should succeed, error: \(result.scriptResult.error ?? "none")")
        XCTAssertEqual(result.toolCallCount, 1)

        // Should have toolCallStart and toolCallEnd entries.
        let starts = result.executionLog.entries(ofKind: .toolCallStart)
        let ends = result.executionLog.entries(ofKind: .toolCallEnd)
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(starts[0].toolName, "read")
        XCTAssertEqual(ends[0].toolName, "read")
        XCTAssertEqual(ends[0].success, true)
    }

    func testFailingMockTool() async {
        let failTool = MockTool(name: "read", shouldFail: true)
        let harness = JSCDeveloperHarness(tools: [failTool])

        let result = await harness.run(script: """
            try {
                await fae.tool('read', '{}');
                return 'should not reach';
            } catch(e) {
                return 'caught: ' + e.message;
            }
        """)

        XCTAssertEqual(result.scriptResult.status, .success)
        XCTAssertTrue(result.scriptResult.value?.contains("caught:") == true)

        // toolCallEnd should show failure.
        let ends = result.executionLog.entries(ofKind: .toolCallEnd)
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(ends[0].success, false)
    }

    func testMultipleToolCalls() async {
        let readTool = MockTool(name: "read", response: #"{"ok":true}"#)
        let harness = JSCDeveloperHarness(tools: [readTool])

        let result = await harness.run(script: """
            await fae.tool('read', '{"path":"a"}');
            await fae.tool('read', '{"path":"b"}');
            await fae.tool('read', '{"path":"c"}');
            return 'done';
        """)

        XCTAssertEqual(result.scriptResult.status, .success)
        XCTAssertEqual(result.toolCallCount, 3)
    }

    // MARK: - Error Handling

    func testSyntaxErrorCaptured() async {
        let harness = JSCDeveloperHarness()
        let result = await harness.run(script: "function {{{ invalid")

        XCTAssertEqual(result.scriptResult.status, .failure)
        XCTAssertTrue(result.hasErrors)

        let exceptions = result.executionLog.entries(ofKind: .jsException)
        XCTAssertTrue(exceptions.count >= 1, "Should have at least 1 jsException entry")
    }

    func testThrowCaptured() async {
        let harness = JSCDeveloperHarness()
        let result = await harness.run(script: "throw new Error('test error');")

        XCTAssertEqual(result.scriptResult.status, .failure)
        XCTAssertTrue(result.hasErrors)
    }

    // MARK: - Budget Enforcement via Harness

    func testBudgetExceededCaptured() async {
        let readTool = MockTool(name: "read", response: "{}")
        let harness = JSCDeveloperHarness(tools: [readTool])

        let budget = ScriptBudget(
            maxToolCalls: 1,
            maxWallClockSeconds: 30,
            maxConcurrentToolCalls: 5
        )

        let result = await harness.run(script: """
            await fae.tool('read', '{}');
            await fae.tool('read', '{}');
            return 'should not reach';
        """, budget: budget)

        // Second call exceeds budget, uncaught rejection fails script.
        XCTAssertEqual(result.scriptResult.status, .failure)
        XCTAssertTrue(result.hasErrors)

        let budgetEntries = result.executionLog.entries(ofKind: .budgetCheck)
        XCTAssertTrue(budgetEntries.count >= 1, "Should have budget check entries")
    }

    // MARK: - Sleep Logging

    func testSleepLogged() async {
        let harness = JSCDeveloperHarness()
        let result = await harness.run(script: """
            await fae.sleep(10);
            return 'slept';
        """)

        XCTAssertEqual(result.scriptResult.status, .success)

        let sleepStarts = result.executionLog.entries(ofKind: .sleepStart)
        let sleepEnds = result.executionLog.entries(ofKind: .sleepEnd)
        XCTAssertEqual(sleepStarts.count, 1, "Expected 1 sleepStart, got \(sleepStarts.count)")
        XCTAssertEqual(sleepEnds.count, 1, "Expected 1 sleepEnd, got \(sleepEnds.count)")
    }

    // MARK: - Lifecycle Validation

    func testScriptStartAndEndAlwaysPresent() async {
        let harness = JSCDeveloperHarness()

        // Successful script.
        let ok = await harness.run(script: "return 'ok';")
        let okStarts = ok.executionLog.entries(ofKind: .scriptStart)
        let okEnds = ok.executionLog.entries(ofKind: .scriptEnd)
        XCTAssertEqual(okStarts.count, 1, "Should have exactly 1 scriptStart")
        XCTAssertEqual(okEnds.count, 1, "Should have exactly 1 scriptEnd")
        XCTAssertEqual(okEnds[0].success, true)

        // Failing script.
        let fail = await harness.run(script: "throw new Error('boom');")
        let failStarts = fail.executionLog.entries(ofKind: .scriptStart)
        let failEnds = fail.executionLog.entries(ofKind: .scriptEnd)
        XCTAssertEqual(failStarts.count, 1, "Should have exactly 1 scriptStart")
        XCTAssertEqual(failEnds.count, 1, "Should have exactly 1 scriptEnd")
        XCTAssertEqual(failEnds[0].success, false)
    }

    func testIsolationBetweenRuns() async {
        let harness = JSCDeveloperHarness()

        let r1 = await harness.run(script: """
            globalThis.__leak = 'leaked';
            return 'set';
        """)
        XCTAssertEqual(r1.scriptResult.status, .success)

        let r2 = await harness.run(script: """
            return typeof globalThis.__leak === 'undefined' ? 'isolated' : 'leaked';
        """)
        XCTAssertEqual(r2.scriptResult.status, .success)
        XCTAssertEqual(r2.scriptResult.value, "isolated")

        // Each run should have its own independent log.
        XCTAssertTrue(r1.logEntries.count > 0)
        XCTAssertTrue(r2.logEntries.count > 0)
        // Verify the log instances are separate objects (different identity).
        XCTAssertTrue(r1.executionLog !== r2.executionLog, "Each run should create a separate execution log")
    }

    // MARK: - Custom Budget

    func testCustomBudget() async {
        let harness = JSCDeveloperHarness(
            defaultBudget: ScriptBudget(maxToolCalls: 1, maxWallClockSeconds: 5, maxConcurrentToolCalls: 1)
        )
        let result = await harness.run(script: "return 'ok';")
        XCTAssertEqual(result.scriptResult.status, .success)

        // Budget metadata should be in scriptStart entry.
        let starts = result.executionLog.entries(ofKind: .scriptStart)
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts[0].metadata["budgetMaxToolCalls"], "1")
    }

    // MARK: - MockTool Tests

    func testMockToolSuccess() async throws {
        let tool = MockTool(name: "test", response: #"{"key":"value"}"#)
        let result = try await tool.execute(input: [:])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.output, #"{"key":"value"}"#)
    }

    func testMockToolFailure() async throws {
        let tool = MockTool(name: "test", shouldFail: true)
        let result = try await tool.execute(input: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("intentional failure"))
    }

}

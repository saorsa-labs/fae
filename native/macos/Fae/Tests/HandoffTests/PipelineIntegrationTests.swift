import XCTest
@testable import Fae

// MARK: - Script Block Parsing Tests

final class ScriptBlockParsingTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParsesSingleScriptBlock() {
        let text = """
        <tool_program>
        var x = await fae.tool('read', '{"path":"/tmp/test"}');
        return x;
        </tool_program>
        """

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].source.contains("fae.tool"))
        XCTAssertNil(blocks[0].allowedTools)
        XCTAssertNil(blocks[0].budget)
    }

    func testParsesMultipleScriptBlocks() {
        let text = """
        <tool_program>
        return 'first';
        </tool_program>
        Some text in between.
        <tool_program>
        return 'second';
        </tool_program>
        """

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks[0].source.contains("first"))
        XCTAssertTrue(blocks[1].source.contains("second"))
    }

    func testSkipsEmptyScriptBlocks() {
        let text = """
        <tool_program>
        </tool_program>
        <tool_program>
        return 'valid';
        </tool_program>
        """

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].source.contains("valid"))
    }

    func testNoScriptBlocksReturnsEmpty() {
        let text = "Just regular text with no script blocks."
        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertTrue(blocks.isEmpty)
    }

    func testUnclosedScriptBlockParsesToEnd() {
        let text = """
        <tool_program>
        return 'unclosed';
        """

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].source.contains("unclosed"))
    }

    // MARK: - Metadata Parsing

    func testParsesMetaWithAllowedTools() {
        let text = """
        <tool_program_meta>{"allowed_tools":["read","write"]}</tool_program_meta>
        <tool_program>
        return 'with meta';
        </tool_program>
        """

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].allowedTools, Set(["read", "write"]))
        XCTAssertNil(blocks[0].budget)
    }

    func testParsesMetaWithBudget() {
        let text = """
        <tool_program_meta>{"max_tool_calls":5,"max_wall_clock_seconds":30}</tool_program_meta>
        <tool_program>
        return 'budgeted';
        </tool_program>
        """

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertNotNil(blocks[0].budget)
        XCTAssertEqual(blocks[0].budget?.maxToolCalls, 5)
        XCTAssertEqual(blocks[0].budget?.maxWallClockSeconds, 30)
    }

    func testParsesMetaWithAllFieldsCombined() {
        let text = """
        <tool_program_meta>{"allowed_tools":["bash"],"max_tool_calls":3,"max_wall_clock_seconds":10,"max_concurrent_tool_calls":1}</tool_program_meta>
        <tool_program>
        await fae.tool('bash', '{"command":"echo hi"}');
        </tool_program>
        """

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].allowedTools, Set(["bash"]))
        XCTAssertEqual(blocks[0].budget?.maxToolCalls, 3)
        XCTAssertEqual(blocks[0].budget?.maxWallClockSeconds, 10)
        XCTAssertEqual(blocks[0].budget?.maxConcurrentToolCalls, 1)
    }

    func testInvalidMetaJSONIsIgnored() {
        let text = """
        <tool_program_meta>not valid json</tool_program_meta>
        <tool_program>
        return 'still works';
        </tool_program>
        """

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(blocks[0].allowedTools)
        XCTAssertNil(blocks[0].budget)
    }

    // MARK: - Mixed Tool Calls and Script Blocks

    func testToolCallsAndScriptBlocksCoexist() {
        let text = """
        <tool_call>{"name":"read","arguments":{"path":"/tmp/a"}}</tool_call>
        <tool_program>
        return 'script result';
        </tool_program>
        """

        let toolCalls = PipelineCoordinator.parseToolCalls(from: text)
        let scriptBlocks = PipelineCoordinator.parseScriptBlocks(from: text)

        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0].name, "read")
        XCTAssertEqual(scriptBlocks.count, 1)
        XCTAssertTrue(scriptBlocks[0].source.contains("script result"))
    }

    func testToolCallParsingUnaffectedByScriptBlocks() {
        let text = """
        <tool_call>{"name":"web_search","arguments":{"query":"swift"}}</tool_call>
        <tool_call><function=calendar><parameter=action>list_today</parameter></function></tool_call>
        """

        let toolCalls = PipelineCoordinator.parseToolCalls(from: text)
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].name, "web_search")
        XCTAssertEqual(toolCalls[1].name, "calendar")

        let scriptBlocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertTrue(scriptBlocks.isEmpty)
    }

    // MARK: - ScriptBlock Equatable

    func testScriptBlockEquality() {
        let a = PipelineCoordinator.ScriptBlock(source: "return 1;", allowedTools: nil, budget: nil)
        let b = PipelineCoordinator.ScriptBlock(source: "return 1;", allowedTools: nil, budget: nil)
        let c = PipelineCoordinator.ScriptBlock(source: "return 2;", allowedTools: nil, budget: nil)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)

        let d = PipelineCoordinator.ScriptBlock(
            source: "return 1;",
            allowedTools: Set(["read"]),
            budget: ScriptBudget(maxToolCalls: 5, maxWallClockSeconds: 30, maxConcurrentToolCalls: 2)
        )
        let e = PipelineCoordinator.ScriptBlock(
            source: "return 1;",
            allowedTools: Set(["read"]),
            budget: ScriptBudget(maxToolCalls: 5, maxWallClockSeconds: 30, maxConcurrentToolCalls: 2)
        )
        XCTAssertEqual(d, e)
    }

    // MARK: - No prefix(5) Cap for Script Path

    func testScriptBlocksHaveNoPrefixCap() {
        // Build a response with 10 script blocks — all should be parsed.
        var text = ""
        for i in 0..<10 {
            text += "<tool_program>\nreturn \(i);\n</tool_program>\n"
        }

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 10, "Script blocks should not be capped at 5")
    }

    func testToolCallsStillCappedAtFiveInParsing() {
        // parseToolCalls itself doesn't cap — the cap is at the call site (prefix(5)).
        // This test verifies the parser returns all calls; the cap is applied later.
        var text = ""
        for i in 0..<10 {
            text += "<tool_call>{\"name\":\"read\",\"arguments\":{\"n\":\(i)}}</tool_call>\n"
        }

        let calls = PipelineCoordinator.parseToolCalls(from: text)
        XCTAssertEqual(calls.count, 10, "Parser returns all calls; prefix(5) is applied at execution")
    }

    // MARK: - Whitespace Handling

    func testScriptBlockTrimsWhitespace() {
        let text = """
        <tool_program>

            return 'trimmed';

        </tool_program>
        """

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].source, "return 'trimmed';")
    }

    func testMetaWithExtraWhitespace() {
        let text = """
        <tool_program_meta>
          { "allowed_tools": ["read"] }
        </tool_program_meta>
        <tool_program>
        return 'ok';
        </tool_program>
        """

        let blocks = PipelineCoordinator.parseScriptBlocks(from: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].allowedTools, Set(["read"]))
    }
}

// MARK: - Script Execution Integration Tests

/// Tests that verify JS tool programs execute correctly through the JSCRuntime
/// when routed from the pipeline's `executeScriptBlock` path.
final class ScriptExecutionIntegrationTests: XCTestCase {

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

    private actor AllowBroker: TrustedActionBroker {
        func evaluate(_ intent: ActionIntent) async -> BrokerDecision {
            .allow(reason: DecisionReason(code: .allowLowRisk, message: "test allow"))
        }
    }

    private func makeRuntime(
        tools: [any Tool] = [],
        broker: (any TrustedActionBroker)? = nil,
        ticketManager: ScriptScopedTicketManager? = nil
    ) -> JSCRuntime {
        let registry = ToolRegistry(tools: tools)
        let executor = ToolExecutor(
            registry: registry,
            actionBroker: broker ?? AllowBroker(),
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
            },
            ticketManager: ticketManager
        )
    }

    // MARK: - Script Execution via Runtime

    func testScriptBlockExecutesThroughRuntime() async {
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo])

        let block = PipelineCoordinator.ScriptBlock(
            source: """
            var r = await fae.tool('read', '{"path":"/tmp/test"}');
            return 'done: ' + r;
            """,
            allowedTools: nil,
            budget: nil
        )

        let result = await runtime.run(
            script: block.source,
            budget: block.budget ?? .default,
            allowedTools: block.allowedTools
        )

        XCTAssertEqual(result.status, .success, "Expected success, got \(result.status), error: \(result.error ?? "none"), logs: \(result.logs)")
        XCTAssertNotNil(result.value, "Expected a value, error: \(result.error ?? "none")")
        XCTAssertTrue(result.value?.contains("done:") == true, "Expected 'done:' in value: \(result.value ?? "nil")")
    }

    func testScriptBlockWithCustomBudget() async {
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo])

        let block = PipelineCoordinator.ScriptBlock(
            source: """
            await fae.tool('read', '{"n":1}');
            await fae.tool('read', '{"n":2}');
            await fae.tool('read', '{"n":3}');
            return 'should not reach';
            """,
            allowedTools: nil,
            budget: ScriptBudget(maxToolCalls: 2, maxWallClockSeconds: 30, maxConcurrentToolCalls: 5)
        )

        let result = await runtime.run(
            script: block.source,
            budget: block.budget ?? .default,
            allowedTools: block.allowedTools
        )

        // Third call exceeds budget — script should fail.
        XCTAssertEqual(result.status, .failure, "Expected failure from budget exceeded, got \(result.status)")
    }

    func testScriptBlockWithAllowedToolsTicket() async {
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo], ticketManager: ScriptScopedTicketManager())

        let block = PipelineCoordinator.ScriptBlock(
            source: """
            var r = await fae.tool('read', '{"path":"test"}');
            return 'got: ' + r;
            """,
            allowedTools: Set(["read"]),
            budget: nil
        )

        let result = await runtime.run(
            script: block.source,
            budget: block.budget ?? .default,
            allowedTools: block.allowedTools
        )

        XCTAssertEqual(result.status, .success)
    }

    func testScriptBlockFailureReturnsError() async {
        let runtime = makeRuntime()

        let block = PipelineCoordinator.ScriptBlock(
            source: "throw new Error('intentional test error');",
            allowedTools: nil,
            budget: nil
        )

        let result = await runtime.run(
            script: block.source,
            budget: block.budget ?? .default,
            allowedTools: block.allowedTools
        )

        XCTAssertEqual(result.status, .failure)
        XCTAssertTrue(result.error?.contains("intentional test error") == true)
    }

    func testMultipleScriptBlocksExecuteSequentially() async {
        let runtime = makeRuntime()

        let blocks = [
            PipelineCoordinator.ScriptBlock(source: "return 'first';", allowedTools: nil, budget: nil),
            PipelineCoordinator.ScriptBlock(source: "return 'second';", allowedTools: nil, budget: nil),
            PipelineCoordinator.ScriptBlock(source: "return 'third';", allowedTools: nil, budget: nil),
        ]

        var results: [String] = []
        for block in blocks {
            let result = await runtime.run(
                script: block.source,
                budget: block.budget ?? .default,
                allowedTools: block.allowedTools
            )
            XCTAssertEqual(result.status, .success)
            if let value = result.value {
                results.append(value)
            }
        }

        XCTAssertEqual(results, ["first", "second", "third"])
    }

    // MARK: - Governance Enforcement

    func testScriptBlockGovernedByBroker() async {
        // Create a broker that denies all tool calls.
        let denyBroker = DenyBroker()
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo], broker: denyBroker)

        let block = PipelineCoordinator.ScriptBlock(
            source: """
            try {
                await fae.tool('read', '{"path":"test"}');
                return 'should not reach';
            } catch(e) {
                return 'denied: ' + e.message;
            }
            """,
            allowedTools: nil,
            budget: nil
        )

        let result = await runtime.run(
            script: block.source,
            budget: block.budget ?? .default,
            allowedTools: block.allowedTools
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertTrue(result.value?.contains("denied") == true, "Tool call should be denied by broker")
    }
}

/// Broker that denies all tool calls.
private actor DenyBroker: TrustedActionBroker {
    func evaluate(_ intent: ActionIntent) async -> BrokerDecision {
        .deny(reason: DecisionReason(code: .ownerRequired, message: "denied by test broker"))
    }
}

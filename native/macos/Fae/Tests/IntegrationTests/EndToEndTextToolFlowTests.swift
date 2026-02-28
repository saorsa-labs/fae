import XCTest
@testable import Fae

/// Tests the text → LLM → tool → LLM response flow using mock engines.
///
/// Since PipelineCoordinator requires concrete engine types, these tests
/// exercise the component contracts that the pipeline depends on:
/// LLM token streaming, tool execution, tool risk decisions, and event emission.
final class EndToEndTextToolFlowTests: XCTestCase {

    private var harness: TestRuntimeHarness!

    override func setUp() async throws {
        harness = try TestRuntimeHarness()
        await harness.setUp()
    }

    override func tearDown() {
        harness.cleanup()
        harness = nil
    }

    // MARK: - LLM Generation

    func testMockLLMGeneratesTokenStream() async throws {
        let llm = MockLLMEngine()
        await llm.setTokens(["Hello", " world", "!"])

        let messages = [LLMMessage(role: .user, content: "Hi")]
        let stream = await llm.generate(
            messages: messages,
            systemPrompt: "You are Fae.",
            options: GenerationOptions()
        )

        var collected = ""
        for try await token in stream {
            collected += token
        }
        XCTAssertEqual(collected, "Hello world!")
        let count = await llm.generateCallCount
        XCTAssertEqual(count, 1)
    }

    func testMockLLMTracksMultipleCalls() async throws {
        let llm = MockLLMEngine()
        await llm.setTokens(["A"])

        for _ in 0..<3 {
            let stream = await llm.generate(
                messages: [LLMMessage(role: .user, content: "test")],
                systemPrompt: "",
                options: GenerationOptions()
            )
            for try await _ in stream {}
        }

        let count = await llm.generateCallCount
        XCTAssertEqual(count, 3)
    }

    // MARK: - Tool Execution

    func testToolExecutionReturnsResult() async throws {
        var tool = MockTool(name: "test_tool", riskLevel: .low, requiresApproval: false)
        tool.resultJSON = "{\"answer\": 42}"

        let result = try await tool.execute(input: ["query": "meaning of life"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("42"))
    }

    func testFailingToolReturnsError() async throws {
        let tool = FailingMockTool(name: "bad_tool")
        let result = try await tool.execute(input: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("failed"))
    }

    func testToolRegistryLookup() async throws {
        let registry = harness.makeRegistry()

        XCTAssertNotNil(registry.tool(named: "read"))
        XCTAssertNotNil(registry.tool(named: "write"))
        XCTAssertNotNil(registry.tool(named: "bash"))
        XCTAssertNil(registry.tool(named: "nonexistent"))
    }

    func testToolRegistrySchemasContainAllTools() async throws {
        let registry = harness.makeRegistry()
        let schemas = registry.toolSchemas

        XCTAssertTrue(schemas.contains("read"))
        XCTAssertTrue(schemas.contains("write"))
        XCTAssertTrue(schemas.contains("bash"))
    }

    // MARK: - Event Bus

    func testEventBusDeliversToolEvents() async throws {
        harness.eventBus.send(.toolCall(id: "tc1", name: "read", inputJSON: "{}"))
        harness.eventBus.send(.toolResult(id: "tc1", name: "read", success: true, output: "file contents"))

        // Allow Combine delivery
        try await Task.sleep(nanoseconds: 50_000_000)

        let events = await harness.eventCollector.allEvents()
        let toolCalls = events.compactMap { event -> String? in
            if case .toolCall(_, let name, _) = event { return name }
            return nil
        }
        let toolResults = events.compactMap { event -> Bool? in
            if case .toolResult(_, _, let success, _) = event { return success }
            return nil
        }
        XCTAssertEqual(toolCalls, ["read"])
        XCTAssertEqual(toolResults, [true])
    }
}

// MARK: - MockLLMEngine helpers

extension MockLLMEngine {
    func setTokens(_ tokens: [String]) {
        self.tokens = tokens
    }
}

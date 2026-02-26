import Foundation

/// Background agent loop: generates LLM responses with tool execution.
///
/// The agent loop runs iteratively: generate → parse tool calls →
/// execute tools → feed results back → generate again. Max 10 turns.
///
/// Replaces: `src/fae_llm/agent/{loop_engine.rs, executor.rs, accumulator.rs}`
actor AgentLoop {
    private let llmEngine: MLXLLMEngine
    private let registry: ToolRegistry
    private let approvalManager: ApprovalManager?
    private let config: FaeConfig

    static let maxTurns = 10
    static let maxToolsPerTurn = 5
    static let toolTimeoutSeconds: TimeInterval = 30

    init(
        llmEngine: MLXLLMEngine,
        registry: ToolRegistry,
        approvalManager: ApprovalManager? = nil,
        config: FaeConfig
    ) {
        self.llmEngine = llmEngine
        self.registry = registry
        self.approvalManager = approvalManager
        self.config = config
    }

    /// Run the agent loop and return the final text response.
    func run(
        userText: String,
        systemPrompt: String,
        history: [LLMMessage]
    ) async -> String {
        var messages = history
        messages.append(LLMMessage(role: .user, content: userText))

        for turn in 0..<Self.maxTurns {
            // Generate LLM response.
            var fullResponse = ""
            let options = GenerationOptions(
                temperature: config.llm.temperature,
                topP: config.llm.topP,
                maxTokens: config.llm.maxTokens,
                repetitionPenalty: config.llm.repeatPenalty
            )

            let stream = await llmEngine.generate(
                messages: messages,
                systemPrompt: systemPrompt,
                options: options
            )

            do {
                for try await token in stream {
                    fullResponse += token
                }
            } catch {
                NSLog("AgentLoop: generation error turn %d: %@", turn, error.localizedDescription)
                return fullResponse.isEmpty ? "I encountered an error." : fullResponse
            }

            // Check for tool calls in response.
            let toolCalls = parseToolCalls(from: fullResponse)
            if toolCalls.isEmpty {
                // No tool calls — return the response text.
                return stripToolCallMarkup(fullResponse)
            }

            // Execute tool calls.
            messages.append(LLMMessage(role: .assistant, content: fullResponse))

            for call in toolCalls.prefix(Self.maxToolsPerTurn) {
                let result = await executeTool(call)
                messages.append(LLMMessage(
                    role: .tool,
                    content: result.output,
                    name: call.name
                ))
            }
        }

        return "I've reached the maximum number of tool iterations."
    }

    // MARK: - Tool Call Parsing

    struct ToolCall: @unchecked Sendable {
        let name: String
        let arguments: [String: Any]
    }

    /// Parse `<tool_call>{"name":"...","arguments":{...}}</tool_call>` from response.
    private func parseToolCalls(from text: String) -> [ToolCall] {
        var calls: [ToolCall] = []
        var searchRange = text.startIndex..<text.endIndex

        while let openRange = text.range(of: "<tool_call>", range: searchRange),
              let closeRange = text.range(of: "</tool_call>", range: openRange.upperBound..<text.endIndex)
        {
            let jsonStr = text[openRange.upperBound..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String
            {
                let args = json["arguments"] as? [String: Any] ?? [:]
                calls.append(ToolCall(name: name, arguments: args))
            }

            searchRange = closeRange.upperBound..<text.endIndex
        }

        return calls
    }

    /// Strip tool call markup from response text, leaving only human-readable content.
    private func stripToolCallMarkup(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<tool_call>"),
              let close = result.range(of: "</tool_call>", range: open.upperBound..<result.endIndex)
        {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tool Execution

    private func executeTool(_ call: ToolCall) async -> ToolResult {
        guard let tool = registry.tool(named: call.name) else {
            return .error("Unknown tool: \(call.name)")
        }

        // Check approval if required.
        if tool.requiresApproval {
            if let manager = approvalManager {
                let approved = await manager.requestApproval(
                    toolName: call.name,
                    description: "Execute \(call.name)"
                )
                if !approved {
                    return .error("Tool execution denied by user.")
                }
            }
        }

        // Execute with timeout.
        do {
            return try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask {
                    try await tool.execute(input: call.arguments)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.toolTimeoutSeconds * 1_000_000_000))
                    return .error("Tool timed out after \(Int(Self.toolTimeoutSeconds))s")
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            return .error("Tool error: \(error.localizedDescription)")
        }
    }
}

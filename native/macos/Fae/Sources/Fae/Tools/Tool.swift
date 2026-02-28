import Foundation

/// Result of a tool execution.
struct ToolResult: Sendable {
    let output: String
    let isError: Bool

    init(output: String, isError: Bool = false) {
        self.output = output
        self.isError = isError
    }

    static func success(_ output: String) -> ToolResult {
        ToolResult(output: output)
    }

    static func error(_ message: String) -> ToolResult {
        ToolResult(output: message, isError: true)
    }
}

/// Protocol for all Fae tools.
///
/// Replaces: tool trait from `src/fae_llm/tools/`
protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parametersSchema: String { get }
    var requiresApproval: Bool { get }
    var riskLevel: ToolRiskLevel { get }
    /// A concrete `<tool_call>` example for the LLM to follow.
    var example: String { get }
    func execute(input: [String: Any]) async throws -> ToolResult
}

extension Tool {
    var requiresApproval: Bool { false }
    var riskLevel: ToolRiskLevel { .medium }
    var example: String { "" }
}

import Foundation
import MCP

/// Dynamic `Tool` conformance that wraps an MCP server tool.
///
/// When the LLM calls this tool, the execution is forwarded to the MCP client
/// which communicates with the actual MCP server (local or remote).
///
/// MCP tool results (text, images, etc.) are converted to Fae `ToolResult` format.
final class MCPToolProxy: Tool, @unchecked Sendable {
    let name: String
    let description: String
    let parametersSchema: String
    let requiresApproval: Bool = true
    let riskLevel: ToolRiskLevel = .medium
    let example: String

    /// The MCP server name this tool belongs to.
    let serverName: String

    /// The original MCP tool name (may differ from Fae name if prefixed).
    let mcpToolName: String

    /// Reference to the MCPBridge for executing calls.
    private let bridge: MCPBridge

    init(
        mcpTool: MCP.Tool,
        serverName: String,
        bridge: MCPBridge
    ) {
        // Prefix tool name with server name to avoid collisions.
        // e.g., "slack:send_message", "linear:create_issue"
        self.name = "mcp_\(serverName)_\(mcpTool.name)"
        self.mcpToolName = mcpTool.name
        self.serverName = serverName

        self.description = mcpTool.description
            ?? "MCP tool '\(mcpTool.name)' from \(serverName)"

        // Convert MCP input schema to JSON string for Fae's schema format.
        self.parametersSchema = Self.schemaToString(mcpTool.inputSchema)

        self.example = """
            <tool_call>{"name":"\(self.name)","arguments":{}}</tool_call>
            """

        self.bridge = bridge
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        do {
            let result = try await bridge.callTool(
                serverName: serverName,
                toolName: mcpToolName,
                arguments: input
            )
            return .success(result)
        } catch {
            return .error("MCP tool '\(mcpToolName)' failed: \(error.localizedDescription)")
        }
    }

    /// Convert MCP Value schema to JSON string.
    static func schemaToString(_ schema: MCP.Value) -> String {
        // Encode the MCP Value to JSON data, then to string.
        if let data = try? JSONEncoder().encode(schema),
           let str = String(data: data, encoding: .utf8)
        {
            return str
        }
        return "{}"
    }
}

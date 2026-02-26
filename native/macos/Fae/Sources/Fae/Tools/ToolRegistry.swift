import Foundation

/// Central registry of available tools, filtered by permission mode.
///
/// Replaces: `src/agent/mod.rs` (build_registry)
final class ToolRegistry: Sendable {
    private let tools: [String: any Tool]

    init(tools: [any Tool]) {
        var map: [String: any Tool] = [:]
        for tool in tools {
            map[tool.name] = tool
        }
        self.tools = map
    }

    /// Build a registry with all built-in tools.
    static func buildDefault() -> ToolRegistry {
        let allTools: [any Tool] = [
            ReadTool(),
            WriteTool(),
            EditTool(),
            BashTool(),
            WebSearchTool(),
            FetchURLTool(),
        ]
        return ToolRegistry(tools: allTools)
    }

    /// Build a registry filtered to a specific tool allowlist.
    static func buildFiltered(allowlist: [String]) -> ToolRegistry {
        let allTools: [any Tool] = [
            ReadTool(),
            WriteTool(),
            EditTool(),
            BashTool(),
            WebSearchTool(),
            FetchURLTool(),
        ]
        let filtered = allTools.filter { allowlist.contains($0.name) }
        return ToolRegistry(tools: filtered)
    }

    func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    var allTools: [any Tool] {
        Array(tools.values)
    }

    var toolNames: [String] {
        Array(tools.keys).sorted()
    }

    /// JSON schema descriptions for all registered tools.
    var toolSchemas: String {
        tools.values
            .sorted { $0.name < $1.name }
            .map { "## \($0.name)\n\($0.description)\nParameters: \($0.parametersSchema)" }
            .joined(separator: "\n\n")
    }
}

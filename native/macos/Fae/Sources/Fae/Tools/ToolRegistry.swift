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
        let allTools: [any Tool] = Self.allBuiltinTools()
        return ToolRegistry(tools: allTools)
    }

    /// All built-in tools (core + Apple + scheduler).
    private static func allBuiltinTools() -> [any Tool] {
        [
            // Core tools
            ReadTool(),
            WriteTool(),
            EditTool(),
            BashTool(),
            SelfConfigTool(),
            WebSearchTool(),
            FetchURLTool(),
            RunSkillTool(),
            // Apple integration tools
            CalendarTool(),
            RemindersTool(),
            ContactsTool(),
            MailTool(),
            NotesTool(),
            // Scheduler tools
            SchedulerListTool(),
            SchedulerCreateTool(),
            SchedulerUpdateTool(),
            SchedulerDeleteTool(),
            SchedulerTriggerTool(),
            // Roleplay
            RoleplayTool(),
        ]
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

    /// JSON schema descriptions for all registered tools, with examples when available.
    var toolSchemas: String {
        tools.values
            .sorted { $0.name < $1.name }
            .map { tool in
                var schema = "## \(tool.name)\n\(tool.description)\nRisk: \(tool.riskLevel.rawValue)\nParameters: \(tool.parametersSchema)"
                if !tool.example.isEmpty {
                    schema += "\nExample: \(tool.example)"
                }
                return schema
            }
            .joined(separator: "\n\n")
    }
}

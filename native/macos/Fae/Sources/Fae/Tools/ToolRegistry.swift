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
    static func buildDefault(skillManager: SkillManager? = nil) -> ToolRegistry {
        let allTools: [any Tool] = Self.allBuiltinTools(skillManager: skillManager)
        return ToolRegistry(tools: allTools)
    }

    /// All built-in tools (core + Apple + scheduler + skills).
    private static func allBuiltinTools(skillManager: SkillManager?) -> [any Tool] {
        let sm = skillManager ?? SkillManager()
        let tools: [any Tool] = [
            // Core tools
            ReadTool(),
            WriteTool(),
            EditTool(),
            BashTool(),
            SelfConfigTool(),
            WebSearchTool(),
            FetchURLTool(),
            // Skill tools
            ActivateSkillTool(skillManager: sm),
            RunSkillTool(skillManager: sm),
            ManageSkillTool(skillManager: sm),
            // User input tool
            InputRequestTool(),
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
        return tools
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
        schemaString(for: Array(tools.values))
    }

    /// JSON schema descriptions filtered by tool mode.
    ///
    /// - `off` / `read_only`: read-only tools (no writes, no bash)
    /// - `read_write`: read tools + write/edit/self_config + scheduler mutation
    /// - `full`: all tools (with approval for writes)
    /// - `full_no_approval`: all tools
    func toolSchemas(for mode: String) -> String {
        let allowed = tools.values.filter { isToolAllowed($0.name, mode: mode) }
        return schemaString(for: allowed)
    }

    /// Check whether a tool is allowed in the given mode.
    func isToolAllowed(_ name: String, mode: String) -> Bool {
        switch mode {
        case "off", "read_only":
            return Self.readOnlyTools.contains(name)
        case "read_write":
            return Self.readOnlyTools.contains(name) || Self.writeTools.contains(name)
        case "full", "full_no_approval":
            return tools[name] != nil
        default:
            // Unknown mode — treat as "full" for backward compatibility.
            return tools[name] != nil
        }
    }

    // MARK: - Tool Mode Sets

    /// Tools available in "off" and "read_only" modes.
    /// Reads are always safe — Fae is local.
    private static let readOnlyTools: Set<String> = [
        "read", "web_search", "fetch_url",
        "calendar", "reminders", "contacts", "mail", "notes",
        "scheduler_list", "roleplay", "run_skill",
        "activate_skill",
        "input_request",
    ]

    /// Additional tools available in "read_write" mode.
    private static let writeTools: Set<String> = [
        "write", "edit", "self_config",
        "scheduler_create", "scheduler_update", "scheduler_delete", "scheduler_trigger",
        "manage_skill",
    ]

    // MARK: - Private

    private func schemaString(for toolList: [any Tool]) -> String {
        toolList
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

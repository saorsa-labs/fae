import Foundation
import Tokenizers

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
    static func buildDefault(
        skillManager: SkillManager? = nil,
        speakerEncoder: CoreMLSpeakerEncoder? = nil,
        speakerProfileStore: SpeakerProfileStore? = nil,
        audioCaptureManager: AudioCaptureManager? = nil,
        audioPlaybackManager: AudioPlaybackManager? = nil,
        sttEngine: MLXSTTEngine? = nil,
        wakeWordProfileStore: WakeWordProfileStore? = nil
    ) -> ToolRegistry {
        let allTools: [any Tool] = Self.allBuiltinTools(
            skillManager: skillManager,
            speakerEncoder: speakerEncoder,
            speakerProfileStore: speakerProfileStore,
            audioCaptureManager: audioCaptureManager,
            audioPlaybackManager: audioPlaybackManager,
            sttEngine: sttEngine,
            wakeWordProfileStore: wakeWordProfileStore
        )
        return ToolRegistry(tools: allTools)
    }

    /// All built-in tools (core + Apple + scheduler + skills + voice identity).
    private static func allBuiltinTools(
        skillManager: SkillManager?,
        speakerEncoder: CoreMLSpeakerEncoder? = nil,
        speakerProfileStore: SpeakerProfileStore? = nil,
        audioCaptureManager: AudioCaptureManager? = nil,
        audioPlaybackManager: AudioPlaybackManager? = nil,
        sttEngine: MLXSTTEngine? = nil,
        wakeWordProfileStore: WakeWordProfileStore? = nil
    ) -> [any Tool] {
        let sm = skillManager ?? SkillManager()
        let tools: [any Tool] = [
            // Core tools
            ReadTool(),
            WriteTool(),
            EditTool(),
            BashTool(),
            SelfConfigTool(),
            ChannelSetupTool(),
            WindowControlTool(),
            WebSearchTool(),
            FetchURLTool(),
            // Skill tools
            ActivateSkillTool(skillManager: sm),
            RunSkillTool(skillManager: sm),
            ManageSkillTool(skillManager: sm),
            AgentDelegateTool(),
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
            // Vision & computer use tools
            ScreenshotTool(),
            CameraTool(),
            ReadScreenTool(),
            ClickTool(),
            TypeTextTool(),
            ScrollTool(),
            FindElementTool(),
            // Voice identity
            VoiceIdentityTool(
                speakerEncoder: speakerEncoder,
                speakerProfileStore: speakerProfileStore,
                audioCaptureManager: audioCaptureManager,
                audioPlaybackManager: audioPlaybackManager,
                sttEngine: sttEngine,
                wakeWordProfileStore: wakeWordProfileStore
            ),
        ]
        return tools
    }

    func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    /// Return a tool with VLM provider injected for vision tools.
    func tool(named name: String, vlmProvider: VLMProvider?) -> (any Tool)? {
        guard let tool = tools[name] else { return nil }
        // Inject VLM provider into vision tools that need it.
        if let provider = vlmProvider {
            if var vt = tool as? ScreenshotTool { vt.vlmProvider = provider; return vt }
            if var vt = tool as? CameraTool { vt.vlmProvider = provider; return vt }
            if var vt = tool as? ReadScreenTool { vt.vlmProvider = provider; return vt }
        }
        return tool
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
    /// - `off`: no tools
    /// - `read_only`: read-only tools (no writes, no bash)
    /// - `read_write`: read tools + write/edit/self_config + scheduler mutation
    /// - `full`: all tools (with approval for writes)
    /// - `full_no_approval`: all tools
    func toolSchemas(
        for mode: String,
        privacyMode: String = "local_preferred",
        limitedTo allowedNames: Set<String>? = nil
    ) -> String {
        let allowed = filteredTools(for: mode, privacyMode: privacyMode, limitedTo: allowedNames)
        return schemaString(for: allowed)
    }

    /// Compact tool summary for prompt context when native tool specs are also supplied.
    ///
    /// Keeps prompt tokens low while still exposing high-level capability surface.
    func compactToolSummary(
        for mode: String,
        privacyMode: String = "local_preferred",
        limitedTo allowedNames: Set<String>? = nil
    ) -> String {
        let allowed = filteredTools(for: mode, privacyMode: privacyMode, limitedTo: allowedNames)

        guard !allowed.isEmpty else { return "" }

        let lines = allowed.map { tool in
            "- \(tool.name): \(tool.riskLevel.rawValue)"
        }
        return "Available tools (name: risk):\n" + lines.joined(separator: "\n")
    }

    /// Check whether a tool is allowed in the given mode.
    func isToolAllowed(_ name: String, mode: String, privacyMode: String = "local_preferred") -> Bool {
        if privacyMode == "strict_local", Self.strictLocalDeniedTools.contains(name) {
            return false
        }

        switch mode {
        case "off":
            return false
        case "read_only":
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
        "read", "window_control", "web_search", "fetch_url",
        "calendar", "reminders", "contacts", "mail", "notes",
        "scheduler_list", "roleplay",
        "activate_skill",
        "input_request",
        "find_element",
        "voice_identity",
    ]

    /// Additional tools available in "read_write" mode.
    private static let writeTools: Set<String> = [
        "write", "edit", "self_config", "channel_setup",
        "scheduler_create", "scheduler_update", "scheduler_delete", "scheduler_trigger",
        "manage_skill", "run_skill",
        // Vision & computer use tools require read_write or higher.
        "screenshot", "camera", "read_screen",
        "click", "type_text", "scroll",
    ]

    /// Tools disabled when privacy mode is strict_local.
    private static let strictLocalDeniedTools: Set<String> = [
        "delegate_agent",
        "web_search",
        "fetch_url",
    ]

    /// Native tool specs for MLX tool calling, filtered by mode.
    ///
    /// Returns `nil` when tools are disabled (`off` mode) so the caller
    /// can distinguish "no tools" from "empty tool list".
    func nativeToolSpecs(
        for mode: String,
        privacyMode: String = "local_preferred",
        limitedTo allowedNames: Set<String>? = nil
    ) -> [ToolSpec]? {
        guard mode != "off" else { return nil }
        let allowed = filteredTools(for: mode, privacyMode: privacyMode, limitedTo: allowedNames)
        guard !allowed.isEmpty else { return nil }
        return allowed.sorted { $0.name < $1.name }.map { $0.toolSpec }
    }

    // MARK: - Private

    private func filteredTools(
        for mode: String,
        privacyMode: String = "local_preferred",
        limitedTo allowedNames: Set<String>? = nil
    ) -> [any Tool] {
        tools.values
            .filter { tool in
                guard isToolAllowed(tool.name, mode: mode, privacyMode: privacyMode) else { return false }
                guard let allowedNames else { return true }
                return allowedNames.contains(tool.name)
            }
            .sorted { $0.name < $1.name }
    }

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

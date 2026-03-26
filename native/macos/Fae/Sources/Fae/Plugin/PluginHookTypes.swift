import Foundation

/// Hook event types matching Claude Code's hook lifecycle points.
///
/// Plugins define hooks in `hooks/hooks.json` with Python scripts that receive
/// JSON on stdin and return JSON on stdout.
enum HookEvent: String, Codable, Sendable {
    /// Fired before a tool is executed. Can block or warn.
    case preToolUse = "PreToolUse"
    /// Fired after a tool completes. Can add system messages.
    case postToolUse = "PostToolUse"
    /// Fired when user submits a prompt (speech transcription in Fae's case).
    case userPromptSubmit = "UserPromptSubmit"
    /// Fired when generation/response completes.
    case stop = "Stop"
}

/// Input payload sent to hook scripts via stdin.
struct HookInput: Codable, Sendable {
    let event: String
    let toolName: String?
    let toolInput: [String: AnyCodableValue]?
    let toolOutput: String?
    let userPrompt: String?
    let assistantResponse: String?
    let sessionId: String?

    /// Build input for a PreToolUse hook.
    static func preToolUse(toolName: String, toolInput: [String: Any]) -> HookInput {
        HookInput(
            event: HookEvent.preToolUse.rawValue,
            toolName: toolName,
            toolInput: toolInput.mapValues { AnyCodableValue($0) },
            toolOutput: nil,
            userPrompt: nil,
            assistantResponse: nil,
            sessionId: nil
        )
    }

    /// Build input for a PostToolUse hook.
    static func postToolUse(toolName: String, toolOutput: String) -> HookInput {
        HookInput(
            event: HookEvent.postToolUse.rawValue,
            toolName: toolName,
            toolInput: nil,
            toolOutput: toolOutput,
            userPrompt: nil,
            assistantResponse: nil,
            sessionId: nil
        )
    }

    /// Build input for a UserPromptSubmit hook.
    static func userPromptSubmit(prompt: String) -> HookInput {
        HookInput(
            event: HookEvent.userPromptSubmit.rawValue,
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            userPrompt: prompt,
            assistantResponse: nil,
            sessionId: nil
        )
    }

    /// Build input for a Stop hook.
    static func stop(assistantResponse: String?) -> HookInput {
        HookInput(
            event: HookEvent.stop.rawValue,
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            userPrompt: nil,
            assistantResponse: assistantResponse,
            sessionId: nil
        )
    }
}

/// Response from a hook script.
struct HookResponse: Codable, Sendable {
    /// Optional message to inject into the conversation context.
    let systemMessage: String?
    /// If true, block the action (tool call, prompt submission, etc.).
    let block: Bool?
    /// Optional metadata passed back from the hook.
    let metadata: [String: AnyCodableValue]?

    /// Whether this hook wants to block the action.
    var shouldBlock: Bool { block ?? false }

    /// Default pass-through response.
    static let passthrough = HookResponse(systemMessage: nil, block: nil, metadata: nil)
}

/// A hook definition from `hooks/hooks.json`.
struct HookDefinition: Sendable {
    let event: HookEvent
    let command: String
    let timeout: Int

    /// Default timeout for hook execution (seconds).
    static let defaultTimeout = 10
}

/// Parsed `hooks/hooks.json` from a plugin.
///
/// Format:
/// ```json
/// {
///   "hooks": {
///     "PreToolUse": [{ "hooks": [{ "type": "command", "command": "...", "timeout": 10 }] }],
///     "PostToolUse": [{ "hooks": [{ "type": "command", "command": "..." }] }]
///   }
/// }
/// ```
struct PluginHookConfig: Sendable {
    let hooks: [HookEvent: [HookDefinition]]

    /// Parse a `hooks/hooks.json` file from a plugin directory.
    ///
    /// Substitutes `${CLAUDE_PLUGIN_ROOT}` / `${FAE_PLUGIN_ROOT}` with the actual path.
    static func load(from pluginDir: URL) -> PluginHookConfig? {
        let hooksFile = pluginDir
            .appendingPathComponent("hooks")
            .appendingPathComponent("hooks.json")
        guard let data = try? Data(contentsOf: hooksFile),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooksDict = raw["hooks"] as? [String: Any]
        else {
            return nil
        }

        let pluginPath = pluginDir.path
        var result: [HookEvent: [HookDefinition]] = [:]

        for (eventName, value) in hooksDict {
            guard let event = HookEvent(rawValue: eventName),
                  let entries = value as? [[String: Any]]
            else { continue }

            var definitions: [HookDefinition] = []

            for entry in entries {
                guard let hooksList = entry["hooks"] as? [[String: Any]] else { continue }

                for hookSpec in hooksList {
                    guard (hookSpec["type"] as? String) == "command",
                          let command = hookSpec["command"] as? String
                    else { continue }

                    let timeout = hookSpec["timeout"] as? Int ?? HookDefinition.defaultTimeout
                    let expandedCommand = command
                        .replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: pluginPath)
                        .replacingOccurrences(of: "${FAE_PLUGIN_ROOT}", with: pluginPath)

                    definitions.append(HookDefinition(
                        event: event,
                        command: expandedCommand,
                        timeout: timeout
                    ))
                }
            }

            if !definitions.isEmpty {
                result[event] = definitions
            }
        }

        return result.isEmpty ? nil : PluginHookConfig(hooks: result)
    }
}

/// Type-erased Codable value for JSON serialization of arbitrary tool inputs.
enum AnyCodableValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(_ value: Any) {
        if let s = value as? String { self = .string(s) }
        else if let i = value as? Int { self = .int(i) }
        else if let d = value as? Double { self = .double(d) }
        else if let b = value as? Bool { self = .bool(b) }
        else if let s = value as? CustomStringConvertible { self = .string(s.description) }
        else { self = .null }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        }
    }
}

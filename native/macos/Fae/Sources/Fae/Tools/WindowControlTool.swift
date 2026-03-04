import AppKit
import Foundation

/// Controls Fae UI windows from tool calls.
///
/// Skill-driven routing uses this tool for settings/window actions so natural speech
/// can map to UI control without deterministic phrase hardcoding in the voice parser.
struct WindowControlTool: Tool {
    let name = "window_control"
    let description = "Control Fae windows. Actions: open_settings, close_settings."
    let parametersSchema = #"{"action": "string (required: open_settings|close_settings)"}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"window_control","arguments":{"action":"close_settings"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }

        switch action {
        case "open_settings":
            let opened = await MainActor.run { () -> (Bool, Bool) in
                let primary = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                let fallback = !primary
                    ? NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    : false
                NotificationCenter.default.post(name: .faeOpenSettingsRequested, object: nil)
                return (primary, fallback)
            }
            return .success("Requested settings open (primary=\(opened.0), fallback=\(opened.1)).")

        case "close_settings":
            await MainActor.run {
                NotificationCenter.default.post(name: .faeCloseSettingsRequested, object: nil)
            }
            return .success("Requested settings close.")

        default:
            return .error("Unknown action '\(action)'. Use: open_settings, close_settings")
        }
    }
}

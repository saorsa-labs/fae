import AppKit
import Foundation

/// Controls Fae UI windows from tool calls.
///
/// Skill-driven routing uses this tool for settings/window actions so natural speech
/// can map to UI control without deterministic phrase hardcoding in the voice parser.
struct WindowControlTool: Tool {
    let name = "window_control"
    let description = "Control Fae and macOS app windows. Actions: open_settings, close_settings, close_app (quit a running app by name, e.g. Calendar, Reminders, Contacts, Notes, Safari)."
    let parametersSchema = #"{"action": "string (required: open_settings|close_settings|close_app)", "app_name": "string (for close_app: the app name, e.g. Calendar, Reminders, Safari)"}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"window_control","arguments":{"action":"close_app","app_name":"Calendar"}}</tool_call>"#

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

        case "close_app":
            guard let appName = input["app_name"] as? String, !appName.isEmpty else {
                return .error("Missing required parameter: app_name (e.g. Calendar, Reminders)")
            }
            let closed = await closeApp(named: appName)
            return closed
                ? .success("\(appName) has been closed.")
                : .error("\(appName) was not running or could not be closed.")

        default:
            return .error("Unknown action '\(action)'. Use: open_settings, close_settings, close_app")
        }
    }

    /// Gracefully quit a macOS app by name using NSRunningApplication.terminate().
    private func closeApp(named appName: String) async -> Bool {
        await MainActor.run {
            let apps = NSWorkspace.shared.runningApplications
            let normalizedName = appName.lowercased()
            guard let app = apps.first(where: {
                $0.localizedName?.lowercased() == normalizedName
                    || $0.bundleIdentifier?.lowercased().hasSuffix(".\(normalizedName)") == true
            }) else {
                return false
            }
            return app.terminate()
        }
    }
}

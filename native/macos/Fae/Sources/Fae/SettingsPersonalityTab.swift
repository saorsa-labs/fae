import SwiftUI

/// Settings tab for personality configuration — soul, custom instructions, rescue mode.
struct SettingsPersonalityTab: View {
    var personalityEditor: PersonalityEditorController?
    var onToggleRescue: (() -> Void)?

    @EnvironmentObject private var rescueMode: RescueMode

    var body: some View {
        Form {
            // MARK: - Soul Contract

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Soul Contract")
                            .font(.headline)
                        Text(soulStatusLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Edit") {
                        personalityEditor?.showSoulEditor()
                    }
                    Button("Reset") {
                        try? SoulManager.resetToDefault()
                    }
                }
            } header: {
                Text("Soul")
            }

            // MARK: - Directive

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Directive")
                            .font(.headline)
                        Text(directiveStatusLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Edit") {
                        personalityEditor?.showInstructionsEditor()
                    }
                    Button("Clear") {
                        clearDirective()
                    }
                    .disabled(SelfConfigTool.readInstructions().isEmpty)
                }
            } header: {
                Text("Directive")
            } footer: {
                Text("Critical instructions Fae follows in every conversation. Usually empty — only add something here if it's important enough to override normal behavior.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Heartbeat")
                            .font(.headline)
                        Text(heartbeatStatusLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Edit") {
                        personalityEditor?.showHeartbeatEditor()
                    }
                    Button("Reset") {
                        try? HeartbeatManager.resetToDefault()
                    }
                }
            } header: {
                Text("Heartbeat")
            } footer: {
                Text("Behavioral prompt contract for proactive disclosure and approval style. Scheduler cadence and hard safety gates still come from runtime code and config.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // MARK: - Rescue Mode

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rescue Mode")
                            .font(.headline)
                        Text(rescueMode.isActive
                             ? "Active — running with default settings"
                             : "Inactive — running normally")
                            .font(.caption)
                            .foregroundColor(rescueMode.isActive ? .orange : .secondary)
                    }
                    Spacer()
                    Button(rescueMode.isActive ? "Exit Rescue Mode" : "Enter Rescue Mode") {
                        onToggleRescue?()
                    }
                }
            } header: {
                Text("Recovery")
            } footer: {
                Text("Rescue Mode starts Fae with default settings, bypassing custom soul and instructions. Your data is preserved.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 300)
    }

    // MARK: - Status Helpers

    private var soulStatusLine: String {
        let lines = SoulManager.lineCount
        let status = SoulManager.isModified ? "modified" : "default"
        return "\(lines) lines, \(status)"
    }

    private var directiveStatusLine: String {
        let text = SelfConfigTool.readInstructions()
        if text.isEmpty {
            return "Empty (no active directives)"
        }
        return "\(text.count) / 4000 characters"
    }

    private var heartbeatStatusLine: String {
        let lines = HeartbeatManager.lineCount
        let status = HeartbeatManager.isModified ? "modified" : "default"
        return "\(lines) lines, \(status)"
    }

    private func clearDirective() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let url = appSupport.appendingPathComponent("fae/directive.md")
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }
}

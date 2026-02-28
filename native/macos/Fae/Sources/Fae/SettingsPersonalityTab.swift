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

            // MARK: - Custom Instructions

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom Instructions")
                            .font(.headline)
                        Text(instructionsStatusLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Edit") {
                        personalityEditor?.showInstructionsEditor()
                    }
                    Button("Clear") {
                        clearInstructions()
                    }
                    .disabled(SelfConfigTool.readInstructions().isEmpty)
                }
            } header: {
                Text("Instructions")
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

    private var instructionsStatusLine: String {
        let text = SelfConfigTool.readInstructions()
        if text.isEmpty {
            return "None set — using default personality"
        }
        return "\(text.count) / 2000 characters"
    }

    private func clearInstructions() {
        let url = SoulManager.userSoulURL
            .deletingLastPathComponent()
            .appendingPathComponent("custom_instructions.txt")
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }
}

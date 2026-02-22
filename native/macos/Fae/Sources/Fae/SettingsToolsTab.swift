import SwiftUI

/// Tools settings tab: control tool mode for the embedded agent.
struct SettingsToolsTab: View {
    var commandSender: HostCommandSender?

    @AppStorage("toolMode") private var toolMode: String = "read_only"

    private let toolModes: [(label: String, value: String, description: String)] = [
        ("Off", "off", "Tools disabled. LLM-only conversational mode."),
        ("Read Only", "read_only", "Safe defaults: read files, search, list directories."),
        ("Read/Write", "read_write", "Adds file writing and editing capabilities."),
        ("Full", "full", "All tools including shell and web search. Highest risk."),
        ("Full (No Approval)", "full_no_approval", "All tools without confirmation prompts."),
    ]

    var body: some View {
        Form {
            Section("Tool Mode") {
                Picker("Mode", selection: $toolMode) {
                    ForEach(toolModes, id: \.value) { mode in
                        Text(mode.label).tag(mode.value)
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .onChange(of: toolMode) {
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "tool_mode", "value": toolMode]
                    )
                }

                if let current = toolModes.first(where: { $0.value == toolMode }) {
                    Text(current.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("About Tools") {
                Text("Tools give Fae the ability to interact with your system — reading files, managing calendar events, sending emails, and more. The tool mode controls the maximum capability level.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Individual tool permissions (Calendar, Contacts, Mail, etc.) are managed through macOS System Settings > Privacy & Security.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

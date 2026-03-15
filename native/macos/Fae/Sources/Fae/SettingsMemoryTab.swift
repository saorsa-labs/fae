import SwiftUI

struct SettingsMemoryTab: View {
    @AppStorage("fae.memory.enabled") private var memoryEnabled: Bool = true
    @AppStorage("fae.memory.maxRecallResults") private var maxRecallResults: Int = 5
    @AppStorage("fae.memory.autoIngestInbox") private var autoIngestInbox: Bool = true
    @AppStorage("fae.memory.generateDigests") private var generateDigests: Bool = true

    var commandSender: HostCommandSender?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Memory") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable long-term memory", isOn: $memoryEnabled)
                            .toggleStyle(.switch)
                            .onChange(of: memoryEnabled) { _, value in
                                commandSender?.sendCommand(
                                    name: "config.patch",
                                    payload: ["key": "memory.enabled", "value": value]
                                )
                            }

                        Stepper(value: $maxRecallResults, in: 3 ... 25) {
                            Text("Remember up to \(maxRecallResults) things per conversation")
                        }
                        .onChange(of: maxRecallResults) { _, value in
                            commandSender?.sendCommand(
                                name: "config.patch",
                                payload: ["key": "memory.max_recall_results", "value": value]
                            )
                        }

                        Toggle("Import notes automatically", isOn: $autoIngestInbox)
                            .toggleStyle(.switch)
                            .onChange(of: autoIngestInbox) { _, value in
                                commandSender?.sendCommand(
                                    name: "config.patch",
                                    payload: ["key": "memory.auto_ingest_inbox", "value": value]
                                )
                            }

                        Toggle("Create daily summaries", isOn: $generateDigests)
                            .toggleStyle(.switch)
                            .onChange(of: generateDigests) { _, value in
                                commandSender?.sendCommand(
                                    name: "config.patch",
                                    payload: ["key": "memory.generate_digests", "value": value]
                                )
                            }

                        Text("Fae remembers important things from your conversations. More memories per conversation means richer context but longer thinking time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                Divider()

                SettingsSchedulesTab(commandSender: commandSender)
            }
            .padding()
        }
    }
}

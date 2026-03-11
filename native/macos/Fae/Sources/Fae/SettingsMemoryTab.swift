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
                            Text("Recall depth: \(maxRecallResults) memories")
                        }
                        .onChange(of: maxRecallResults) { _, value in
                            commandSender?.sendCommand(
                                name: "config.patch",
                                payload: ["key": "memory.max_recall_results", "value": value]
                            )
                        }

                        Toggle("Auto-ingest inbox folder", isOn: $autoIngestInbox)
                            .toggleStyle(.switch)
                            .onChange(of: autoIngestInbox) { _, value in
                                commandSender?.sendCommand(
                                    name: "config.patch",
                                    payload: ["key": "memory.auto_ingest_inbox", "value": value]
                                )
                            }

                        Toggle("Generate memory digests", isOn: $generateDigests)
                            .toggleStyle(.switch)
                            .onChange(of: generateDigests) { _, value in
                                commandSender?.sendCommand(
                                    name: "config.patch",
                                    payload: ["key": "memory.generate_digests", "value": value]
                                )
                            }

                        Text("Fae automatically captures important context, ingests queued artifacts, and creates digest records for higher-level recall. Increase recall depth for richer context, decrease it for tighter responses.")
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

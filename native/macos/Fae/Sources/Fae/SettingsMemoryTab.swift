import SwiftUI

/// Settings tab for Memory & Learning — informational showcase with recall depth control.
///
/// Memory, note import, and digest features are always-on (proactive-by-default).
/// This tab educates the user about what Fae remembers and provides the
/// recall depth control.
struct SettingsMemoryTab: View {
    @AppStorage("fae.memory.maxRecallResults") private var maxRecallResults: Int = 5

    var commandSender: HostCommandSender?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Long-term memory")
                                    .font(.body.bold())
                                Text("Fae remembers important things from every conversation — people you mention, commitments you make, preferences you express, and interests you share.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "brain")
                                .foregroundStyle(.purple)
                        }

                        Divider()

                        Stepper(value: $maxRecallResults, in: 3 ... 25) {
                            Text("Recall up to \(maxRecallResults) memories per conversation")
                        }
                        .onChange(of: maxRecallResults) { _, value in
                            commandSender?.sendCommand(
                                name: "config.patch",
                                payload: ["key": "memory.max_recall_results", "value": value]
                            )
                        }

                        Text("More memories means richer context but slightly longer thinking time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Automatic note import")
                                    .font(.body)
                                Text("Drop files into Fae's memory inbox and she'll absorb them automatically — no need to tell her about it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.blue)
                        }

                        Divider()

                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Daily summaries")
                                    .font(.body)
                                Text("Fae creates a daily digest of what you discussed, what she learned, and what's coming up — building a searchable record of your life together.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "doc.richtext")
                                .foregroundStyle(.green)
                        }

                        Divider()

                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Personal learning")
                                    .font(.body)
                                Text("Fae continuously learns from your interactions — how you like to work, what matters to you, and how to be most helpful. She gets better every day.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.orange)
                        }
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

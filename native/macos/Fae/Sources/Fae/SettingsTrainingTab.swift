import SwiftUI

/// Settings tab for Personal Learning — Fae learns from conversations to give better answers.
struct SettingsTrainingTab: View {
    var commandSender: HostCommandSender?

    @State private var hydratingFromConfig = false
    @State private var hasLoadedConfig = false

    @State private var trainingEnabled: Bool = false
    @State private var lastTrainingRunAt: String = ""
    @State private var personalAdapterPath: String = ""

    @State private var showingConsentAlert = false
    @State private var improvementTimeline: [MetaOptNarrator.TimelineItem] = []

    var body: some View {
        Form {
            Section {
                Toggle("Personal Learning", isOn: Binding(
                    get: { trainingEnabled },
                    set: { newValue in
                        if newValue && !trainingEnabled {
                            showingConsentAlert = true
                        } else if !newValue {
                            trainingEnabled = false
                            patchConfig("training.enabled", false)
                        }
                    }
                ))
                .font(.headline)

                Text("Fae learns from your conversations to give more relevant, personalised answers over time. Everything happens on this Mac — your data never leaves the device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .alert("Enable Personal Learning?", isPresented: $showingConsentAlert) {
                Button("Enable") {
                    trainingEnabled = true
                    patchConfig("training.consent_granted", true)
                    patchConfig("training.enabled", true)
                    patchConfig("training.auto_train_enabled", true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Fae will periodically review your conversations to improve her responses. All processing runs locally on this Mac using Apple Silicon — nothing is sent anywhere.")
            }

            if trainingEnabled {
                Section("How It Works") {
                    Label("Fae reviews recent conversations weekly", systemImage: "text.bubble")
                    Label("Learns your preferences and communication style", systemImage: "brain.head.profile")
                    Label("Proposes improvements for your approval", systemImage: "checkmark.circle")
                    Label("You can always undo — just say \"Fae, undo the last learning update\"", systemImage: "arrow.uturn.backward")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if !lastTrainingRunAt.isEmpty || !personalAdapterPath.isEmpty {
                    Section("Status") {
                        if !lastTrainingRunAt.isEmpty {
                            LabeledContent("Last update", value: lastTrainingRunAt)
                        }
                        if !personalAdapterPath.isEmpty {
                            HStack {
                                Label("Personal learning active", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(FaeDesign.statusSuccess)
                                Spacer()
                                Button("Undo") {
                                    commandSender?.sendCommand(
                                        name: "conversation.inject_text",
                                        payload: ["text": "Undo the last learning update."]
                                    )
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                if !improvementTimeline.isEmpty {
                    Section("Recent Adjustments") {
                        ForEach(improvementTimeline) { item in
                            HStack(spacing: 8) {
                                Image(systemName: MetaOptNarrator.surfaceIcon(item.surface))
                                    .foregroundStyle(item.kept ? FaeDesign.statusSuccess : .secondary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.description)
                                        .font(.callout)
                                        .lineLimit(2)

                                    HStack(spacing: 4) {
                                        Text(MetaOptNarrator.surfaceDisplayName(item.surface))
                                            .font(.caption2)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(.quaternary)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))

                                        Text(item.date, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer()

                                if item.kept {
                                    Button("Undo") {
                                        commandSender?.sendCommand(
                                            name: "conversation.inject_text",
                                            payload: ["text": "Undo the overnight adjustment: \(item.description)"]
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !hasLoadedConfig {
                hasLoadedConfig = true
                Task { @MainActor in
                    await hydrateFromBackendConfig()
                }
            }
        }
    }

    private func patchConfig(_ key: String, _ value: Any) {
        commandSender?.sendCommand(
            name: "config.patch",
            payload: ["key": key, "value": value]
        )
    }

    @MainActor
    private func hydrateFromBackendConfig() async {
        guard let sender = commandSender as? FaeCore else { return }

        hydratingFromConfig = true
        defer { hydratingFromConfig = false }

        if let response = await sender.queryCommand(name: "config.get", payload: ["key": "training"]) {
            if let payload = response["payload"] as? [String: Any],
               let training = payload["training"] as? [String: Any]
            {
                if let enabled = training["enabled"] as? Bool {
                    trainingEnabled = enabled
                }
                if let lastRun = training["last_training_run_at"] as? String {
                    lastTrainingRunAt = lastRun
                }
                if let adapterPath = training["personal_adapter_path"] as? String {
                    personalAdapterPath = adapterPath
                }
            }
        }

        // Load recent meta-optimization results for the timeline.
        if let response = await sender.queryCommand(
            name: "improvement.recent_meta_opt",
            payload: [:]
        ) {
            if let entries = response["payload"] as? [[String: Any]] {
                improvementTimeline = MetaOptNarrator.buildTimeline(from: entries)
            }
        }
    }
}

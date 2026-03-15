import SwiftUI

/// Channels settings tab.
///
/// Channel setup is skill-first: discovered channel skills surface here with
/// current state, required fields, and direct "configure via chat" actions.
struct SettingsChannelsTab: View {
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager

    var commandSender: HostCommandSender?

    @AppStorage("fae.channels.enabled") private var channelsEnabled: Bool = true

    @State private var capabilities: SettingsCapabilityManifest?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        Form {
            sectionMasterToggle
            sectionChannelSkills
            sectionSetup
        }
        .formStyle(.grouped)
        .task {
            await refreshCapabilities()
        }
        .onChange(of: channelsEnabled) {
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": "channels.enabled", "value": channelsEnabled]
            )
            Task { await refreshCapabilities() }
        }
    }

    private var sectionMasterToggle: some View {
        Section {
            Toggle("Channels Enabled", isOn: $channelsEnabled)
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            Text("Master switch. Turn off to immediately silence all external channel integrations.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var sectionChannelSkills: some View {
        Section("Channel Skills") {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading channel capabilities…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            let channels = capabilities?.channels ?? []
            if !isLoading, channels.isEmpty {
                Text("No channel skills discovered yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(channels, id: \.skillName) { channel in
                channelCard(channel)
            }

            Button("Refresh Channel Status") {
                Task { await refreshCapabilities() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var sectionSetup: some View {
        Section("Connecting new channels") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Zero-config walkthrough")
                    .font(.subheadline.weight(.semibold))

                Text("1) Tell Fae which channel you want (Discord, WhatsApp, or iMessage).")
                    .font(.footnote)
                Text("2) She checks what is missing and asks only for required fields.")
                    .font(.footnote)
                Text("3) Choose between a conversational or guided setup style.")
                    .font(.footnote)
                Text("4) Fae saves settings and confirms when the channel is configured.")
                    .font(.footnote)
                    .padding(.bottom, 2)
            }
            .foregroundStyle(.secondary)

            Button("Start guided setup in chat") {
                auxiliaryWindows.focusMainWindow()
                commandSender?.sendCommand(
                    name: "conversation.inject_text",
                    payload: ["text": "Help me set up a channel using the guided workflow."]
                )
            }
            .buttonStyle(.borderedProminent)

            Button("Open conversation") {
                auxiliaryWindows.focusMainWindow()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func channelCard(_ channel: SettingsCapabilityManifest.ChannelCapability) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(channel.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                statusBadge(for: channel.state)
            }

            if !channel.missingFields.isEmpty {
                Text("Missing: \(channel.missingFields.joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Configure via Chat") {
                    auxiliaryWindows.focusMainWindow()
                }
                .buttonStyle(.bordered)

                if supportsDisconnect(channel: channel) {
                    Button("Disconnect") {
                        disconnectChannel(channel)
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(for state: SettingsCapabilityManifest.ChannelCapability.State) -> some View {
        let (label, color): (String, Color) = switch state {
        case .configured:
            ("Configured", .green)
        case .missingInput:
            ("Needs Input", .orange)
        case .skillDisabled:
            ("Skill Disabled", .red)
        case .globalDisabled:
            ("Channels Off", .secondary)
        }

        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }

    private func supportsDisconnect(channel: SettingsCapabilityManifest.ChannelCapability) -> Bool {
        channel.supportsDisconnect
    }

    private func disconnectChannel(_ channel: SettingsCapabilityManifest.ChannelCapability) {
        Task {
            let manager = SkillManager()
            let descriptors = await manager.configurableSkills(kind: "channel")
            guard let descriptor = descriptors.first(where: {
                normalizeChannelKey($0.key) == normalizeChannelKey(channel.key) ||
                    normalizeChannelKey($0.name) == normalizeChannelKey(channel.skillName)
            }) else {
                return
            }

            try? ChannelSettingsStore.clearChannel(
                channelKey: descriptor.key,
                fields: descriptor.fields
            )
            await refreshCapabilities()
        }
    }

    private func normalizeChannelKey(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    @MainActor
    private func refreshCapabilities() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let config = FaeConfig.load()
        let manager = SkillManager()
        let manifest = await SettingsCapabilityManifestBuilder.build(config: config, skillManager: manager)
        capabilities = manifest
    }
}

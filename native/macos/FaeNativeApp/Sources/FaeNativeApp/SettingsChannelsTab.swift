import SwiftUI

/// Channels settings tab: configure Discord and WhatsApp integrations.
struct SettingsChannelsTab: View {
    var commandSender: HostCommandSender?

    @AppStorage("channelsEnabled") private var channelsEnabled: Bool = false

    // Discord
    @State private var discordBotToken: String = ""
    @State private var discordGuildId: String = ""
    @State private var discordAllowedChannels: String = ""

    // WhatsApp
    @State private var whatsappAccessToken: String = ""
    @State private var whatsappPhoneNumberId: String = ""
    @State private var whatsappVerifyToken: String = ""
    @State private var whatsappAllowedNumbers: String = ""

    var body: some View {
        Form {
            Section("Channels") {
                Toggle("Enable External Channels", isOn: $channelsEnabled)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .onChange(of: channelsEnabled) {
                        commandSender?.sendCommand(
                            name: "config.patch",
                            payload: ["key": "channels.enabled", "value": channelsEnabled]
                        )
                    }
                Text("Allow Fae to communicate through Discord and WhatsApp.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if channelsEnabled {
                discordSection
                whatsappSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Discord

    private var discordSection: some View {
        Section("Discord") {
            SecureField("Bot Token", text: $discordBotToken)
                .font(.system(size: 12, design: .monospaced))
            TextField("Guild ID (optional)", text: $discordGuildId)
                .font(.system(size: 12, design: .monospaced))
            TextField("Allowed Channel IDs (comma-separated)", text: $discordAllowedChannels)
                .font(.system(size: 12, design: .monospaced))

            HStack {
                Spacer()
                Button("Save Discord Settings") {
                    saveDiscordSettings()
                }
                .buttonStyle(.bordered)
            }

            Text("Create a bot at discord.com/developers. The bot token is stored in your local config only.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - WhatsApp

    private var whatsappSection: some View {
        Section("WhatsApp Business") {
            SecureField("Access Token", text: $whatsappAccessToken)
                .font(.system(size: 12, design: .monospaced))
            TextField("Phone Number ID", text: $whatsappPhoneNumberId)
                .font(.system(size: 12, design: .monospaced))
            SecureField("Verify Token", text: $whatsappVerifyToken)
                .font(.system(size: 12, design: .monospaced))
            TextField("Allowed Numbers (comma-separated, E.164)", text: $whatsappAllowedNumbers)
                .font(.system(size: 12, design: .monospaced))

            HStack {
                Spacer()
                Button("Save WhatsApp Settings") {
                    saveWhatsAppSettings()
                }
                .buttonStyle(.bordered)
            }

            Text("Configure via Meta Business Platform. Tokens are stored in your local config only.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func saveDiscordSettings() {
        if !discordBotToken.isEmpty {
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": "channels.discord.bot_token", "value": discordBotToken]
            )
        }
        if !discordGuildId.isEmpty {
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": "channels.discord.guild_id", "value": discordGuildId]
            )
        }
        let channelIds = discordAllowedChannels
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !channelIds.isEmpty {
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": "channels.discord.allowed_channel_ids", "value": channelIds]
            )
        }
    }

    private func saveWhatsAppSettings() {
        if !whatsappAccessToken.isEmpty {
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": "channels.whatsapp.access_token", "value": whatsappAccessToken]
            )
        }
        if !whatsappPhoneNumberId.isEmpty {
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": "channels.whatsapp.phone_number_id", "value": whatsappPhoneNumberId]
            )
        }
        if !whatsappVerifyToken.isEmpty {
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": "channels.whatsapp.verify_token", "value": whatsappVerifyToken]
            )
        }
        let numbers = whatsappAllowedNumbers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !numbers.isEmpty {
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": "channels.whatsapp.allowed_numbers", "value": numbers]
            )
        }
    }
}

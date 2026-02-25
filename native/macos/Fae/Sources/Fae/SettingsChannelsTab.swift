import SwiftUI

/// Channels settings tab.
///
/// Channels are set up by asking Fae to install a skill — she walks through
/// configuration herself. This tab is the control panel: see what's connected,
/// disconnect individual channels, or kill everything at once if things go
/// sideways.
struct SettingsChannelsTab: View {
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager

    var commandSender: HostCommandSender?

    @AppStorage("fae.channels.enabled") private var channelsEnabled: Bool = true

    var body: some View {
        Form {
            // MARK: - Master kill switch

            Section {
                Toggle("Channels Enabled", isOn: $channelsEnabled)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .onChange(of: channelsEnabled) {
                        commandSender?.sendCommand(
                            name: "config.patch",
                            payload: ["key": "channels.enabled", "value": channelsEnabled]
                        )
                    }
                Text("Master switch. Turn off to immediately silence all external channel integrations — Discord, WhatsApp, and anything else. Good if things go sideways.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Discord

            Section("Discord") {
                channelInfoRow(
                    icon: "bubble.left.and.bubble.right.fill",
                    title: "Discord",
                    description: "Chat with Fae in any server or DM."
                )
                Button("Disconnect Discord") {
                    disconnectDiscord()
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
                Text("Clears the bot token and all Discord configuration from your local config.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // MARK: - WhatsApp

            Section("WhatsApp") {
                channelInfoRow(
                    icon: "phone.bubble.fill",
                    title: "WhatsApp Business",
                    description: "Message Fae directly from WhatsApp."
                )
                Button("Disconnect WhatsApp") {
                    disconnectWhatsApp()
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
                Text("Clears the access token, phone number ID, and verify token from your local config.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Setup

            Section("Connecting new channels") {
                Text("Just ask Fae — \"set up a Discord channel\" or \"connect me to WhatsApp\". She'll find the right skill and walk through setup herself. Credentials stay local.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Ask Fae to set up a channel") {
                    auxiliaryWindows.showConversation()
                }
                .buttonStyle(.bordered)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Row

    private func channelInfoRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Disconnect

    private func disconnectDiscord() {
        let keys = [
            "channels.discord.bot_token",
            "channels.discord.guild_id",
            "channels.discord.allowed_channel_ids"
        ]
        for key in keys {
            commandSender?.sendCommand(name: "config.patch", payload: ["key": key, "value": ""])
        }
    }

    private func disconnectWhatsApp() {
        let keys = [
            "channels.whatsapp.access_token",
            "channels.whatsapp.phone_number_id",
            "channels.whatsapp.verify_token",
            "channels.whatsapp.allowed_numbers"
        ]
        for key in keys {
            commandSender?.sendCommand(name: "config.patch", payload: ["key": key, "value": ""])
        }
    }
}

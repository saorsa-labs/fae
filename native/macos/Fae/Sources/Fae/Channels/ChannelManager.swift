import Foundation

/// Manages Discord and WhatsApp channel integrations.
///
/// Channel adapters feed incoming text into this actor and receive generated
/// responses through the configured `responseHandler` closure.
actor ChannelManager {
    typealias ResponseHandler = @Sendable (_ channel: String, _ sender: String, _ text: String) async -> String?

    private let eventBus: FaeEventBus
    private var isEnabled = false
    private var responseHandler: ResponseHandler?

    struct ChannelConfig: Codable, Sendable {
        var enabled: Bool = false
        var discord: DiscordConfig = DiscordConfig()
        var whatsapp: WhatsAppConfig = WhatsAppConfig()

        struct DiscordConfig: Codable, Sendable {
            var botToken: String?
            var guildId: String?
            var allowedChannelIds: [String] = []
        }

        struct WhatsAppConfig: Codable, Sendable {
            var accessToken: String?
            var phoneNumberId: String?
            var verifyToken: String?
            var allowedNumbers: [String] = []
        }
    }

    private var config: ChannelConfig

    init(eventBus: FaeEventBus, config: ChannelConfig = ChannelConfig()) {
        self.eventBus = eventBus
        self.config = config
    }

    func setResponseHandler(_ handler: @escaping ResponseHandler) {
        responseHandler = handler
    }

    func start() {
        guard config.enabled else {
            isEnabled = false
            NSLog("ChannelManager: disabled by config")
            return
        }

        let discordReady = config.discord.botToken?.isEmpty == false
        let whatsappReady = config.whatsapp.accessToken?.isEmpty == false

        guard discordReady || whatsappReady else {
            isEnabled = false
            NSLog("ChannelManager: enabled but no configured channel credentials")
            return
        }

        isEnabled = true
        NSLog("ChannelManager: started (discord=%@, whatsapp=%@)",
              discordReady ? "on" : "off",
              whatsappReady ? "on" : "off")
    }

    func stop() {
        isEnabled = false
        NSLog("ChannelManager: stopped")
    }

    func updateConfig(_ newConfig: ChannelConfig) {
        config = newConfig
        if isEnabled {
            stop()
            start()
        }
    }

    /// Handle an incoming message from a channel adapter.
    ///
    /// - Parameters:
    ///   - channel: channel identifier (`discord` or `whatsapp`)
    ///   - sender: sender identifier (user id / phone number)
    ///   - text: incoming text payload
    ///   - channelId: optional channel/thread identifier (used for allowlist checks)
    /// - Returns: response text to send back through the adapter, if any.
    func handleIncomingMessage(
        channel: String,
        sender: String,
        text: String,
        channelId: String? = nil
    ) async -> String? {
        guard isEnabled else {
            NSLog("ChannelManager: dropped message while disabled")
            return nil
        }

        let normalizedChannel = channel.lowercased()
        guard isSenderAllowed(on: normalizedChannel, sender: sender, channelId: channelId) else {
            NSLog("ChannelManager: denied sender %@ on %@", sender, normalizedChannel)
            return nil
        }

        guard let handler = responseHandler else {
            NSLog("ChannelManager: no response handler configured")
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        NSLog("ChannelManager: inbound %@ message from %@", normalizedChannel, sender)
        let response = await handler(normalizedChannel, sender, trimmed)
        if let response {
            NSLog("ChannelManager: produced %@ response (%d chars)", normalizedChannel, response.count)
            eventBus.send(.runtimeProgress(stage: "channel.response", progress: 1.0))
        }
        return response
    }

    private func isSenderAllowed(on channel: String, sender: String, channelId: String?) -> Bool {
        switch channel {
        case "discord":
            if !config.discord.allowedChannelIds.isEmpty {
                guard let channelId,
                      config.discord.allowedChannelIds.contains(channelId)
                else { return false }
            }
            return true

        case "whatsapp":
            if config.whatsapp.allowedNumbers.isEmpty {
                return true
            }
            return config.whatsapp.allowedNumbers.contains(sender)

        default:
            return false
        }
    }
}

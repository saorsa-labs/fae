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

    private var discordAdapter: DiscordAdapter?
    private var whatsappAdapter: WhatsAppAdapter?
    private var imessageAdapter: IMessageAdapter?

    struct ChannelConfig: Codable, Sendable {
        var enabled: Bool = false
        var discord: DiscordConfig = DiscordConfig()
        var whatsapp: WhatsAppConfig = WhatsAppConfig()
        var imessage: IMessageConfig = IMessageConfig()

        struct DiscordConfig: Codable, Sendable {
            var botToken: String?
            var guildId: String?
            var allowedChannelIds: [String] = []
        }

        struct WhatsAppConfig: Codable, Sendable {
            var accessToken: String?
            var phoneNumberId: String?
            var verifyToken: String?
            var appSecret: String?
            var allowedNumbers: [String] = []
            var webhookPort: UInt16 = 8443
        }

        struct IMessageConfig: Codable, Sendable {
            var enabled: Bool = false
            var allowedSenders: [String] = []
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

    func start() async {
        guard config.enabled else {
            isEnabled = false
            NSLog("ChannelManager: disabled by config")
            return
        }

        let discordReady = config.discord.botToken?.isEmpty == false
        let whatsappReady = config.whatsapp.accessToken?.isEmpty == false
            && config.whatsapp.phoneNumberId?.isEmpty == false
            && config.whatsapp.verifyToken?.isEmpty == false
        let imessageReady = config.imessage.enabled

        guard discordReady || whatsappReady || imessageReady else {
            isEnabled = false
            NSLog("ChannelManager: enabled but no configured channel credentials")
            return
        }

        isEnabled = true

        if discordReady {
            let adapter = DiscordAdapter(
                config: config.discord,
                messageHandler: { [weak self] senderId, channelId, text in
                    guard let self else { return nil }
                    return await self.handleIncomingMessage(
                        channel: "discord", sender: senderId, text: text, channelId: channelId
                    )
                }
            )
            discordAdapter = adapter
            await adapter.start()
        }

        if whatsappReady {
            let waConfig = WhatsAppAdapter.Config(
                accessToken: config.whatsapp.accessToken ?? "",
                phoneNumberId: config.whatsapp.phoneNumberId ?? "",
                verifyToken: config.whatsapp.verifyToken ?? "",
                allowedNumbers: config.whatsapp.allowedNumbers,
                webhookPath: "/webhook",
                appSecret: config.whatsapp.appSecret
            )
            let adapter = WhatsAppAdapter(config: waConfig)
            await adapter.setMessageHandler { [weak self] sender, text in
                guard let self else { return nil }
                return await self.handleIncomingMessage(
                    channel: "whatsapp", sender: sender, text: text
                )
            }
            do {
                try await adapter.start(port: config.whatsapp.webhookPort)
                whatsappAdapter = adapter
            } catch {
                NSLog("ChannelManager: failed to start WhatsApp adapter — %@", error.localizedDescription)
            }
        }

        if config.imessage.enabled {
            let adapter = IMessageAdapter { [weak self] message in
                guard let self else { return }
                if let reply = await self.handleIncomingMessage(
                    channel: "imessage", sender: message.sender, text: message.text
                ) {
                    await self.replyViaIMessage(text: reply, to: message.sender)
                }
            }
            imessageAdapter = adapter
            await adapter.start()
        }

        NSLog("ChannelManager: started (discord=%@, whatsapp=%@, imessage=%@)",
              discordReady ? "on" : "off",
              whatsappReady ? "on" : "off",
              config.imessage.enabled ? "on" : "off")
    }

    func stop() async {
        if let adapter = discordAdapter {
            await adapter.stop()
            discordAdapter = nil
        }
        if let adapter = whatsappAdapter {
            await adapter.stop()
            whatsappAdapter = nil
        }
        if let adapter = imessageAdapter {
            await adapter.stop()
            imessageAdapter = nil
        }
        isEnabled = false
        NSLog("ChannelManager: stopped")
    }

    func updateConfig(_ newConfig: ChannelConfig) async {
        config = newConfig
        await stop()
        await start()
    }

    /// Handle an incoming message from a channel adapter.
    ///
    /// - Parameters:
    ///   - channel: channel identifier (`discord`, `whatsapp`, or `imessage`)
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

    private func replyViaIMessage(text: String, to sender: String) async {
        try? await imessageAdapter?.sendReply(text: text, to: sender)
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

        case "imessage":
            if config.imessage.allowedSenders.isEmpty {
                return true
            }
            return config.imessage.allowedSenders.contains(sender)

        default:
            return false
        }
    }
}

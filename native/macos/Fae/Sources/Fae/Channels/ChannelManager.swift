import Foundation

/// Manages Discord and WhatsApp channel integrations.
///
/// Routes incoming messages from external channels into the LLM pipeline
/// and sends responses back through webhooks.
///
/// Replaces: `src/channels/` (1,736 lines)
actor ChannelManager {
    private let eventBus: FaeEventBus
    private var isEnabled = false

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

    func start() {
        guard config.enabled else {
            NSLog("ChannelManager: disabled")
            return
        }
        isEnabled = true
        NSLog("ChannelManager: started")
        // TODO: Connect to Discord bot, start WhatsApp webhook listener
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

    /// Handle an incoming message from a channel.
    func handleIncomingMessage(channel: String, sender: String, text: String) {
        guard isEnabled else { return }
        NSLog("ChannelManager: message from %@ on %@: %@", sender, channel, text)
        // TODO: Route to LLM pipeline, send response back through channel
    }
}

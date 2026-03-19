import Foundation

/// Central routing actor for all channel messages.
///
/// `ChannelGateway` replaces `ChannelManager` as the single entry point for
/// external messaging. It:
/// - Owns all `ChannelAdapter` instances
/// - Receives normalised `ChannelMessage` from adapters
/// - Resolves per-sender `ChannelSession` via `ChannelSessionStore`
/// - Serialises dispatch (no concurrent `processTranscription` calls)
/// - Routes responses back to the originating adapter
/// - Emits `FaeEvent`s for channel activity
///
/// ```
/// Adapters ──→ ChannelGateway ──→ ChannelSessionStore ──→ responseHandler ──→ Adapter.send()
/// ```
actor ChannelGateway {
    /// Handler that processes a channel message and returns an optional response.
    ///
    /// The gateway calls this for every validated inbound message. The handler
    /// should run the message through the LLM pipeline and return the assistant's
    /// response text.
    typealias ResponseHandler = @Sendable (
        _ message: ChannelMessage,
        _ session: ChannelSession
    ) async -> String?

    private let eventBus: FaeEventBus
    private let sessionStore: ChannelSessionStore
    private let identityResolver: ChannelIdentityResolver
    private var adapters: [ChannelKind: any ChannelAdapter] = [:]
    private var responseHandler: ResponseHandler?
    private var isRunning = false

    /// Create a new gateway with the given event bus.
    ///
    /// - Parameters:
    ///   - eventBus: The event bus for emitting channel activity events.
    ///   - sessionStore: The session store (injected for testability).
    ///   - identityResolver: The identity resolver (injected for testability).
    init(
        eventBus: FaeEventBus,
        sessionStore: ChannelSessionStore = ChannelSessionStore(),
        identityResolver: ChannelIdentityResolver = ChannelIdentityResolver()
    ) {
        self.eventBus = eventBus
        self.sessionStore = sessionStore
        self.identityResolver = identityResolver
    }

    /// The identity resolver used by this gateway for cross-channel identity linking.
    var resolver: ChannelIdentityResolver {
        identityResolver
    }

    /// Set the handler that processes inbound messages through the LLM pipeline.
    func setResponseHandler(_ handler: @escaping ResponseHandler) {
        responseHandler = handler
    }

    /// Register an adapter with the gateway.
    ///
    /// The gateway takes ownership and wires the adapter's `onMessage` callback
    /// to route through the gateway. If an adapter for the same `ChannelKind`
    /// already exists, the old one is stopped first.
    func registerAdapter(_ adapter: any ChannelAdapter) async {
        let kind = adapter.kind

        // Stop existing adapter for this channel if present.
        if let existing = adapters[kind] {
            await existing.stop()
        }

        // Wire the adapter's message callback to route through the gateway.
        adapter.onMessage = { [weak self] message in
            guard let self else { return nil }
            return await self.handleIncomingMessage(message)
        }

        adapters[kind] = adapter
    }

    /// Start all registered adapters.
    func start() async {
        guard !isRunning else { return }
        isRunning = true

        for (kind, adapter) in adapters {
            do {
                try await adapter.start()
                NSLog("ChannelGateway: started %@ adapter", kind.displayName)
            } catch {
                NSLog("ChannelGateway: failed to start %@ adapter — %@",
                      kind.displayName, error.localizedDescription)
            }
        }

        NSLog("ChannelGateway: running with %d adapter(s)", adapters.count)
    }

    /// Stop all adapters and clean up sessions.
    func stop() async {
        guard isRunning else { return }

        for (kind, adapter) in adapters {
            await adapter.stop()
            NSLog("ChannelGateway: stopped %@ adapter", kind.displayName)
        }

        isRunning = false
        NSLog("ChannelGateway: stopped")
    }

    /// The number of currently active sessions across all channels.
    var activeSessionCount: Int {
        get async {
            await sessionStore.activeSessionCount
        }
    }

    /// Clean up idle sessions older than the given timeout.
    ///
    /// - Parameter timeout: Idle duration threshold (defaults to session store default).
    /// - Returns: Number of sessions cleaned up.
    @discardableResult
    func cleanupIdleSessions(olderThan timeout: TimeInterval? = nil) async -> Int {
        await sessionStore.cleanupIdle(olderThan: timeout)
    }

    // MARK: - Message Handling

    /// Handle an inbound message from any adapter.
    ///
    /// This method serialises all message processing through the actor, ensuring
    /// no concurrent `processTranscription` calls. Each message gets its own
    /// session based on channel + sender.
    private func handleIncomingMessage(_ message: ChannelMessage) async -> String? {
        guard isRunning else {
            NSLog("ChannelGateway: dropped message while not running")
            return nil
        }

        guard let handler = responseHandler else {
            NSLog("ChannelGateway: no response handler configured")
            return nil
        }

        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Attempt identity auto-linking for phone-based channels.
        await attemptAutoLink(for: message)

        // Resolve or create per-sender session.
        let key = SessionKey(channel: message.channel, senderId: message.senderId)
        let session = await sessionStore.session(
            for: key,
            displayName: message.senderDisplayName
        )

        // Inject cross-channel context if identities are linked.
        let crossChannelContext = await buildCrossChannelContext(for: message)

        NSLog("ChannelGateway: inbound %@ message from %@ (session messages: %d, cross-channel: %@)",
              message.channel.displayName, message.senderId, session.messages.count,
              crossChannelContext != nil ? "yes" : "no")

        // Enrich message with cross-channel context if available.
        let enrichedMessage: ChannelMessage
        if let context = crossChannelContext {
            enrichedMessage = ChannelMessage(
                id: message.id,
                channel: message.channel,
                senderId: message.senderId,
                senderDisplayName: message.senderDisplayName,
                text: message.text,
                timestamp: message.timestamp,
                threadId: message.threadId,
                replyToId: message.replyToId,
                attachments: message.attachments,
                crossChannelContext: context
            )
        } else {
            enrichedMessage = message
        }

        // Dispatch through the pipeline.
        let response = await handler(enrichedMessage, session)

        if let response {
            let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedResponse.isEmpty else { return nil }

            NSLog("ChannelGateway: produced %@ response (%d chars)",
                  message.channel.displayName, trimmedResponse.count)

            eventBus.send(.runtimeProgress(stage: "channel.response", progress: 1.0))

            // Route response back to the originating adapter.
            if let adapter = adapters[message.channel] {
                do {
                    try await adapter.send(response: trimmedResponse, to: message)
                } catch {
                    NSLog("ChannelGateway: failed to send response via %@ — %@",
                          message.channel.displayName, error.localizedDescription)
                }
            }

            return trimmedResponse
        }

        return nil
    }

    // MARK: - Identity Linking

    /// Attempt to auto-link the sender's identity across channels.
    ///
    /// For phone-based channels (WhatsApp, iMessage), this normalises the phone
    /// number and checks if the same number exists on another channel. For all
    /// channels, display name matching is attempted.
    private func attemptAutoLink(for message: ChannelMessage) async {
        // Check if already resolved.
        let existing = await identityResolver.resolve(
            channel: message.channel, senderId: message.senderId
        )
        if existing != nil { return }

        // Try phone-based linking for WhatsApp and iMessage.
        let isPhoneChannel = message.channel == .whatsapp || message.channel == .imessage
        if isPhoneChannel {
            let matched = await identityResolver.autoLinkByPhone(
                channel: message.channel,
                senderId: message.senderId,
                displayName: message.senderDisplayName
            )
            if matched != nil { return }
        }

        // Try display name matching if a display name is available.
        if let displayName = message.senderDisplayName, !displayName.isEmpty {
            let matched = await identityResolver.autoLinkByDisplayName(
                channel: message.channel,
                senderId: message.senderId,
                displayName: displayName
            )
            if matched != nil { return }
        }

        // Register this sender as a new standalone identity for future matching.
        await identityResolver.link(
            channel: message.channel,
            senderId: message.senderId,
            displayName: message.senderDisplayName,
            source: .manual
        )
    }

    /// Build cross-channel context string for the LLM if identities are linked.
    ///
    /// Returns a human-readable summary of the sender's activity on other channels,
    /// including recent conversation snippets for continuity.
    private func buildCrossChannelContext(for message: ChannelMessage) async -> String? {
        let linkedKeys = await identityResolver.linkedSessionKeys(
            channel: message.channel, senderId: message.senderId
        )
        guard !linkedKeys.isEmpty else { return nil }

        let summaries = await sessionStore.linkedSessionSummaries(for: linkedKeys)
        guard !summaries.isEmpty else { return nil }

        let identity = await identityResolver.resolve(
            channel: message.channel, senderId: message.senderId
        )
        let name = identity?.displayName ?? message.senderDisplayName ?? message.senderId

        var context = "Cross-channel context for \(name):\n"
        for summary in summaries {
            context += summary.formattedContext + "\n"
        }

        return context
    }
}

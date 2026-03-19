import FaeInference
import XCTest
@testable import Fae

// MARK: - End-to-End Integration Tests

/// Integration tests verifying the full message flow:
/// message arrives → gateway → pipeline handler → response → adapter.send()
///
/// Uses mock adapters that simulate each platform's message format.
final class ChannelIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func makeFullGateway() -> (
        gateway: ChannelGateway,
        sessionStore: ChannelSessionStore,
        resolver: ChannelIdentityResolver,
        monitor: ChannelHealthMonitor,
        discord: IntegrationMockAdapter,
        whatsapp: IntegrationMockAdapter,
        imessage: IntegrationMockAdapter
    ) {
        let sessionStore = ChannelSessionStore()
        let resolver = ChannelIdentityResolver()
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(checkIntervalSeconds: 999)
        )
        let gateway = ChannelGateway(
            eventBus: FaeEventBus(),
            sessionStore: sessionStore,
            identityResolver: resolver,
            healthMonitor: monitor
        )
        let discord = IntegrationMockAdapter(kind: .discord)
        let whatsapp = IntegrationMockAdapter(kind: .whatsapp)
        let imessage = IntegrationMockAdapter(kind: .imessage)

        return (gateway, sessionStore, resolver, monitor, discord, whatsapp, imessage)
    }

    // MARK: - Discord E2E

    func testDiscordMessageFullRoundTrip() async {
        let (gateway, sessionStore, _, _, discord, _, _) = makeFullGateway()

        await gateway.registerAdapter(discord)
        await gateway.setResponseHandler { message, session in
            session.addUserMessage(message.text)
            let reply = "Hello \(message.senderDisplayName ?? "user")! You said: \(message.text)"
            session.addAssistantMessage(reply)
            return reply
        }
        await gateway.start()

        let msg = ChannelMessage(
            id: "discord-msg-001",
            channel: .discord,
            senderId: "user-42",
            senderDisplayName: "Alice",
            text: "What's the weather?",
            threadId: "channel-123"
        )

        let response = await discord.simulateInbound(msg)

        // Verify response was generated.
        XCTAssertEqual(response, "Hello Alice! You said: What's the weather?")

        // Verify response was sent back via the adapter.
        XCTAssertEqual(discord.sentResponses.count, 1)
        XCTAssertEqual(discord.sentResponses[0].response, "Hello Alice! You said: What's the weather?")
        XCTAssertEqual(discord.sentResponses[0].message.senderId, "user-42")

        // Verify session was created and populated.
        let sessionCount = await sessionStore.activeSessionCount
        XCTAssertGreaterThanOrEqual(sessionCount, 1)

        await gateway.stop()
    }

    // MARK: - WhatsApp E2E

    func testWhatsAppMessageFullRoundTrip() async {
        let (gateway, _, _, _, _, whatsapp, _) = makeFullGateway()

        await gateway.registerAdapter(whatsapp)
        await gateway.setResponseHandler { message, session in
            session.addUserMessage(message.text)
            let reply = "Received from \(message.channel.displayName): \(message.text)"
            session.addAssistantMessage(reply)
            return reply
        }
        await gateway.start()

        let msg = ChannelMessage(
            id: "wa-msg-001",
            channel: .whatsapp,
            senderId: "+1234567890",
            senderDisplayName: "Bob",
            text: "Remind me about the meeting"
        )

        let response = await whatsapp.simulateInbound(msg)

        XCTAssertEqual(response, "Received from WhatsApp: Remind me about the meeting")
        XCTAssertEqual(whatsapp.sentResponses.count, 1)

        await gateway.stop()
    }

    // MARK: - iMessage E2E

    func testIMessageMessageFullRoundTrip() async {
        let (gateway, _, _, _, _, _, imessage) = makeFullGateway()

        await gateway.registerAdapter(imessage)
        await gateway.setResponseHandler { message, session in
            session.addUserMessage(message.text)
            let reply = "iMessage reply to \(message.senderId)"
            session.addAssistantMessage(reply)
            return reply
        }
        await gateway.start()

        let msg = ChannelMessage(
            id: "imsg-001",
            channel: .imessage,
            senderId: "alice@icloud.com",
            senderDisplayName: "Alice",
            text: "Check my calendar"
        )

        let response = await imessage.simulateInbound(msg)

        XCTAssertEqual(response, "iMessage reply to alice@icloud.com")
        XCTAssertEqual(imessage.sentResponses.count, 1)

        await gateway.stop()
    }

    // MARK: - Multi-Channel E2E

    func testMultiChannelSimultaneousMessages() async {
        let (gateway, sessionStore, _, _, discord, whatsapp, imessage) = makeFullGateway()

        await gateway.registerAdapter(discord)
        await gateway.registerAdapter(whatsapp)
        await gateway.registerAdapter(imessage)

        var processedChannels: [ChannelKind] = []
        await gateway.setResponseHandler { message, session in
            processedChannels.append(message.channel)
            session.addUserMessage(message.text)
            let reply = "\(message.channel.displayName) reply"
            session.addAssistantMessage(reply)
            return reply
        }
        await gateway.start()

        let discordMsg = ChannelMessage(channel: .discord, senderId: "alice", text: "Discord hello")
        let whatsappMsg = ChannelMessage(channel: .whatsapp, senderId: "+1111", text: "WhatsApp hello")
        let imessageMsg = ChannelMessage(channel: .imessage, senderId: "bob@icloud.com", text: "iMessage hello")

        // Process all three sequentially (gateway actor serialises).
        _ = await discord.simulateInbound(discordMsg)
        _ = await whatsapp.simulateInbound(whatsappMsg)
        _ = await imessage.simulateInbound(imessageMsg)

        // All three channels should have been processed.
        XCTAssertEqual(processedChannels.count, 3)
        XCTAssertTrue(processedChannels.contains(.discord))
        XCTAssertTrue(processedChannels.contains(.whatsapp))
        XCTAssertTrue(processedChannels.contains(.imessage))

        // Each adapter should have received its response.
        XCTAssertEqual(discord.sentResponses.count, 1)
        XCTAssertEqual(discord.sentResponses[0].response, "Discord reply")
        XCTAssertEqual(whatsapp.sentResponses.count, 1)
        XCTAssertEqual(whatsapp.sentResponses[0].response, "WhatsApp reply")
        XCTAssertEqual(imessage.sentResponses.count, 1)
        XCTAssertEqual(imessage.sentResponses[0].response, "iMessage reply")

        // Sessions should be isolated — 3 different senders.
        let count = await sessionStore.activeSessionCount
        XCTAssertGreaterThanOrEqual(count, 3)

        await gateway.stop()
    }

    // MARK: - Cross-Channel Identity E2E

    func testCrossChannelIdentityLinkingE2E() async {
        let (gateway, sessionStore, resolver, _, _, whatsapp, imessage) = makeFullGateway()

        await gateway.registerAdapter(whatsapp)
        await gateway.registerAdapter(imessage)

        var capturedContexts: [String?] = []
        await gateway.setResponseHandler { message, session in
            capturedContexts.append(message.crossChannelContext)
            session.addUserMessage(message.text)
            session.addAssistantMessage("Reply")
            return "Reply"
        }
        await gateway.start()

        // Step 1: Alice messages on WhatsApp.
        _ = await whatsapp.simulateInbound(
            ChannelMessage(
                channel: .whatsapp, senderId: "+1234567890",
                senderDisplayName: "Alice", text: "WhatsApp message"
            )
        )

        // Step 2: Manually link the identities (simulating auto-link result).
        let waIdentity = await resolver.resolve(channel: .whatsapp, senderId: "+1234567890")
        if let canonicalId = waIdentity?.id {
            await resolver.link(
                channel: .imessage, senderId: "+1234567890",
                displayName: "Alice", canonicalId: canonicalId, source: .phoneMatch
            )
        }

        // Step 3: Alice messages on iMessage — should have cross-channel context.
        _ = await imessage.simulateInbound(
            ChannelMessage(
                channel: .imessage, senderId: "+1234567890",
                senderDisplayName: "Alice", text: "iMessage follow-up"
            )
        )

        XCTAssertEqual(capturedContexts.count, 2)
        // First message: no cross-channel context.
        XCTAssertNil(capturedContexts[0])
        // Second message: should have WhatsApp context.
        XCTAssertNotNil(capturedContexts[1])
        if let context = capturedContexts[1] {
            XCTAssertTrue(context.contains("WhatsApp"))
            XCTAssertTrue(context.contains("WhatsApp message"))
        }

        await gateway.stop()
    }

    // MARK: - Handler Returns Nil

    func testNilResponseDoesNotSendToAdapter() async {
        let (gateway, _, _, _, discord, _, _) = makeFullGateway()

        await gateway.registerAdapter(discord)
        await gateway.setResponseHandler { _, _ in nil }
        await gateway.start()

        _ = await discord.simulateInbound(
            ChannelMessage(channel: .discord, senderId: "user-1", text: "Hello")
        )

        XCTAssertTrue(discord.sentResponses.isEmpty)

        await gateway.stop()
    }

    // MARK: - Empty Response

    func testEmptyResponseNotSentToAdapter() async {
        let (gateway, _, _, _, discord, _, _) = makeFullGateway()

        await gateway.registerAdapter(discord)
        await gateway.setResponseHandler { _, _ in "   " }
        await gateway.start()

        _ = await discord.simulateInbound(
            ChannelMessage(channel: .discord, senderId: "user-1", text: "Hello")
        )

        XCTAssertTrue(discord.sentResponses.isEmpty)

        await gateway.stop()
    }

    // MARK: - Conversation Continuity

    func testMultiTurnConversationMaintainsHistory() async {
        let (gateway, sessionStore, _, _, discord, _, _) = makeFullGateway()

        await gateway.registerAdapter(discord)
        await gateway.setResponseHandler { message, session in
            let historyCount = session.messages.count
            session.addUserMessage(message.text)
            let reply = "Turn \(historyCount / 2 + 1) reply"
            session.addAssistantMessage(reply)
            return reply
        }
        await gateway.start()

        let sender = "alice"

        _ = await discord.simulateInbound(
            ChannelMessage(channel: .discord, senderId: sender, text: "First message")
        )
        _ = await discord.simulateInbound(
            ChannelMessage(channel: .discord, senderId: sender, text: "Second message")
        )
        _ = await discord.simulateInbound(
            ChannelMessage(channel: .discord, senderId: sender, text: "Third message")
        )

        // Session should have 6 messages (3 user + 3 assistant).
        let key = SessionKey(channel: .discord, senderId: sender)
        let session = await sessionStore.session(for: key)
        XCTAssertEqual(session.messages.count, 6)
        XCTAssertEqual(session.messages[0].role, .user)
        XCTAssertEqual(session.messages[0].content, "First message")
        XCTAssertEqual(session.messages[5].role, .assistant)
        XCTAssertEqual(session.messages[5].content, "Turn 3 reply")

        // Adapter should have 3 responses.
        XCTAssertEqual(discord.sentResponses.count, 3)

        await gateway.stop()
    }

    // MARK: - Health Status After Start

    func testHealthStatusAfterFullStartup() async {
        let (gateway, _, _, monitor, discord, whatsapp, _) = makeFullGateway()

        await gateway.registerAdapter(discord)
        await gateway.registerAdapter(whatsapp)
        await gateway.start()

        let discordStatus = await monitor.status(for: .discord)
        let whatsappStatus = await monitor.status(for: .whatsapp)

        XCTAssertEqual(discordStatus, .connected)
        XCTAssertEqual(whatsappStatus, .connected)

        await gateway.stop()
    }

    // MARK: - Adapter Send Error

    func testAdapterSendErrorReportsToHealthMonitor() async {
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(checkIntervalSeconds: 999)
        )
        let gateway = ChannelGateway(
            eventBus: FaeEventBus(),
            healthMonitor: monitor
        )

        let failingAdapter = IntegrationMockAdapter(kind: .discord, shouldFailSend: true)
        await gateway.registerAdapter(failingAdapter)
        await gateway.setResponseHandler { _, _ in "response" }
        await gateway.start()

        _ = await failingAdapter.simulateInbound(
            ChannelMessage(channel: .discord, senderId: "user-1", text: "Hello")
        )

        // The health monitor should have the error reported.
        let status = await monitor.status(for: .discord)
        if case .error(let msg) = status {
            XCTAssertTrue(msg.contains("send failed"))
        } else {
            XCTFail("Expected error status after send failure, got \(String(describing: status))")
        }

        await gateway.stop()
    }
}

// MARK: - Integration Mock Adapter

/// Mock adapter for integration testing that tracks all interactions.
private final class IntegrationMockAdapter: ChannelAdapter, @unchecked Sendable {
    let kind: ChannelKind
    var onMessage: (@Sendable (ChannelMessage) async -> String?)?

    private let lock = NSLock()
    private var _sentResponses: [(response: String, message: ChannelMessage)] = []
    private let shouldFailSend: Bool

    var sentResponses: [(response: String, message: ChannelMessage)] {
        lock.lock()
        defer { lock.unlock() }
        return _sentResponses
    }

    init(kind: ChannelKind, shouldFailSend: Bool = false) {
        self.kind = kind
        self.shouldFailSend = shouldFailSend
    }

    func start() async throws {}
    func stop() async {}

    func send(response: String, to message: ChannelMessage) async throws {
        if shouldFailSend {
            throw NSError(domain: "test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "simulated send failure",
            ])
        }
        lock.lock()
        _sentResponses.append((response: response, message: message))
        lock.unlock()
    }

    func simulateInbound(_ message: ChannelMessage) async -> String? {
        await onMessage?(message)
    }
}

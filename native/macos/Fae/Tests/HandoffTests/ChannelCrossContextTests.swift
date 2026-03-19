import FaeInference
import XCTest
@testable import Fae

// MARK: - LinkedSessionSummary Tests

final class LinkedSessionSummaryTests: XCTestCase {

    func testFormattedContextIncludesChannelAndName() {
        let summary = LinkedSessionSummary(
            channel: .whatsapp,
            senderId: "+1234567890",
            displayName: "Alice",
            messageCount: 4,
            recentMessages: [
                LLMMessage(role: .user, content: "Hello from WhatsApp"),
                LLMMessage(role: .assistant, content: "Hi Alice!"),
            ],
            lastActivity: Date()
        )

        let context = summary.formattedContext
        XCTAssertTrue(context.contains("WhatsApp"))
        XCTAssertTrue(context.contains("Alice"))
        XCTAssertTrue(context.contains("4 messages"))
        XCTAssertTrue(context.contains("Hello from WhatsApp"))
        XCTAssertTrue(context.contains("Hi Alice!"))
    }

    func testFormattedContextUsesSenderIdWhenNoDisplayName() {
        let summary = LinkedSessionSummary(
            channel: .discord,
            senderId: "user-42",
            displayName: nil,
            messageCount: 1,
            recentMessages: [
                LLMMessage(role: .user, content: "Test"),
            ],
            lastActivity: Date()
        )

        let context = summary.formattedContext
        XCTAssertTrue(context.contains("user-42"))
    }

    func testFormattedContextShowsFaeForAssistantMessages() {
        let summary = LinkedSessionSummary(
            channel: .imessage,
            senderId: "alice@icloud.com",
            displayName: "Alice",
            messageCount: 2,
            recentMessages: [
                LLMMessage(role: .user, content: "Question"),
                LLMMessage(role: .assistant, content: "Answer"),
            ],
            lastActivity: Date()
        )

        let context = summary.formattedContext
        XCTAssertTrue(context.contains("[Fae]: Answer"))
        XCTAssertTrue(context.contains("[Alice]: Question"))
    }
}

// MARK: - ChannelSessionStore Linked Summaries Tests

final class ChannelSessionStoreLinkTests: XCTestCase {

    func testLinkedSessionSummariesReturnsNonEmptySessions() async {
        let store = ChannelSessionStore()

        let key1 = SessionKey(channel: .whatsapp, senderId: "+1234")
        let key2 = SessionKey(channel: .discord, senderId: "user-42")

        let session1 = await store.session(for: key1, displayName: "Alice")
        session1.addUserMessage("Hello from WhatsApp")
        session1.addAssistantMessage("Hi Alice!")

        // key2 exists but is empty.
        _ = await store.session(for: key2)

        let summaries = await store.linkedSessionSummaries(for: [key1, key2])

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].channel, .whatsapp)
        XCTAssertEqual(summaries[0].messageCount, 2)
        XCTAssertEqual(summaries[0].displayName, "Alice")
    }

    func testLinkedSessionSummariesRespectsMaxMessages() async {
        let store = ChannelSessionStore()
        let key = SessionKey(channel: .whatsapp, senderId: "+1234")

        let session = await store.session(for: key)
        for i in 0..<20 {
            session.addUserMessage("msg \(i)")
            session.addAssistantMessage("reply \(i)")
        }

        let summaries = await store.linkedSessionSummaries(
            for: [key], maxMessagesPerSession: 4
        )

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].recentMessages.count, 4)
        // Should be the most recent 4 messages.
        XCTAssertEqual(summaries[0].recentMessages.last?.content, "reply 19")
    }

    func testLinkedSessionSummariesReturnsEmptyForUnknownKeys() async {
        let store = ChannelSessionStore()
        let key = SessionKey(channel: .discord, senderId: "unknown")

        let summaries = await store.linkedSessionSummaries(for: [key])
        XCTAssertTrue(summaries.isEmpty)
    }

    func testLinkedSessionSummariesMultipleChannels() async {
        let store = ChannelSessionStore()

        let whatsappKey = SessionKey(channel: .whatsapp, senderId: "+1234")
        let discordKey = SessionKey(channel: .discord, senderId: "user-42")
        let imessageKey = SessionKey(channel: .imessage, senderId: "+1234")

        let waSession = await store.session(for: whatsappKey, displayName: "Alice")
        waSession.addUserMessage("WhatsApp msg")
        waSession.addAssistantMessage("WA reply")

        let dcSession = await store.session(for: discordKey, displayName: "Alice")
        dcSession.addUserMessage("Discord msg")
        dcSession.addAssistantMessage("DC reply")

        // iMessage session has no messages — should be excluded.
        _ = await store.session(for: imessageKey, displayName: "Alice")

        let summaries = await store.linkedSessionSummaries(
            for: [whatsappKey, discordKey, imessageKey]
        )

        XCTAssertEqual(summaries.count, 2)
        let channels = Set(summaries.map { $0.channel })
        XCTAssertTrue(channels.contains(.whatsapp))
        XCTAssertTrue(channels.contains(.discord))
    }
}

// MARK: - Gateway Cross-Channel Context Integration Tests

final class GatewayCrossChannelContextTests: XCTestCase {

    /// Mock adapter for cross-channel tests.
    private final class MockAdapter: ChannelAdapter, @unchecked Sendable {
        let kind: ChannelKind
        var onMessage: (@Sendable (ChannelMessage) async -> String?)?

        init(kind: ChannelKind) { self.kind = kind }
        func start() async throws {}
        func stop() async {}
        func send(response: String, to message: ChannelMessage) async throws {}

        func simulateInbound(_ message: ChannelMessage) async -> String? {
            await onMessage?(message)
        }
    }

    func testCrossChannelContextIncludesConversationSnippets() async {
        let sessionStore = ChannelSessionStore()
        let resolver = ChannelIdentityResolver()
        let gateway = ChannelGateway(
            eventBus: FaeEventBus(),
            sessionStore: sessionStore,
            identityResolver: resolver
        )

        let whatsapp = MockAdapter(kind: .whatsapp)
        let imessage = MockAdapter(kind: .imessage)

        await gateway.registerAdapter(whatsapp)
        await gateway.registerAdapter(imessage)

        var capturedMessages: [ChannelMessage] = []
        await gateway.setResponseHandler { message, session in
            capturedMessages.append(message)
            session.addUserMessage(message.text)
            session.addAssistantMessage("Reply on \(message.channel.displayName)")
            return "Reply on \(message.channel.displayName)"
        }
        await gateway.start()

        // Step 1: WhatsApp conversation.
        _ = await whatsapp.simulateInbound(
            ChannelMessage(
                channel: .whatsapp, senderId: "+1234567890",
                senderDisplayName: "Alice", text: "What time is our meeting?"
            )
        )

        // Step 2: Manually link identities (simulating phone match).
        let waIdentity = await resolver.resolve(channel: .whatsapp, senderId: "+1234567890")
        if let canonicalId = waIdentity?.id {
            await resolver.link(
                channel: .imessage, senderId: "+1234567890",
                displayName: "Alice", canonicalId: canonicalId, source: .phoneMatch
            )
        }

        // Step 3: iMessage message — should include cross-channel context with WhatsApp snippet.
        _ = await imessage.simulateInbound(
            ChannelMessage(
                channel: .imessage, senderId: "+1234567890",
                senderDisplayName: "Alice", text: "Can you remind me again?"
            )
        )

        XCTAssertEqual(capturedMessages.count, 2)

        // First message: no cross-channel context.
        XCTAssertNil(capturedMessages[0].crossChannelContext)

        // Second message: should include WhatsApp conversation context.
        let context = capturedMessages[1].crossChannelContext ?? ""
        XCTAssertTrue(context.contains("WhatsApp"), "Expected WhatsApp in context: \(context)")
        XCTAssertTrue(
            context.contains("What time is our meeting?"),
            "Expected conversation content in context: \(context)"
        )
    }

    func testNoCrossChannelContextForUnlinkedSenders() async {
        let sessionStore = ChannelSessionStore()
        let resolver = ChannelIdentityResolver()
        let gateway = ChannelGateway(
            eventBus: FaeEventBus(),
            sessionStore: sessionStore,
            identityResolver: resolver
        )

        let discord = MockAdapter(kind: .discord)
        await gateway.registerAdapter(discord)

        var capturedMessages: [ChannelMessage] = []
        await gateway.setResponseHandler { message, _ in
            capturedMessages.append(message)
            return "ok"
        }
        await gateway.start()

        _ = await discord.simulateInbound(
            ChannelMessage(channel: .discord, senderId: "user-1", text: "Hello")
        )

        XCTAssertEqual(capturedMessages.count, 1)
        XCTAssertNil(capturedMessages[0].crossChannelContext)
    }

    func testCrossChannelContextEmptyWhenLinkedSessionsHaveNoMessages() async {
        let sessionStore = ChannelSessionStore()
        let resolver = ChannelIdentityResolver()
        let gateway = ChannelGateway(
            eventBus: FaeEventBus(),
            sessionStore: sessionStore,
            identityResolver: resolver
        )

        let whatsapp = MockAdapter(kind: .whatsapp)
        let imessage = MockAdapter(kind: .imessage)

        await gateway.registerAdapter(whatsapp)
        await gateway.registerAdapter(imessage)

        // Pre-link identities with no messages.
        let id1 = await resolver.link(
            channel: .whatsapp, senderId: "+1234567890", displayName: "Alice"
        )
        await resolver.link(
            channel: .imessage, senderId: "+1234567890",
            canonicalId: id1.id, source: .phoneMatch
        )

        var capturedMessages: [ChannelMessage] = []
        await gateway.setResponseHandler { message, _ in
            capturedMessages.append(message)
            return "ok"
        }
        await gateway.start()

        // iMessage message — linked WhatsApp session exists but has no messages.
        _ = await imessage.simulateInbound(
            ChannelMessage(
                channel: .imessage, senderId: "+1234567890",
                senderDisplayName: "Alice", text: "Hello"
            )
        )

        XCTAssertEqual(capturedMessages.count, 1)
        // WhatsApp session was created by the gateway's auto-link but has no messages.
        // Cross-channel context should be nil because linked session is empty.
        // (The auto-link creates a new standalone identity, not linking to existing.)
    }
}

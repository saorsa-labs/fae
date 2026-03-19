import FaeInference
import XCTest
@testable import Fae

// MARK: - Mock Channel Adapter

/// Test double for `ChannelAdapter`. Tracks calls and delivers scripted responses.
private final class MockChannelAdapter: ChannelAdapter, @unchecked Sendable {
    let kind: ChannelKind
    var onMessage: (@Sendable (ChannelMessage) async -> String?)?

    private let lock = NSLock()
    private var _sentResponses: [(response: String, message: ChannelMessage)] = []
    private var _startCount = 0
    private var _stopCount = 0

    var sentResponses: [(response: String, message: ChannelMessage)] {
        lock.lock()
        defer { lock.unlock() }
        return _sentResponses
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _startCount
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopCount
    }

    init(kind: ChannelKind) {
        self.kind = kind
    }

    func start() async throws {
        lock.lock()
        _startCount += 1
        lock.unlock()
    }

    func stop() async {
        lock.lock()
        _stopCount += 1
        lock.unlock()
    }

    func send(response: String, to message: ChannelMessage) async throws {
        lock.lock()
        _sentResponses.append((response: response, message: message))
        lock.unlock()
    }

    /// Simulate an inbound message arriving at this adapter.
    func simulateInbound(_ message: ChannelMessage) async -> String? {
        await onMessage?(message)
    }
}

// MARK: - ChannelMessage Tests

final class ChannelMessageTests: XCTestCase {

    func testChannelMessageCreationWithDefaults() {
        let msg = ChannelMessage(
            channel: .discord,
            senderId: "user-123",
            text: "Hello Fae"
        )

        XCTAssertEqual(msg.channel, .discord)
        XCTAssertEqual(msg.senderId, "user-123")
        XCTAssertEqual(msg.text, "Hello Fae")
        XCTAssertNil(msg.senderDisplayName)
        XCTAssertNil(msg.threadId)
        XCTAssertNil(msg.replyToId)
        XCTAssertTrue(msg.attachments.isEmpty)
        XCTAssertFalse(msg.id.isEmpty)
    }

    func testChannelMessageCreationWithAllFields() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let msg = ChannelMessage(
            id: "msg-001",
            channel: .whatsapp,
            senderId: "+1234567890",
            senderDisplayName: "Alice",
            text: "Hey there",
            timestamp: ts,
            threadId: "group-abc",
            replyToId: "msg-000",
            attachments: []
        )

        XCTAssertEqual(msg.id, "msg-001")
        XCTAssertEqual(msg.channel, .whatsapp)
        XCTAssertEqual(msg.senderId, "+1234567890")
        XCTAssertEqual(msg.senderDisplayName, "Alice")
        XCTAssertEqual(msg.text, "Hey there")
        XCTAssertEqual(msg.timestamp, ts)
        XCTAssertEqual(msg.threadId, "group-abc")
        XCTAssertEqual(msg.replyToId, "msg-000")
    }

    func testChannelKindDisplayNames() {
        XCTAssertEqual(ChannelKind.imessage.displayName, "iMessage")
        XCTAssertEqual(ChannelKind.whatsapp.displayName, "WhatsApp")
        XCTAssertEqual(ChannelKind.discord.displayName, "Discord")
    }

    func testChannelKindRawValues() {
        XCTAssertEqual(ChannelKind.imessage.rawValue, "imessage")
        XCTAssertEqual(ChannelKind.whatsapp.rawValue, "whatsapp")
        XCTAssertEqual(ChannelKind.discord.rawValue, "discord")
    }

    func testChannelMessageEquality() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let msg1 = ChannelMessage(
            id: "same-id",
            channel: .discord,
            senderId: "user-1",
            text: "Hello",
            timestamp: ts
        )
        let msg2 = ChannelMessage(
            id: "same-id",
            channel: .discord,
            senderId: "user-1",
            text: "Hello",
            timestamp: ts
        )
        XCTAssertEqual(msg1, msg2)
    }

    func testChannelAttachmentCreation() {
        let attachment = ChannelAttachment(
            type: .image,
            url: URL(string: "https://example.com/image.png"),
            data: nil,
            mimeType: "image/png"
        )
        XCTAssertEqual(attachment.type, .image)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertNotNil(attachment.url)
        XCTAssertNil(attachment.data)
    }
}

// MARK: - ChannelSession Tests

final class ChannelSessionTests: XCTestCase {

    func testSessionCreation() {
        let key = SessionKey(channel: .discord, senderId: "user-1")
        let session = ChannelSession(key: key, senderDisplayName: "Bob")

        XCTAssertEqual(session.key, key)
        XCTAssertEqual(session.senderDisplayName, "Bob")
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertTrue(session.isActive)
    }

    func testAddUserMessage() {
        let key = SessionKey(channel: .whatsapp, senderId: "+1234")
        let session = ChannelSession(key: key)

        session.addUserMessage("Hello Fae")

        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages[0].role, .user)
        XCTAssertEqual(session.messages[0].content, "Hello Fae")
    }

    func testAddAssistantMessage() {
        let key = SessionKey(channel: .imessage, senderId: "alice@icloud.com")
        let session = ChannelSession(key: key)

        session.addAssistantMessage("Hi there!")

        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages[0].role, .assistant)
        XCTAssertEqual(session.messages[0].content, "Hi there!")
    }

    func testConversationFlow() {
        let key = SessionKey(channel: .discord, senderId: "user-42")
        let session = ChannelSession(key: key)

        session.addUserMessage("What's the weather?")
        session.addAssistantMessage("I don't have access to weather data right now.")
        session.addUserMessage("That's okay, thanks")
        session.addAssistantMessage("You're welcome!")

        XCTAssertEqual(session.messages.count, 4)
        XCTAssertEqual(session.messages[0].role, .user)
        XCTAssertEqual(session.messages[1].role, .assistant)
        XCTAssertEqual(session.messages[2].role, .user)
        XCTAssertEqual(session.messages[3].role, .assistant)
    }

    func testTrimHistory() {
        let key = SessionKey(channel: .discord, senderId: "user-1")
        let session = ChannelSession(key: key)

        for i in 0..<30 {
            session.addUserMessage("Message \(i)")
            session.addAssistantMessage("Reply \(i)")
        }

        XCTAssertEqual(session.messages.count, 60)

        session.trimHistory(maxMessages: 10)

        XCTAssertEqual(session.messages.count, 10)
        // Should have the most recent messages
        XCTAssertEqual(session.messages.last?.content, "Reply 29")
    }

    func testTrimHistoryNoOpWhenUnderLimit() {
        let key = SessionKey(channel: .whatsapp, senderId: "+5555")
        let session = ChannelSession(key: key)

        session.addUserMessage("Hello")
        session.addAssistantMessage("Hi")

        session.trimHistory(maxMessages: 20)

        XCTAssertEqual(session.messages.count, 2)
    }

    func testDeactivate() {
        let key = SessionKey(channel: .discord, senderId: "user-1")
        let session = ChannelSession(key: key)

        XCTAssertTrue(session.isActive)
        session.deactivate()
        XCTAssertFalse(session.isActive)
    }

    func testUpdateDisplayName() {
        let key = SessionKey(channel: .whatsapp, senderId: "+1234")
        let session = ChannelSession(key: key)

        XCTAssertNil(session.senderDisplayName)
        session.updateDisplayName("Alice")
        XCTAssertEqual(session.senderDisplayName, "Alice")
    }

    func testLastActivityUpdatesOnMessage() {
        let key = SessionKey(channel: .discord, senderId: "user-1")
        let session = ChannelSession(key: key)
        let initialActivity = session.lastActivity

        // Small sleep to ensure time difference
        Thread.sleep(forTimeInterval: 0.01)

        session.addUserMessage("Hello")
        XCTAssertTrue(session.lastActivity >= initialActivity)
    }
}

// MARK: - SessionKey Tests

final class SessionKeyTests: XCTestCase {

    func testSessionKeyEquality() {
        let key1 = SessionKey(channel: .discord, senderId: "user-1")
        let key2 = SessionKey(channel: .discord, senderId: "user-1")
        XCTAssertEqual(key1, key2)
    }

    func testSessionKeyInequality() {
        let key1 = SessionKey(channel: .discord, senderId: "user-1")
        let key2 = SessionKey(channel: .whatsapp, senderId: "user-1")
        let key3 = SessionKey(channel: .discord, senderId: "user-2")

        XCTAssertNotEqual(key1, key2)
        XCTAssertNotEqual(key1, key3)
    }

    func testSessionKeyDescription() {
        let key = SessionKey(channel: .imessage, senderId: "alice@icloud.com")
        XCTAssertEqual(key.description, "imessage:alice@icloud.com")
    }

    func testSessionKeyHashable() {
        let key1 = SessionKey(channel: .discord, senderId: "user-1")
        let key2 = SessionKey(channel: .discord, senderId: "user-1")
        var set = Set<SessionKey>()
        set.insert(key1)
        set.insert(key2)
        XCTAssertEqual(set.count, 1)
    }
}

// MARK: - ChannelSessionStore Tests

final class ChannelSessionStoreTests: XCTestCase {

    func testSessionCreatedOnFirstAccess() async {
        let store = ChannelSessionStore()
        let key = SessionKey(channel: .discord, senderId: "user-1")

        let session = await store.session(for: key)

        XCTAssertEqual(session.key, key)
        XCTAssertTrue(session.messages.isEmpty)
        let count1 = await store.activeSessionCount
        XCTAssertEqual(count1, 1)
    }

    func testSameSessionReturnedForSameKey() async {
        let store = ChannelSessionStore()
        let key = SessionKey(channel: .discord, senderId: "user-1")

        let session1 = await store.session(for: key)
        session1.addUserMessage("Hello")

        let session2 = await store.session(for: key)

        XCTAssertEqual(session2.messages.count, 1)
        let count = await store.activeSessionCount
        XCTAssertEqual(count, 1)
    }

    func testDifferentKeysCreateDifferentSessions() async {
        let store = ChannelSessionStore()
        let key1 = SessionKey(channel: .discord, senderId: "user-1")
        let key2 = SessionKey(channel: .whatsapp, senderId: "user-2")

        let session1 = await store.session(for: key1)
        let session2 = await store.session(for: key2)

        session1.addUserMessage("Discord message")
        session2.addUserMessage("WhatsApp message")

        XCTAssertEqual(session1.messages.count, 1)
        XCTAssertEqual(session2.messages.count, 1)
        XCTAssertEqual(session1.messages[0].content, "Discord message")
        XCTAssertEqual(session2.messages[0].content, "WhatsApp message")
        let count = await store.activeSessionCount
        XCTAssertEqual(count, 2)
    }

    func testCleanupIdleSessions() async {
        let store = ChannelSessionStore()
        let key = SessionKey(channel: .discord, senderId: "user-old")

        _ = await store.session(for: key)

        // Clean up with a zero timeout — everything is "idle"
        let removed = await store.cleanupIdle(olderThan: 0)

        XCTAssertEqual(removed, 1)
        let count = await store.activeSessionCount
        XCTAssertEqual(count, 0)
    }

    func testCleanupPreservesRecentSessions() async {
        let store = ChannelSessionStore()
        let key = SessionKey(channel: .discord, senderId: "user-active")

        let session = await store.session(for: key)
        session.addUserMessage("Just chatted")

        // Clean up with a 1-hour timeout — session is recent
        let removed = await store.cleanupIdle(olderThan: 3600)

        XCTAssertEqual(removed, 0)
        let count = await store.activeSessionCount
        XCTAssertEqual(count, 1)
    }

    func testRemoveSession() async {
        let store = ChannelSessionStore()
        let key = SessionKey(channel: .whatsapp, senderId: "+1234")

        _ = await store.session(for: key)
        let countBefore = await store.activeSessionCount
        XCTAssertEqual(countBefore, 1)

        let removed = await store.removeSession(for: key)
        XCTAssertNotNil(removed)
        let countAfter = await store.activeSessionCount
        XCTAssertEqual(countAfter, 0)
    }

    func testRemoveAll() async {
        let store = ChannelSessionStore()

        _ = await store.session(for: SessionKey(channel: .discord, senderId: "a"))
        _ = await store.session(for: SessionKey(channel: .whatsapp, senderId: "b"))
        _ = await store.session(for: SessionKey(channel: .imessage, senderId: "c"))

        let countBefore = await store.activeSessionCount
        XCTAssertEqual(countBefore, 3)

        await store.removeAll()

        let countAfter = await store.activeSessionCount
        XCTAssertEqual(countAfter, 0)
    }

    func testDisplayNameUpdatedOnSubsequentAccess() async {
        let store = ChannelSessionStore()
        let key = SessionKey(channel: .discord, senderId: "user-1")

        let session1 = await store.session(for: key)
        XCTAssertNil(session1.senderDisplayName)

        let session2 = await store.session(for: key, displayName: "Bob")
        XCTAssertEqual(session2.senderDisplayName, "Bob")
    }
}

// MARK: - ChannelGateway Tests

final class ChannelGatewayTests: XCTestCase {

    private func makeGateway() -> (ChannelGateway, ChannelSessionStore) {
        let sessionStore = ChannelSessionStore()
        let gateway = ChannelGateway(eventBus: FaeEventBus(), sessionStore: sessionStore)
        return (gateway, sessionStore)
    }

    func testGatewayRoutesMessageToHandler() async {
        let (gateway, _) = makeGateway()
        let adapter = MockChannelAdapter(kind: .discord)

        await gateway.registerAdapter(adapter)
        await gateway.setResponseHandler { message, session in
            session.addUserMessage(message.text)
            let reply = "Echo: \(message.text)"
            session.addAssistantMessage(reply)
            return reply
        }
        await gateway.start()

        let msg = ChannelMessage(
            channel: .discord,
            senderId: "user-1",
            text: "Hello Fae"
        )

        let response = await adapter.simulateInbound(msg)

        XCTAssertEqual(response, "Echo: Hello Fae")
    }

    func testGatewayCreatesSessionPerSender() async {
        let (gateway, sessionStore) = makeGateway()
        let adapter = MockChannelAdapter(kind: .discord)

        await gateway.registerAdapter(adapter)
        await gateway.setResponseHandler { message, session in
            session.addUserMessage(message.text)
            session.addAssistantMessage("Reply to \(message.senderId)")
            return "Reply to \(message.senderId)"
        }
        await gateway.start()

        let msg1 = ChannelMessage(channel: .discord, senderId: "alice", text: "Hi")
        let msg2 = ChannelMessage(channel: .discord, senderId: "bob", text: "Hey")

        _ = await adapter.simulateInbound(msg1)
        _ = await adapter.simulateInbound(msg2)

        let count = await sessionStore.activeSessionCount
        XCTAssertEqual(count, 2)
    }

    func testGatewayRejectsEmptyText() async {
        let (gateway, _) = makeGateway()
        let adapter = MockChannelAdapter(kind: .discord)

        await gateway.registerAdapter(adapter)
        await gateway.setResponseHandler { _, _ in
            XCTFail("Handler should not be called for empty text")
            return nil
        }
        await gateway.start()

        let msg = ChannelMessage(channel: .discord, senderId: "user-1", text: "   ")
        let response = await adapter.simulateInbound(msg)

        XCTAssertNil(response)
    }

    func testGatewayRejectsWhenNotRunning() async {
        let (gateway, _) = makeGateway()
        let adapter = MockChannelAdapter(kind: .discord)

        await gateway.registerAdapter(adapter)
        await gateway.setResponseHandler { _, _ in
            XCTFail("Handler should not be called when gateway is not running")
            return nil
        }
        // Deliberately NOT calling start()

        let msg = ChannelMessage(channel: .discord, senderId: "user-1", text: "Hello")
        let response = await adapter.simulateInbound(msg)

        XCTAssertNil(response)
    }

    func testGatewayRejectsWithoutHandler() async {
        let (gateway, _) = makeGateway()
        let adapter = MockChannelAdapter(kind: .discord)

        await gateway.registerAdapter(adapter)
        // Deliberately NOT setting responseHandler
        await gateway.start()

        let msg = ChannelMessage(channel: .discord, senderId: "user-1", text: "Hello")
        let response = await adapter.simulateInbound(msg)

        XCTAssertNil(response)
    }

    func testGatewaySendsResponseBackToAdapter() async {
        let (gateway, _) = makeGateway()
        let adapter = MockChannelAdapter(kind: .discord)

        await gateway.registerAdapter(adapter)
        await gateway.setResponseHandler { _, _ in
            return "Gateway response"
        }
        await gateway.start()

        let msg = ChannelMessage(channel: .discord, senderId: "user-1", text: "Hi")
        _ = await adapter.simulateInbound(msg)

        let sent = adapter.sentResponses
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].response, "Gateway response")
        XCTAssertEqual(sent[0].message.senderId, "user-1")
    }

    func testGatewayStartStopLifecycle() async {
        let (gateway, _) = makeGateway()
        let adapter = MockChannelAdapter(kind: .discord)

        await gateway.registerAdapter(adapter)
        await gateway.start()

        XCTAssertEqual(adapter.startCount, 1)

        await gateway.stop()

        XCTAssertEqual(adapter.stopCount, 1)
    }

    func testGatewayMultipleAdapters() async {
        let (gateway, sessionStore) = makeGateway()
        let discordAdapter = MockChannelAdapter(kind: .discord)
        let whatsappAdapter = MockChannelAdapter(kind: .whatsapp)

        await gateway.registerAdapter(discordAdapter)
        await gateway.registerAdapter(whatsappAdapter)
        await gateway.setResponseHandler { message, session in
            session.addUserMessage(message.text)
            let reply = "\(message.channel.displayName): \(message.text)"
            session.addAssistantMessage(reply)
            return reply
        }
        await gateway.start()

        let discordMsg = ChannelMessage(channel: .discord, senderId: "user-d", text: "Discord hi")
        let whatsappMsg = ChannelMessage(channel: .whatsapp, senderId: "user-w", text: "WhatsApp hi")

        let r1 = await discordAdapter.simulateInbound(discordMsg)
        let r2 = await whatsappAdapter.simulateInbound(whatsappMsg)

        XCTAssertEqual(r1, "Discord: Discord hi")
        XCTAssertEqual(r2, "WhatsApp: WhatsApp hi")

        let count = await sessionStore.activeSessionCount
        XCTAssertEqual(count, 2)
    }

    func testGatewaySessionIsolation() async {
        let (gateway, sessionStore) = makeGateway()
        let adapter = MockChannelAdapter(kind: .discord)

        await gateway.registerAdapter(adapter)
        await gateway.setResponseHandler { message, session in
            session.addUserMessage(message.text)
            let reply = "You said: \(message.text) (history: \(session.messages.count))"
            session.addAssistantMessage(reply)
            return reply
        }
        await gateway.start()

        // Alice sends 2 messages, Bob sends 1.
        _ = await adapter.simulateInbound(ChannelMessage(channel: .discord, senderId: "alice", text: "First"))
        _ = await adapter.simulateInbound(ChannelMessage(channel: .discord, senderId: "alice", text: "Second"))
        _ = await adapter.simulateInbound(ChannelMessage(channel: .discord, senderId: "bob", text: "Hello"))

        // Verify session isolation: Alice has 4 messages (2 user + 2 assistant), Bob has 2.
        let aliceKey = SessionKey(channel: .discord, senderId: "alice")
        let bobKey = SessionKey(channel: .discord, senderId: "bob")

        let aliceSession = await sessionStore.session(for: aliceKey)
        let bobSession = await sessionStore.session(for: bobKey)

        XCTAssertEqual(aliceSession.messages.count, 4)
        XCTAssertEqual(bobSession.messages.count, 2)
    }

    func testGatewayIdleSessionCleanup() async {
        let (gateway, _) = makeGateway()
        let adapter = MockChannelAdapter(kind: .discord)

        await gateway.registerAdapter(adapter)
        await gateway.setResponseHandler { _, _ in "ok" }
        await gateway.start()

        _ = await adapter.simulateInbound(ChannelMessage(channel: .discord, senderId: "user-1", text: "Hi"))

        let countBefore = await gateway.activeSessionCount
        XCTAssertEqual(countBefore, 1)

        // Cleanup with zero timeout removes everything.
        let removed = await gateway.cleanupIdleSessions(olderThan: 0)
        XCTAssertEqual(removed, 1)

        let countAfter = await gateway.activeSessionCount
        XCTAssertEqual(countAfter, 0)
    }

    func testGatewayNilResponseDoesNotSendToAdapter() async {
        let (gateway, _) = makeGateway()
        let adapter = MockChannelAdapter(kind: .discord)

        await gateway.registerAdapter(adapter)
        await gateway.setResponseHandler { _, _ in nil }
        await gateway.start()

        _ = await adapter.simulateInbound(ChannelMessage(channel: .discord, senderId: "user-1", text: "Hi"))

        XCTAssertTrue(adapter.sentResponses.isEmpty)
    }
}

// MARK: - Per-Sender Conversation Isolation Tests

final class ChannelConversationIsolationTests: XCTestCase {

    func testTwoSendersHaveIndependentSessionHistories() async {
        let sessionStore = ChannelSessionStore()

        let aliceKey = SessionKey(channel: .discord, senderId: "alice")
        let bobKey = SessionKey(channel: .discord, senderId: "bob")

        let aliceSession = await sessionStore.session(for: aliceKey, displayName: "Alice")
        let bobSession = await sessionStore.session(for: bobKey, displayName: "Bob")

        // Alice sends 3 messages.
        aliceSession.addUserMessage("Alice message 1")
        aliceSession.addAssistantMessage("Reply to Alice 1")
        aliceSession.addUserMessage("Alice message 2")
        aliceSession.addAssistantMessage("Reply to Alice 2")
        aliceSession.addUserMessage("Alice message 3")
        aliceSession.addAssistantMessage("Reply to Alice 3")

        // Bob sends 1 message.
        bobSession.addUserMessage("Bob says hi")
        bobSession.addAssistantMessage("Hello Bob")

        // Verify isolation.
        XCTAssertEqual(aliceSession.messages.count, 6)
        XCTAssertEqual(bobSession.messages.count, 2)
        XCTAssertEqual(aliceSession.messages[0].content, "Alice message 1")
        XCTAssertEqual(bobSession.messages[0].content, "Bob says hi")
    }

    func testSameSenderDifferentChannelsAreSeparateSessions() async {
        let sessionStore = ChannelSessionStore()

        let discordKey = SessionKey(channel: .discord, senderId: "user-42")
        let whatsappKey = SessionKey(channel: .whatsapp, senderId: "user-42")

        let discordSession = await sessionStore.session(for: discordKey)
        let whatsappSession = await sessionStore.session(for: whatsappKey)

        discordSession.addUserMessage("Discord message")
        discordSession.addAssistantMessage("Discord reply")

        whatsappSession.addUserMessage("WhatsApp message")
        whatsappSession.addAssistantMessage("WhatsApp reply")
        whatsappSession.addUserMessage("WhatsApp follow-up")
        whatsappSession.addAssistantMessage("WhatsApp follow-up reply")

        XCTAssertEqual(discordSession.messages.count, 2)
        XCTAssertEqual(whatsappSession.messages.count, 4)

        let count = await sessionStore.activeSessionCount
        XCTAssertEqual(count, 2)
    }

    func testConversationStateSwapHistoryRoundTrips() async {
        let state = ConversationStateTracker()
        await state.setMaxHistory(20)

        // Add some messages to the shared state.
        await state.addUserMessage("Original user message")
        await state.addAssistantMessage("Original assistant message")

        let originalHistory = await state.history
        XCTAssertEqual(originalHistory.count, 2)

        // Swap in session history.
        let sessionHistory = [
            LLMMessage(role: .user, content: "Session user msg"),
            LLMMessage(role: .assistant, content: "Session assistant msg"),
            LLMMessage(role: .user, content: "Session user msg 2"),
        ]
        let savedHistory = await state.swapHistory(sessionHistory)

        // Saved should be the original.
        XCTAssertEqual(savedHistory.count, 2)
        XCTAssertEqual(savedHistory[0].content, "Original user message")

        // Current state should have session history.
        let currentHistory = await state.history
        XCTAssertEqual(currentHistory.count, 3)
        XCTAssertEqual(currentHistory[0].content, "Session user msg")

        // Restore original.
        await state.swapHistory(savedHistory)
        let restoredHistory = await state.history
        XCTAssertEqual(restoredHistory.count, 2)
        XCTAssertEqual(restoredHistory[0].content, "Original user message")
    }

    func testSessionHistoryTrimming() async {
        let session = ChannelSession(key: SessionKey(channel: .discord, senderId: "verbose"))

        // Add many messages.
        for i in 0..<50 {
            session.addUserMessage("msg \(i)")
            session.addAssistantMessage("reply \(i)")
        }

        XCTAssertEqual(session.messages.count, 100)

        session.trimHistory(maxMessages: 40)

        XCTAssertEqual(session.messages.count, 40)
        // Last message should be the most recent.
        XCTAssertEqual(session.messages.last?.content, "reply 49")
    }
}

import XCTest
@testable import Fae

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

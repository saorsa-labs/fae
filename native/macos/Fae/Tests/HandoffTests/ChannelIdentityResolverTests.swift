import XCTest
@testable import Fae

// MARK: - ChannelIdentityResolver Tests

final class ChannelIdentityResolverTests: XCTestCase {

    // MARK: - Basic Linking

    func testLinkCreatesCanonicalIdentity() async {
        let resolver = ChannelIdentityResolver()

        let identity = await resolver.link(
            channel: .whatsapp,
            senderId: "+1234567890",
            displayName: "Alice"
        )

        XCTAssertFalse(identity.id.isEmpty)
        XCTAssertEqual(identity.displayName, "Alice")
        XCTAssertEqual(identity.platformIds.count, 1)
        XCTAssertEqual(identity.platformIds[0].channel, .whatsapp)
        XCTAssertEqual(identity.platformIds[0].senderId, "+1234567890")
    }

    func testLinkSamePlatformIdIsIdempotent() async {
        let resolver = ChannelIdentityResolver()

        let id1 = await resolver.link(
            channel: .whatsapp, senderId: "+1234567890", displayName: "Alice"
        )
        let id2 = await resolver.link(
            channel: .whatsapp, senderId: "+1234567890", displayName: "Alice"
        )

        XCTAssertEqual(id1.id, id2.id)
        let count = await resolver.identityCount
        XCTAssertEqual(count, 1)
    }

    func testLinkTwoPlatformsToDifferentIdentities() async {
        let resolver = ChannelIdentityResolver()

        let id1 = await resolver.link(channel: .whatsapp, senderId: "+1111")
        let id2 = await resolver.link(channel: .discord, senderId: "user-42")

        XCTAssertNotEqual(id1.id, id2.id)
        let count = await resolver.identityCount
        XCTAssertEqual(count, 2)
    }

    func testLinkTwoPlatformsToSameCanonicalId() async {
        let resolver = ChannelIdentityResolver()

        let id1 = await resolver.link(
            channel: .whatsapp, senderId: "+1234567890", displayName: "Alice"
        )
        let id2 = await resolver.link(
            channel: .imessage, senderId: "+1234567890",
            displayName: "Alice", canonicalId: id1.id
        )

        XCTAssertEqual(id1.id, id2.id)
        XCTAssertEqual(id2.platformIds.count, 2)
        let count = await resolver.identityCount
        XCTAssertEqual(count, 1)
    }

    // MARK: - Resolution

    func testResolveKnownPlatformId() async {
        let resolver = ChannelIdentityResolver()

        await resolver.link(
            channel: .whatsapp, senderId: "+1234567890", displayName: "Alice"
        )

        let resolved = await resolver.resolve(channel: .whatsapp, senderId: "+1234567890")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.displayName, "Alice")
    }

    func testResolveUnknownPlatformIdReturnsNil() async {
        let resolver = ChannelIdentityResolver()

        let resolved = await resolver.resolve(channel: .discord, senderId: "unknown")
        XCTAssertNil(resolved)
    }

    // MARK: - Linked Session Keys

    func testLinkedSessionKeysReturnsOtherChannels() async {
        let resolver = ChannelIdentityResolver()

        let id1 = await resolver.link(
            channel: .whatsapp, senderId: "+1234567890"
        )
        await resolver.link(
            channel: .imessage, senderId: "+1234567890",
            canonicalId: id1.id
        )

        let keys = await resolver.linkedSessionKeys(channel: .whatsapp, senderId: "+1234567890")

        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].channel, .imessage)
        XCTAssertEqual(keys[0].senderId, "+1234567890")
    }

    func testLinkedSessionKeysExcludesSelf() async {
        let resolver = ChannelIdentityResolver()

        await resolver.link(channel: .whatsapp, senderId: "+1234567890")

        let keys = await resolver.linkedSessionKeys(channel: .whatsapp, senderId: "+1234567890")
        XCTAssertTrue(keys.isEmpty)
    }

    func testLinkedSessionKeysReturnsEmptyForUnknown() async {
        let resolver = ChannelIdentityResolver()

        let keys = await resolver.linkedSessionKeys(channel: .discord, senderId: "unknown")
        XCTAssertTrue(keys.isEmpty)
    }

    // MARK: - Unlinking

    func testUnlinkRemovesPlatformId() async {
        let resolver = ChannelIdentityResolver()

        await resolver.link(channel: .whatsapp, senderId: "+1234567890")

        let removed = await resolver.unlink(channel: .whatsapp, senderId: "+1234567890")
        XCTAssertTrue(removed)

        let resolved = await resolver.resolve(channel: .whatsapp, senderId: "+1234567890")
        XCTAssertNil(resolved)

        let count = await resolver.identityCount
        XCTAssertEqual(count, 0)
    }

    func testUnlinkNonexistentReturnsFalse() async {
        let resolver = ChannelIdentityResolver()

        let removed = await resolver.unlink(channel: .discord, senderId: "unknown")
        XCTAssertFalse(removed)
    }

    func testUnlinkOneOfTwoPreservesOther() async {
        let resolver = ChannelIdentityResolver()

        let id1 = await resolver.link(channel: .whatsapp, senderId: "+1111")
        await resolver.link(channel: .imessage, senderId: "+1111", canonicalId: id1.id)

        await resolver.unlink(channel: .whatsapp, senderId: "+1111")

        let resolved = await resolver.resolve(channel: .imessage, senderId: "+1111")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.platformIds.count, 1)

        let count = await resolver.identityCount
        XCTAssertEqual(count, 1)
    }

    // MARK: - Auto-Link by Phone

    func testAutoLinkByPhoneMatchesSameNumber() async {
        let resolver = ChannelIdentityResolver()

        // Register WhatsApp identity.
        await resolver.link(
            channel: .whatsapp, senderId: "+11234567890", displayName: "Alice"
        )

        // Auto-link iMessage with the same number (different prefix).
        let matched = await resolver.autoLinkByPhone(
            channel: .imessage, senderId: "+1234567890"
        )

        XCTAssertNotNil(matched)
        XCTAssertEqual(matched?.platformIds.count, 2)
    }

    func testAutoLinkByPhoneSkipsShortNumbers() async {
        let resolver = ChannelIdentityResolver()

        await resolver.link(channel: .whatsapp, senderId: "123")

        let matched = await resolver.autoLinkByPhone(channel: .imessage, senderId: "123")
        XCTAssertNil(matched)
    }

    func testAutoLinkByPhoneSkipsSameChannel() async {
        let resolver = ChannelIdentityResolver()

        await resolver.link(channel: .whatsapp, senderId: "+1234567890")

        // Same channel should not match.
        let matched = await resolver.autoLinkByPhone(
            channel: .whatsapp, senderId: "+441234567890"
        )
        XCTAssertNil(matched)
    }

    func testAutoLinkByPhoneNoMatchReturnsNil() async {
        let resolver = ChannelIdentityResolver()

        await resolver.link(channel: .whatsapp, senderId: "+1234567890")

        let matched = await resolver.autoLinkByPhone(
            channel: .imessage, senderId: "+9876543210"
        )
        XCTAssertNil(matched)
    }

    // MARK: - Auto-Link by Display Name

    func testAutoLinkByDisplayNameMatchesCaseInsensitive() async {
        let resolver = ChannelIdentityResolver()

        await resolver.link(
            channel: .whatsapp, senderId: "+1111", displayName: "Alice Smith"
        )

        let matched = await resolver.autoLinkByDisplayName(
            channel: .discord, senderId: "user-42", displayName: "alice smith"
        )

        XCTAssertNotNil(matched)
        XCTAssertEqual(matched?.platformIds.count, 2)
    }

    func testAutoLinkByDisplayNameSkipsEmptyName() async {
        let resolver = ChannelIdentityResolver()

        await resolver.link(
            channel: .whatsapp, senderId: "+1111", displayName: "Alice"
        )

        let matched = await resolver.autoLinkByDisplayName(
            channel: .discord, senderId: "user-42", displayName: "  "
        )
        XCTAssertNil(matched)
    }

    func testAutoLinkByDisplayNameSkipsSameChannel() async {
        let resolver = ChannelIdentityResolver()

        await resolver.link(
            channel: .discord, senderId: "user-1", displayName: "Alice"
        )

        let matched = await resolver.autoLinkByDisplayName(
            channel: .discord, senderId: "user-2", displayName: "Alice"
        )

        // Should not link — same channel already has "Alice".
        XCTAssertNil(matched)
    }

    func testAutoLinkByDisplayNameNoMatchReturnsNil() async {
        let resolver = ChannelIdentityResolver()

        await resolver.link(
            channel: .whatsapp, senderId: "+1111", displayName: "Alice"
        )

        let matched = await resolver.autoLinkByDisplayName(
            channel: .discord, senderId: "user-42", displayName: "Bob"
        )
        XCTAssertNil(matched)
    }

    // MARK: - Queries

    func testAllIdentitiesReturnsAllCanonicalIdentities() async {
        let resolver = ChannelIdentityResolver()

        await resolver.link(channel: .whatsapp, senderId: "+1111", displayName: "Alice")
        await resolver.link(channel: .discord, senderId: "user-42", displayName: "Bob")

        let all = await resolver.allIdentities
        XCTAssertEqual(all.count, 2)
    }

    func testRemoveAllClearsEverything() async {
        let resolver = ChannelIdentityResolver()

        await resolver.link(channel: .whatsapp, senderId: "+1111")
        await resolver.link(channel: .discord, senderId: "user-42")

        await resolver.removeAll()

        let count = await resolver.identityCount
        XCTAssertEqual(count, 0)
        let linkCount = await resolver.linkCount
        XCTAssertEqual(linkCount, 0)
    }
}

// MARK: - Gateway Cross-Channel Integration Tests

final class GatewayCrossChannelTests: XCTestCase {

    private func makeGateway() -> (ChannelGateway, ChannelSessionStore, ChannelIdentityResolver) {
        let sessionStore = ChannelSessionStore()
        let resolver = ChannelIdentityResolver()
        let gateway = ChannelGateway(
            eventBus: FaeEventBus(),
            sessionStore: sessionStore,
            identityResolver: resolver
        )
        return (gateway, sessionStore, resolver)
    }

    func testGatewayAutoLinksPhoneNumbers() async {
        let (gateway, _, resolver) = makeGateway()
        let whatsapp = MockCrossChannelAdapter(kind: .whatsapp)
        let imessage = MockCrossChannelAdapter(kind: .imessage)

        await gateway.registerAdapter(whatsapp)
        await gateway.registerAdapter(imessage)
        await gateway.setResponseHandler { _, _ in "ok" }
        await gateway.start()

        // WhatsApp message first.
        let msg1 = ChannelMessage(
            channel: .whatsapp, senderId: "+1234567890",
            senderDisplayName: "Alice", text: "Hello from WhatsApp"
        )
        _ = await whatsapp.simulateInbound(msg1)

        // iMessage with same number.
        let msg2 = ChannelMessage(
            channel: .imessage, senderId: "+1234567890",
            senderDisplayName: "Alice", text: "Hello from iMessage"
        )
        _ = await imessage.simulateInbound(msg2)

        // Both should be linked to the same canonical identity.
        let resolved1 = await resolver.resolve(channel: .whatsapp, senderId: "+1234567890")
        let resolved2 = await resolver.resolve(channel: .imessage, senderId: "+1234567890")

        XCTAssertNotNil(resolved1)
        XCTAssertNotNil(resolved2)
        XCTAssertEqual(resolved1?.id, resolved2?.id)
    }

    func testGatewayInjectsCrossChannelContext() async {
        let (gateway, sessionStore, resolver) = makeGateway()
        let whatsapp = MockCrossChannelAdapter(kind: .whatsapp)
        let imessage = MockCrossChannelAdapter(kind: .imessage)

        await gateway.registerAdapter(whatsapp)
        await gateway.registerAdapter(imessage)

        var capturedMessages: [ChannelMessage] = []
        await gateway.setResponseHandler { message, session in
            capturedMessages.append(message)
            session.addUserMessage(message.text)
            session.addAssistantMessage("Reply")
            return "Reply"
        }
        await gateway.start()

        // WhatsApp message first.
        let msg1 = ChannelMessage(
            channel: .whatsapp, senderId: "+1234567890",
            senderDisplayName: "Alice", text: "Hello from WhatsApp"
        )
        _ = await whatsapp.simulateInbound(msg1)

        // Pre-link the identities (phone auto-link registers WhatsApp as standalone).
        // Now manually link iMessage to the same canonical identity.
        let whatsappIdentity = await resolver.resolve(
            channel: .whatsapp, senderId: "+1234567890"
        )
        if let canonicalId = whatsappIdentity?.id {
            await resolver.link(
                channel: .imessage, senderId: "+1234567890",
                canonicalId: canonicalId, source: .phoneMatch
            )
        }

        // iMessage message — should include cross-channel context.
        let msg2 = ChannelMessage(
            channel: .imessage, senderId: "+1234567890",
            senderDisplayName: "Alice", text: "Hello from iMessage"
        )
        _ = await imessage.simulateInbound(msg2)

        // The second message should have cross-channel context.
        XCTAssertEqual(capturedMessages.count, 2)
        XCTAssertNil(capturedMessages[0].crossChannelContext)
        XCTAssertNotNil(capturedMessages[1].crossChannelContext)
        let context = capturedMessages[1].crossChannelContext ?? ""
        XCTAssertTrue(context.contains("WhatsApp"), "Expected WhatsApp in context: \(context)")
    }

    func testGatewayExposesIdentityResolver() async {
        let (gateway, _, _) = makeGateway()
        let resolverRef = await gateway.resolver
        // Should be the same resolver instance.
        let count = await resolverRef.identityCount
        XCTAssertEqual(count, 0)
    }
}

// MARK: - Mock Adapter for Cross-Channel Tests

private final class MockCrossChannelAdapter: ChannelAdapter, @unchecked Sendable {
    let kind: ChannelKind
    var onMessage: (@Sendable (ChannelMessage) async -> String?)?

    private let lock = NSLock()
    private var _sentResponses: [(response: String, message: ChannelMessage)] = []

    var sentResponses: [(response: String, message: ChannelMessage)] {
        lock.lock()
        defer { lock.unlock() }
        return _sentResponses
    }

    init(kind: ChannelKind) {
        self.kind = kind
    }

    func start() async throws {}
    func stop() async {}

    func send(response: String, to message: ChannelMessage) async throws {
        lock.lock()
        _sentResponses.append((response: response, message: message))
        lock.unlock()
    }

    func simulateInbound(_ message: ChannelMessage) async -> String? {
        await onMessage?(message)
    }
}

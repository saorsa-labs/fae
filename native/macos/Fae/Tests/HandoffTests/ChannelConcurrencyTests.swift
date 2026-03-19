import FaeInference
import XCTest
@testable import Fae

// MARK: - Concurrency Stress Tests

/// Stress tests for concurrent channel message processing.
///
/// Verifies:
/// - No race conditions under simultaneous messages
/// - Per-sender session isolation holds under load
/// - Gateway serialises dispatch correctly
/// - Sessions don't cross-contaminate
final class ChannelConcurrencyTests: XCTestCase {

    // MARK: - Helpers

    private func makeGateway() -> (
        ChannelGateway, ChannelSessionStore, ConcurrencyMockAdapter,
        ConcurrencyMockAdapter, ConcurrencyMockAdapter
    ) {
        let sessionStore = ChannelSessionStore()
        let gateway = ChannelGateway(
            eventBus: FaeEventBus(),
            sessionStore: sessionStore,
            identityResolver: ChannelIdentityResolver(),
            healthMonitor: ChannelHealthMonitor(
                eventBus: FaeEventBus(),
                config: ChannelHealthMonitor.Config(checkIntervalSeconds: 999)
            )
        )
        let discord = ConcurrencyMockAdapter(kind: .discord)
        let whatsapp = ConcurrencyMockAdapter(kind: .whatsapp)
        let imessage = ConcurrencyMockAdapter(kind: .imessage)
        return (gateway, sessionStore, discord, whatsapp, imessage)
    }

    // MARK: - Multiple Senders on Same Channel

    func testConcurrentSendersOnSameChannel() async {
        let (gateway, sessionStore, discord, _, _) = makeGateway()

        await gateway.registerAdapter(discord)

        let processedCount = AtomicCounter()

        await gateway.setResponseHandler { message, session in
            session.addUserMessage(message.text)
            let reply = "Reply to \(message.senderId)"
            session.addAssistantMessage(reply)
            processedCount.increment()
            return reply
        }
        await gateway.start()

        // Send 20 messages from 5 different senders concurrently.
        let senderCount = 5
        let messagesPerSender = 4

        await withTaskGroup(of: Void.self) { group in
            for senderIndex in 0..<senderCount {
                for msgIndex in 0..<messagesPerSender {
                    group.addTask {
                        let msg = ChannelMessage(
                            channel: .discord,
                            senderId: "sender-\(senderIndex)",
                            text: "Message \(msgIndex) from sender \(senderIndex)"
                        )
                        _ = await discord.simulateInbound(msg)
                    }
                }
            }
        }

        // All messages should have been processed.
        XCTAssertEqual(processedCount.value, senderCount * messagesPerSender)

        // Each sender should have their own session.
        let count = await sessionStore.activeSessionCount
        XCTAssertGreaterThanOrEqual(count, senderCount)

        // Verify session isolation — each sender's session should have their own messages.
        for senderIndex in 0..<senderCount {
            let key = SessionKey(channel: .discord, senderId: "sender-\(senderIndex)")
            let session = await sessionStore.session(for: key)
            // Each sender sent messagesPerSender messages, producing 2x messages (user + assistant).
            XCTAssertEqual(
                session.messages.count, messagesPerSender * 2,
                "Sender \(senderIndex) has wrong message count: \(session.messages.count)"
            )
            // Verify no cross-contamination: all user messages should be from this sender.
            let userMessages = session.messages.filter { $0.role == .user }
            for msg in userMessages {
                XCTAssertTrue(
                    msg.content.contains("sender \(senderIndex)"),
                    "Cross-contamination detected: sender-\(senderIndex) has message '\(msg.content)'"
                )
            }
        }

        await gateway.stop()
    }

    // MARK: - Simultaneous Multi-Channel Messages

    func testSimultaneousMessagesAcrossChannels() async {
        let (gateway, _, discord, whatsapp, imessage) = makeGateway()

        await gateway.registerAdapter(discord)
        await gateway.registerAdapter(whatsapp)
        await gateway.registerAdapter(imessage)

        let processedCount = AtomicCounter()
        let channelCounts = AtomicChannelCounter()

        await gateway.setResponseHandler { message, session in
            session.addUserMessage(message.text)
            session.addAssistantMessage("Reply")
            processedCount.increment()
            channelCounts.increment(message.channel)
            return "Reply"
        }
        await gateway.start()

        let messagesPerChannel = 10

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<messagesPerChannel {
                group.addTask {
                    _ = await discord.simulateInbound(
                        ChannelMessage(
                            channel: .discord, senderId: "discord-user-\(i)",
                            text: "Discord \(i)"
                        )
                    )
                }
                group.addTask {
                    _ = await whatsapp.simulateInbound(
                        ChannelMessage(
                            channel: .whatsapp, senderId: "+\(1000 + i)",
                            text: "WhatsApp \(i)"
                        )
                    )
                }
                group.addTask {
                    _ = await imessage.simulateInbound(
                        ChannelMessage(
                            channel: .imessage, senderId: "user\(i)@icloud.com",
                            text: "iMessage \(i)"
                        )
                    )
                }
            }
        }

        XCTAssertEqual(processedCount.value, messagesPerChannel * 3)
        XCTAssertEqual(channelCounts.count(for: .discord), messagesPerChannel)
        XCTAssertEqual(channelCounts.count(for: .whatsapp), messagesPerChannel)
        XCTAssertEqual(channelCounts.count(for: .imessage), messagesPerChannel)

        await gateway.stop()
    }

    // MARK: - Session Isolation Under Load

    func testSessionIsolationUnderConcurrentLoad() async {
        let (gateway, sessionStore, discord, _, _) = makeGateway()

        await gateway.registerAdapter(discord)
        await gateway.setResponseHandler { message, session in
            // Simulate some processing time.
            session.addUserMessage(message.text)
            let reply = "Echo: \(message.text)"
            session.addAssistantMessage(reply)
            return reply
        }
        await gateway.start()

        // Alice and Bob send interleaved messages.
        let messageCount = 10

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<messageCount {
                group.addTask {
                    _ = await discord.simulateInbound(
                        ChannelMessage(
                            channel: .discord, senderId: "alice",
                            text: "Alice-\(i)"
                        )
                    )
                }
                group.addTask {
                    _ = await discord.simulateInbound(
                        ChannelMessage(
                            channel: .discord, senderId: "bob",
                            text: "Bob-\(i)"
                        )
                    )
                }
            }
        }

        // Verify session isolation.
        let aliceKey = SessionKey(channel: .discord, senderId: "alice")
        let bobKey = SessionKey(channel: .discord, senderId: "bob")

        let aliceSession = await sessionStore.session(for: aliceKey)
        let bobSession = await sessionStore.session(for: bobKey)

        // Each should have messageCount * 2 messages (user + assistant).
        XCTAssertEqual(aliceSession.messages.count, messageCount * 2)
        XCTAssertEqual(bobSession.messages.count, messageCount * 2)

        // Verify no cross-contamination.
        let aliceUserMessages = aliceSession.messages.filter { $0.role == .user }
        for msg in aliceUserMessages {
            XCTAssertTrue(
                msg.content.hasPrefix("Alice-"),
                "Alice's session contains Bob's message: \(msg.content)"
            )
        }

        let bobUserMessages = bobSession.messages.filter { $0.role == .user }
        for msg in bobUserMessages {
            XCTAssertTrue(
                msg.content.hasPrefix("Bob-"),
                "Bob's session contains Alice's message: \(msg.content)"
            )
        }

        await gateway.stop()
    }

    // MARK: - Concurrent Session Cleanup

    func testConcurrentSessionCleanup() async {
        let (gateway, sessionStore, discord, _, _) = makeGateway()

        await gateway.registerAdapter(discord)
        await gateway.setResponseHandler { _, _ in "ok" }
        await gateway.start()

        // Create many sessions.
        for i in 0..<20 {
            _ = await discord.simulateInbound(
                ChannelMessage(channel: .discord, senderId: "user-\(i)", text: "Hi")
            )
        }

        let initialCount = await sessionStore.activeSessionCount
        XCTAssertGreaterThanOrEqual(initialCount, 20)

        // Concurrent cleanup + new messages.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await gateway.cleanupIdleSessions(olderThan: 0)
            }
            // Send more messages while cleanup is running.
            for i in 20..<25 {
                group.addTask {
                    _ = await discord.simulateInbound(
                        ChannelMessage(channel: .discord, senderId: "user-\(i)", text: "Hi")
                    )
                }
            }
        }

        // Should not crash; session count should be consistent.
        let finalCount = await sessionStore.activeSessionCount
        XCTAssertGreaterThanOrEqual(finalCount, 0)

        await gateway.stop()
    }

    // MARK: - Concurrent Identity Resolution

    func testConcurrentIdentityAutoLinking() async {
        let resolver = ChannelIdentityResolver()
        let sessionStore = ChannelSessionStore()
        let gateway = ChannelGateway(
            eventBus: FaeEventBus(),
            sessionStore: sessionStore,
            identityResolver: resolver,
            healthMonitor: ChannelHealthMonitor(
                eventBus: FaeEventBus(),
                config: ChannelHealthMonitor.Config(checkIntervalSeconds: 999)
            )
        )

        let whatsapp = ConcurrencyMockAdapter(kind: .whatsapp)
        let imessage = ConcurrencyMockAdapter(kind: .imessage)

        await gateway.registerAdapter(whatsapp)
        await gateway.registerAdapter(imessage)
        await gateway.setResponseHandler { _, _ in "ok" }
        await gateway.start()

        // Send messages from the same phone on both channels concurrently.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await whatsapp.simulateInbound(
                        ChannelMessage(
                            channel: .whatsapp, senderId: "+123456789\(i)",
                            senderDisplayName: "User\(i)", text: "WA msg"
                        )
                    )
                }
                group.addTask {
                    _ = await imessage.simulateInbound(
                        ChannelMessage(
                            channel: .imessage, senderId: "+123456789\(i)",
                            senderDisplayName: "User\(i)", text: "iMsg msg"
                        )
                    )
                }
            }
        }

        // Should not crash. Identity count should be reasonable.
        let identityCount = await resolver.identityCount
        XCTAssertGreaterThan(identityCount, 0)
        XCTAssertLessThanOrEqual(identityCount, 20) // At most 20 (10 per channel if no linking)

        await gateway.stop()
    }

    // MARK: - Rapid Start/Stop

    func testRapidStartStopDoesNotCrash() async {
        let (gateway, _, discord, _, _) = makeGateway()

        await gateway.registerAdapter(discord)
        await gateway.setResponseHandler { _, _ in "ok" }

        // Rapid start/stop cycles.
        for _ in 0..<5 {
            await gateway.start()
            await gateway.stop()
        }

        // Final start — should work normally.
        await gateway.start()
        let response = await discord.simulateInbound(
            ChannelMessage(channel: .discord, senderId: "user-1", text: "Hello")
        )
        XCTAssertEqual(response, "ok")

        await gateway.stop()
    }
}

// MARK: - Thread-Safe Counters

/// Thread-safe counter for concurrent test assertions.
private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}

/// Thread-safe per-channel counter.
private final class AtomicChannelCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [ChannelKind: Int] = [:]

    func increment(_ channel: ChannelKind) {
        lock.lock()
        counts[channel, default: 0] += 1
        lock.unlock()
    }

    func count(for channel: ChannelKind) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[channel] ?? 0
    }
}

// MARK: - Concurrency Mock Adapter

private final class ConcurrencyMockAdapter: ChannelAdapter, @unchecked Sendable {
    let kind: ChannelKind
    var onMessage: (@Sendable (ChannelMessage) async -> String?)?

    init(kind: ChannelKind) {
        self.kind = kind
    }

    func start() async throws {}
    func stop() async {}
    func send(response: String, to message: ChannelMessage) async throws {}

    func simulateInbound(_ message: ChannelMessage) async -> String? {
        await onMessage?(message)
    }
}

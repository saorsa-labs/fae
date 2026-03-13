import XCTest
@testable import Fae

final class SessionStoreTests: XCTestCase {

    private func makeStore() async throws -> SessionStore {
        let dbPath = "\(NSTemporaryDirectory())/session-store-test-\(UUID().uuidString).sqlite"
        let memoryStore = try SQLiteMemoryStore(path: dbPath)
        return try await SessionStore(dbQueue: memoryStore.sharedDatabaseQueue)
    }

    func testOpenAppendAndCloseSessionPersistsMessages() async throws {
        let store = try await makeStore()
        let startedAt = Date(timeIntervalSince1970: 1_741_000_000)
        let session = try await store.openSession(kind: .main, speakerId: "owner", startedAt: startedAt)

        try await store.appendMessage(
            sessionId: session.id,
            turnId: "turn-1",
            role: .user,
            content: "Please remember the launch checklist",
            speakerId: "owner",
            createdAt: startedAt
        )
        try await store.appendMessage(
            sessionId: session.id,
            turnId: "turn-1",
            role: .assistant,
            content: "I will keep that in mind.",
            createdAt: startedAt.addingTimeInterval(2)
        )
        try await store.closeSession(id: session.id, endedAt: startedAt.addingTimeInterval(5))

        let fetched = try await store.fetchSession(id: session.id)
        let unwrappedFetched = try XCTUnwrap(fetched)
        let messages = try await store.messages(sessionId: session.id)

        XCTAssertEqual(unwrappedFetched.status, .closed)
        XCTAssertEqual(unwrappedFetched.messageCount, 2)
        XCTAssertEqual(unwrappedFetched.speakerId, "owner")
        XCTAssertEqual(unwrappedFetched.title, "Please remember the launch checklist")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[0].turnId, "turn-1")
        XCTAssertEqual(messages[1].turnId, "turn-1")
    }

    func testCloseOpenSessionsOnlyClosesRecoveredOpenSessions() async throws {
        let store = try await makeStore()
        let first = try await store.openSession(kind: .main, speakerId: "owner", startedAt: Date())
        let second = try await store.openSession(kind: .main, speakerId: "guest", startedAt: Date().addingTimeInterval(10))
        try await store.closeSession(id: second.id, endedAt: Date().addingTimeInterval(12))

        let closed = try await store.closeOpenSessions(endedAt: Date().addingTimeInterval(20))
        let sessions = try await store.recentSessions(limit: 10)
        let firstFetched = try await store.fetchSession(id: first.id)
        let secondFetched = try await store.fetchSession(id: second.id)
        let unwrappedFirst = try XCTUnwrap(firstFetched)
        let unwrappedSecond = try XCTUnwrap(secondFetched)

        XCTAssertEqual(closed, 1)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(unwrappedFirst.status, .closed)
        XCTAssertEqual(unwrappedSecond.status, .closed)
    }

    func testSearchSessionsReturnsGroupedTranscriptMatches() async throws {
        let store = try await makeStore()
        let firstStart = Date().addingTimeInterval(-1_200)
        let secondStart = firstStart.addingTimeInterval(600)

        let first = try await store.openSession(kind: .main, speakerId: "owner", startedAt: firstStart)
        _ = try await store.appendMessage(
            sessionId: first.id,
            turnId: "turn-1",
            role: .user,
            content: "Let's keep a launch checklist for the macOS release.",
            speakerId: "owner",
            createdAt: firstStart
        )
        _ = try await store.appendMessage(
            sessionId: first.id,
            turnId: "turn-1",
            role: .assistant,
            content: "The launch checklist now includes release notes and screenshots.",
            createdAt: firstStart.addingTimeInterval(3)
        )
        try await store.closeSession(id: first.id, endedAt: firstStart.addingTimeInterval(5))

        let second = try await store.openSession(kind: .main, speakerId: "owner", startedAt: secondStart)
        _ = try await store.appendMessage(
            sessionId: second.id,
            turnId: "turn-2",
            role: .user,
            content: "Please remind me to call the dentist tomorrow.",
            speakerId: "owner",
            createdAt: secondStart
        )
        try await store.closeSession(id: second.id, endedAt: secondStart.addingTimeInterval(5))

        let results = try await store.searchSessions(
            query: "launch checklist",
            limit: 5,
            days: 365
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.session.id, first.id)
        XCTAssertEqual(results.first?.matchedMessageCount, 2)
        XCTAssertEqual(results.first?.snippets.count, 2)
        XCTAssertTrue(results.first?.snippets.contains(where: { $0.snippet.contains("launch") }) == true)
    }
}

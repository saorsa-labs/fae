import GRDB
import XCTest

@testable import Fae

/// Retention GC for the durable session store (production-readiness audit
/// MEDIUM: "session store has no GC — unbounded fae.db growth").
///
/// These tests encode the safety contract, not just the mechanics:
/// - closed sessions outside the retention window are pruned WITH their
///   messages and FTS rows (a cascade would strand FTS entries),
/// - the open (active) session is NEVER deleted, no matter how old,
/// - the count cap keeps the most recent closed sessions.
final class SessionStoreGCTests: XCTestCase {
    private var tempDirectory: URL!
    private var dbQueue: DatabaseQueue!
    private var store: SessionStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-session-gc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: tempDirectory.appendingPathComponent("fae.db").path)
        store = try SessionStore(dbQueue: dbQueue)
    }

    override func tearDownWithError() throws {
        store = nil
        dbQueue = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    // MARK: - Helpers

    private func makeClosedSession(daysAgo: Double, messages: Int) async throws
        -> ConversationSessionRecord
    {
        let at = Date(timeIntervalSinceNow: -daysAgo * 86_400)
        let session = try await store.openSession(startedAt: at)
        for index in 0..<messages {
            _ = try await store.appendMessage(
                sessionId: session.id,
                turnId: "turn-\(index)",
                role: .user,
                content: "message \(index) in session from \(daysAgo) days ago",
                createdAt: at
            )
        }
        try await store.closeSession(id: session.id, endedAt: at)
        return session
    }

    private func count(sql: String, arguments: StatementArguments = StatementArguments())
        throws -> Int
    {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    // MARK: - Retention window

    func testPruneDeletesOldClosedSessionsButKeepsRecentAndActive() async throws {
        let oldClosed = try await makeClosedSession(daysAgo: 200, messages: 2)
        let recentClosed = try await makeClosedSession(daysAgo: 1, messages: 1)
        // An abandoned-but-still-open session must survive GC regardless of
        // age: it is (or may become) the live conversation, and deleting it
        // from under the pipeline would corrupt the active turn.
        let oldOpen = try await store.openSession(
            startedAt: Date(timeIntervalSinceNow: -200 * 86_400))

        let result = try await store.pruneExpiredSessions(retentionDays: 90, maxSessions: 0)

        XCTAssertEqual(result.prunedSessions, 1)
        XCTAssertEqual(result.prunedMessages, 2)
        let oldFetched = try await store.fetchSession(id: oldClosed.id)
        XCTAssertNil(oldFetched, "closed session past retention must be pruned")
        let recentFetched = try await store.fetchSession(id: recentClosed.id)
        XCTAssertNotNil(recentFetched, "closed session inside retention must survive")
        let openFetched = try await store.fetchSession(id: oldOpen.id)
        XCTAssertNotNil(openFetched, "the open (active) session must never be pruned")

        // Messages of the pruned session are gone; the survivor's remain.
        let orphanMessages = try count(
            sql: "SELECT COUNT(*) FROM session_messages WHERE session_id = ?",
            arguments: [oldClosed.id])
        XCTAssertEqual(orphanMessages, 0)
        let survivorMessages = try count(
            sql: "SELECT COUNT(*) FROM session_messages WHERE session_id = ?",
            arguments: [recentClosed.id])
        XCTAssertEqual(survivorMessages, 1)
    }

    func testPruneKeepsFTSIndexConsistent() async throws {
        // The prune deletes messages explicitly (not via FK cascade) because
        // SQLite only fires the external-content FTS delete triggers on
        // direct DELETEs — a cascade would strand rows in the FTS index and
        // session_search would keep resurrecting pruned content.
        _ = try await makeClosedSession(daysAgo: 200, messages: 3)
        _ = try await makeClosedSession(daysAgo: 1, messages: 2)

        _ = try await store.pruneExpiredSessions(retentionDays: 90, maxSessions: 0)

        let messageCount = try count(sql: "SELECT COUNT(*) FROM session_messages")
        let ftsCount = try count(sql: "SELECT COUNT(*) FROM session_message_fts")
        XCTAssertEqual(messageCount, 2)
        XCTAssertEqual(ftsCount, messageCount, "FTS index must shrink with the pruned messages")
    }

    // MARK: - Count cap

    func testPruneCapsClosedSessionsKeepingMostRecent() async throws {
        var sessions: [ConversationSessionRecord] = []
        for day in stride(from: 5.0, through: 1.0, by: -1.0) {
            sessions.append(try await makeClosedSession(daysAgo: day, messages: 1))
        }
        let open = try await store.openSession()

        let result = try await store.pruneExpiredSessions(retentionDays: 0, maxSessions: 2)

        XCTAssertEqual(result.prunedSessions, 3, "cap must prune everything past the newest N")
        for stale in sessions.prefix(3) {
            let fetched = try await store.fetchSession(id: stale.id)
            XCTAssertNil(fetched, "older-than-cap closed session must be pruned")
        }
        for fresh in sessions.suffix(2) {
            let fetched = try await store.fetchSession(id: fresh.id)
            XCTAssertNotNil(fetched, "the newest N closed sessions must survive the cap")
        }
        let openFetched = try await store.fetchSession(id: open.id)
        XCTAssertNotNil(openFetched, "the open session does not count against the cap")
    }

    // MARK: - Disabled

    func testPruneDisabledWhenBothKnobsAreZero() async throws {
        _ = try await makeClosedSession(daysAgo: 500, messages: 1)

        let result = try await store.pruneExpiredSessions(retentionDays: 0, maxSessions: 0)

        XCTAssertEqual(result, SessionPruneResult(prunedSessions: 0, prunedMessages: 0))
        let sessionCount = try count(sql: "SELECT COUNT(*) FROM conversation_sessions")
        XCTAssertEqual(sessionCount, 1, "both knobs at 0 must disable GC entirely")
    }
}

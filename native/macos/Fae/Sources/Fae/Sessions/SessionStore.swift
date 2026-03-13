import Foundation
import GRDB

enum ConversationSessionKind: String, Sendable {
    case main
    case proactive
    case system
}

enum ConversationSessionStatus: String, Sendable {
    case open
    case closed
}

enum SessionMessageRole: String, Sendable {
    case user
    case assistant
    case tool
    case system
}

enum SessionContentClass: String, Sendable {
    case privateLocalOnly = "private_local_only"
}

struct ConversationSessionRecord: Sendable, Equatable {
    let id: String
    let kind: ConversationSessionKind
    let startedAt: Date
    let endedAt: Date?
    let lastMessageAt: Date
    let speakerId: String?
    let title: String?
    let messageCount: Int
    let status: ConversationSessionStatus
}

struct SessionMessageRecord: Sendable, Equatable {
    let id: String
    let sessionId: String
    let turnId: String?
    let role: SessionMessageRole
    let speakerId: String?
    let toolName: String?
    let toolCallId: String?
    let content: String
    let contentClass: SessionContentClass
    let createdAt: Date
}

struct SessionSearchSnippet: Sendable, Equatable {
    let role: SessionMessageRole
    let createdAt: Date
    let snippet: String
}

struct SessionSearchResult: Sendable, Equatable {
    let session: ConversationSessionRecord
    let summaryText: String?
    let snippets: [SessionSearchSnippet]
    let matchedMessageCount: Int
    let score: Double
}

actor SessionStore {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try dbQueue.write { db in
            try Self.applySchema(db)
        }
    }

    private static func applySchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS schema_meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)
        try db.execute(
            sql: "INSERT OR IGNORE INTO schema_meta (key, value) VALUES (?, ?)",
            arguments: ["sessions.schema_version", "1"]
        )

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS conversation_sessions (
                id              TEXT PRIMARY KEY,
                kind            TEXT NOT NULL,
                started_at      INTEGER NOT NULL,
                ended_at        INTEGER,
                last_message_at INTEGER NOT NULL,
                speaker_id      TEXT,
                title           TEXT,
                message_count   INTEGER NOT NULL DEFAULT 0,
                status          TEXT NOT NULL DEFAULT 'open'
            )
            """)
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_conversation_sessions_status ON conversation_sessions(status)"
        )
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_conversation_sessions_last_message_at ON conversation_sessions(last_message_at)"
        )

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS session_messages (
                id            TEXT PRIMARY KEY,
                session_id    TEXT NOT NULL REFERENCES conversation_sessions(id) ON DELETE CASCADE,
                turn_id       TEXT,
                role          TEXT NOT NULL,
                speaker_id    TEXT,
                tool_name     TEXT,
                tool_call_id  TEXT,
                content       TEXT NOT NULL,
                content_class TEXT NOT NULL DEFAULT 'private_local_only',
                created_at    INTEGER NOT NULL
            )
            """)
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_session_messages_session_id ON session_messages(session_id)"
        )
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_session_messages_created_at ON session_messages(created_at)"
        )
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_session_messages_turn_id ON session_messages(turn_id)"
        )

        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS session_message_fts USING fts5(
                content, content='session_messages', content_rowid='rowid'
            )
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS session_message_fts_insert AFTER INSERT ON session_messages BEGIN
                INSERT INTO session_message_fts(rowid, content) VALUES (new.rowid, new.content);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS session_message_fts_delete AFTER DELETE ON session_messages BEGIN
                INSERT INTO session_message_fts(session_message_fts, rowid, content) VALUES('delete', old.rowid, old.content);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS session_message_fts_update AFTER UPDATE OF content ON session_messages BEGIN
                INSERT INTO session_message_fts(session_message_fts, rowid, content) VALUES('delete', old.rowid, old.content);
                INSERT INTO session_message_fts(rowid, content) VALUES (new.rowid, new.content);
            END
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS session_summaries (
                id                    TEXT PRIMARY KEY,
                session_id            TEXT NOT NULL REFERENCES conversation_sessions(id) ON DELETE CASCADE,
                summary_text          TEXT NOT NULL,
                message_count_covered INTEGER NOT NULL,
                created_at            INTEGER NOT NULL,
                model_label           TEXT
            )
            """)
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_session_summaries_session_id ON session_summaries(session_id)"
        )
    }

    func openSession(
        kind: ConversationSessionKind = .main,
        speakerId: String? = nil,
        startedAt: Date = Date()
    ) throws -> ConversationSessionRecord {
        let session = ConversationSessionRecord(
            id: Self.newID(prefix: "session"),
            kind: kind,
            startedAt: startedAt,
            endedAt: nil,
            lastMessageAt: startedAt,
            speakerId: speakerId,
            title: nil,
            messageCount: 0,
            status: .open
        )

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation_sessions
                        (id, kind, started_at, ended_at, last_message_at, speaker_id, title, message_count, status)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    session.id,
                    session.kind.rawValue,
                    Self.unixTimestamp(session.startedAt),
                    nil,
                    Self.unixTimestamp(session.lastMessageAt),
                    session.speakerId,
                    session.title,
                    session.messageCount,
                    session.status.rawValue,
                ]
            )
        }

        return session
    }

    @discardableResult
    func closeOpenSessions(endedAt: Date = Date()) throws -> Int {
        let closedAt = Self.unixTimestamp(endedAt)
        return try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE conversation_sessions
                    SET ended_at = ?, last_message_at = MAX(last_message_at, ?), status = 'closed'
                    WHERE status = 'open'
                    """,
                arguments: [closedAt, closedAt]
            )
            return db.changesCount
        }
    }

    func closeSession(id: String, endedAt: Date = Date()) throws {
        let closedAt = Self.unixTimestamp(endedAt)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE conversation_sessions
                    SET ended_at = ?, last_message_at = MAX(last_message_at, ?), status = 'closed'
                    WHERE id = ?
                    """,
                arguments: [closedAt, closedAt, id]
            )
        }
    }

    @discardableResult
    func appendMessage(
        sessionId: String,
        turnId: String?,
        role: SessionMessageRole,
        content: String,
        speakerId: String? = nil,
        toolName: String? = nil,
        toolCallId: String? = nil,
        contentClass: SessionContentClass = .privateLocalOnly,
        createdAt: Date = Date()
    ) throws -> SessionMessageRecord {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = SessionMessageRecord(
            id: Self.newID(prefix: "session_msg"),
            sessionId: sessionId,
            turnId: turnId,
            role: role,
            speakerId: speakerId,
            toolName: toolName,
            toolCallId: toolCallId,
            content: trimmedContent,
            contentClass: contentClass,
            createdAt: createdAt
        )

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO session_messages
                        (id, session_id, turn_id, role, speaker_id, tool_name, tool_call_id, content, content_class, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id,
                    record.sessionId,
                    record.turnId,
                    record.role.rawValue,
                    record.speakerId,
                    record.toolName,
                    record.toolCallId,
                    record.content,
                    record.contentClass.rawValue,
                    Self.unixTimestamp(record.createdAt),
                ]
            )

            let title = role == .user ? Self.derivedTitle(from: trimmedContent) : nil
            try db.execute(
                sql: """
                    UPDATE conversation_sessions
                    SET last_message_at = ?,
                        message_count = message_count + 1,
                        speaker_id = COALESCE(speaker_id, ?),
                        title = CASE
                            WHEN (? IS NOT NULL) AND (title IS NULL OR TRIM(title) = '') THEN ?
                            ELSE title
                        END
                    WHERE id = ?
                    """,
                arguments: [
                    Self.unixTimestamp(record.createdAt),
                    record.speakerId,
                    title,
                    title,
                    record.sessionId,
                ]
            )
        }

        return record
    }

    func fetchSession(id: String) throws -> ConversationSessionRecord? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversation_sessions WHERE id = ? LIMIT 1",
                arguments: [id]
            )
            return row.map(Self.sessionFromRow)
        }
    }

    func recentSessions(limit: Int = 20) throws -> [ConversationSessionRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM conversation_sessions
                    ORDER BY last_message_at DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return rows.map(Self.sessionFromRow)
        }
    }

    func messages(sessionId: String, limit: Int = 200) throws -> [SessionMessageRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM session_messages
                    WHERE session_id = ?
                    ORDER BY created_at ASC
                    LIMIT ?
                    """,
                arguments: [sessionId, limit]
            )
            return rows.map(Self.messageFromRow)
        }
    }

    func searchSessions(
        query: String,
        limit: Int = 5,
        days: Int = 180,
        kinds: Set<ConversationSessionKind> = [.main]
    ) throws -> [SessionSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let normalizedQuery = Self.normalizeSearchText(trimmedQuery)
        let tokens = Self.searchTokens(from: trimmedQuery)
        guard !tokens.isEmpty else { return [] }

        let clampedLimit = min(max(limit, 1), 10)
        let clampedDays = min(max(days, 1), 3650)
        let hitLimit = max(clampedLimit * 8, clampedLimit)
        let cutoff = Date().addingTimeInterval(-Double(clampedDays) * 86_400)

        return try dbQueue.read { db in
            let kindValues = Array(kinds).map(\.rawValue).sorted()
            var sql = """
                SELECT
                    sm.content AS message_content,
                    sm.role AS message_role,
                    sm.created_at AS message_created_at,
                    cs.id AS session_id,
                    cs.kind AS session_kind,
                    cs.started_at AS session_started_at,
                    cs.ended_at AS session_ended_at,
                    cs.last_message_at AS session_last_message_at,
                    cs.speaker_id AS session_speaker_id,
                    cs.title AS session_title,
                    cs.message_count AS session_message_count,
                    cs.status AS session_status,
                    snippet(session_message_fts, 0, '[', ']', ' ... ', 12) AS match_snippet,
                    bm25(session_message_fts) AS rank,
                    (
                        SELECT summary_text
                        FROM session_summaries
                        WHERE session_id = cs.id
                        ORDER BY created_at DESC
                        LIMIT 1
                    ) AS session_summary_text
                FROM session_message_fts
                JOIN session_messages AS sm ON sm.rowid = session_message_fts.rowid
                JOIN conversation_sessions AS cs ON cs.id = sm.session_id
                WHERE session_message_fts MATCH ?
                  AND cs.last_message_at >= ?
                """

            var arguments: StatementArguments = [
                Self.ftsMatchQuery(from: tokens),
                Self.unixTimestamp(cutoff),
            ]

            if !kindValues.isEmpty {
                let placeholders = Array(repeating: "?", count: kindValues.count).joined(separator: ", ")
                sql += "\n  AND cs.kind IN (\(placeholders))"
                for kind in kindValues {
                    arguments += [kind]
                }
            }

            sql += """

                ORDER BY bm25(session_message_fts), sm.created_at DESC
                LIMIT ?
                """
            arguments += [hitLimit]

            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            guard !rows.isEmpty else { return [] }

            var grouped: [String: SessionSearchAccumulator] = [:]
            var orderedSessionIDs: [String] = []
            let minimumTokenMatches = tokens.count == 1 ? 1 : min(2, tokens.count)

            for (index, row) in rows.enumerated() {
                let content: String = row["message_content"]
                let matchedTokenCount = Self.matchedTokenCount(in: content, tokens: tokens)
                guard matchedTokenCount >= minimumTokenMatches else { continue }

                let session = Self.sessionFromSearchRow(row)
                let sessionID = session.id
                let snippet = Self.cleanSnippet((row["match_snippet"] as String?) ?? content)
                let role = SessionMessageRole(rawValue: row["message_role"]) ?? .system
                let createdAt = Self.dateFromTimestamp(row["message_created_at"] as Int64?)
                let exactPhraseMatch = Self.normalizeSearchText(content).contains(normalizedQuery)
                let coverage = Double(matchedTokenCount) / Double(max(tokens.count, 1))
                let phraseBonus = exactPhraseMatch ? 1.0 : 0.0
                let score = coverage + phraseBonus
                let summaryText = (row["session_summary_text"] as String?)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if grouped[sessionID] == nil {
                    grouped[sessionID] = SessionSearchAccumulator(
                        session: session,
                        summaryText: summaryText,
                        snippets: [],
                        matchedMessageCount: 0,
                        score: score,
                        firstHitIndex: index
                    )
                    orderedSessionIDs.append(sessionID)
                }

                guard var accumulator = grouped[sessionID] else { continue }
                accumulator.matchedMessageCount += 1
                accumulator.score = max(accumulator.score, score)
                if accumulator.summaryText == nil, let summaryText, !summaryText.isEmpty {
                    accumulator.summaryText = summaryText
                }
                if accumulator.snippets.count < 2,
                   !accumulator.snippets.contains(where: { $0.snippet == snippet && $0.role == role })
                {
                    accumulator.snippets.append(
                        SessionSearchSnippet(
                            role: role,
                            createdAt: createdAt,
                            snippet: snippet
                        )
                    )
                }
                grouped[sessionID] = accumulator
            }

            return orderedSessionIDs
                .compactMap { grouped[$0] }
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score {
                        return lhs.score > rhs.score
                    }
                    if lhs.session.lastMessageAt != rhs.session.lastMessageAt {
                        return lhs.session.lastMessageAt > rhs.session.lastMessageAt
                    }
                    return lhs.firstHitIndex < rhs.firstHitIndex
                }
                .prefix(clampedLimit)
                .map { accumulator in
                    SessionSearchResult(
                        session: accumulator.session,
                        summaryText: accumulator.summaryText,
                        snippets: accumulator.snippets.sorted { $0.createdAt < $1.createdAt },
                        matchedMessageCount: accumulator.matchedMessageCount,
                        score: accumulator.score
                    )
                }
        }
    }

    private static func sessionFromRow(_ row: Row) -> ConversationSessionRecord {
        let endedAtRaw: Int64? = row["ended_at"]
        let messageCountRaw: Int64? = row["message_count"]
        return ConversationSessionRecord(
            id: row["id"],
            kind: ConversationSessionKind(rawValue: row["kind"]) ?? .main,
            startedAt: dateFromTimestamp(row["started_at"] as Int64?),
            endedAt: optionalDateFromTimestamp(endedAtRaw),
            lastMessageAt: dateFromTimestamp(row["last_message_at"] as Int64?),
            speakerId: row["speaker_id"],
            title: row["title"],
            messageCount: Int(messageCountRaw ?? 0),
            status: ConversationSessionStatus(rawValue: row["status"]) ?? .open
        )
    }

    private static func messageFromRow(_ row: Row) -> SessionMessageRecord {
        SessionMessageRecord(
            id: row["id"],
            sessionId: row["session_id"],
            turnId: row["turn_id"],
            role: SessionMessageRole(rawValue: row["role"]) ?? .system,
            speakerId: row["speaker_id"],
            toolName: row["tool_name"],
            toolCallId: row["tool_call_id"],
            content: row["content"],
            contentClass: SessionContentClass(rawValue: row["content_class"]) ?? .privateLocalOnly,
            createdAt: dateFromTimestamp(row["created_at"] as Int64?)
        )
    }

    private static func sessionFromSearchRow(_ row: Row) -> ConversationSessionRecord {
        let endedAtRaw: Int64? = row["session_ended_at"]
        let messageCountRaw: Int64? = row["session_message_count"]
        return ConversationSessionRecord(
            id: row["session_id"],
            kind: ConversationSessionKind(rawValue: row["session_kind"]) ?? .main,
            startedAt: dateFromTimestamp(row["session_started_at"] as Int64?),
            endedAt: optionalDateFromTimestamp(endedAtRaw),
            lastMessageAt: dateFromTimestamp(row["session_last_message_at"] as Int64?),
            speakerId: row["session_speaker_id"],
            title: row["session_title"],
            messageCount: Int(messageCountRaw ?? 0),
            status: ConversationSessionStatus(rawValue: row["session_status"]) ?? .open
        )
    }

    private static func unixTimestamp(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970)
    }

    private static func dateFromTimestamp(_ value: Int64?) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value ?? 0))
    }

    private static func optionalDateFromTimestamp(_ value: Int64?) -> Date? {
        guard let value else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }

    private static func newID(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString)"
    }

    private static func derivedTitle(from content: String) -> String? {
        let collapsed = content
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(80))
    }

    private static func searchTokens(from query: String) -> [String] {
        let rawTokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let filtered = rawTokens.filter {
            $0.count >= 2 && !searchStopwords.contains($0)
        }

        let effectiveTokens = filtered.isEmpty
            ? rawTokens.filter { $0.count >= 2 }
            : filtered

        var uniqueTokens: [String] = []
        var seen: Set<String> = []
        for token in effectiveTokens {
            if seen.insert(token).inserted {
                uniqueTokens.append(token)
            }
            if uniqueTokens.count == 8 {
                break
            }
        }
        return uniqueTokens
    }

    private static func ftsMatchQuery(from tokens: [String]) -> String {
        tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }

    private static func matchedTokenCount(in content: String, tokens: [String]) -> Int {
        let normalizedContent = normalizeSearchText(content)
        return tokens.reduce(into: 0) { count, token in
            if normalizedContent.contains(token) {
                count += 1
            }
        }
    }

    private static func normalizeSearchText(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanSnippet(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let searchStopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by",
        "did", "do", "for", "from", "had", "has", "have", "how",
        "i", "if", "in", "is", "it", "me", "my", "of", "on", "or",
        "our", "that", "the", "their", "them", "there", "they", "this",
        "to", "us", "was", "we", "were", "what", "when", "where",
        "which", "who", "why", "with", "you", "your",
    ]
}

private struct SessionSearchAccumulator {
    let session: ConversationSessionRecord
    var summaryText: String?
    var snippets: [SessionSearchSnippet]
    var matchedMessageCount: Int
    var score: Double
    let firstHitIndex: Int
}

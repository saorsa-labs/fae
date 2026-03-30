import Foundation
import GRDB

// MARK: - Record Types

/// A single feedback event captured from a conversation turn.
///
/// Feedback events are the raw signal for the improvement loop. They represent
/// moments where the user implicitly or explicitly indicated satisfaction or
/// dissatisfaction with Fae's response.
struct FeedbackEvent: Sendable {
    /// Auto-assigned integer row id. `nil` before insertion.
    var id: Int64?
    /// ISO-8601 timestamp when the event was recorded.
    let recordedAt: String
    /// Type of feedback signal: re_ask | abandonment | follow_through |
    /// interruption | praise | topic_change | silence_acceptance | correction.
    let signalType: String
    /// SHA-256 fingerprint of the assistant turn that triggered this event.
    let turnFingerprint: String
    /// Excerpt of the user's follow-up or correction (nil for implicit signals).
    let userInput: String?
    /// Excerpt of the assistant turn being rated.
    let assistantOutput: String?
    /// Sentiment score: -1.0 (very negative) to +1.0 (very positive). Nil if not computed.
    let sentimentScore: Double?
    /// True when this event has been incorporated into a training cycle.
    var consumed: Bool
}

/// A baseline performance measurement for a model+adapter combination.
///
/// Baselines are captured before each training cycle so that post-cycle evaluation
/// results can be compared against them to determine whether to deploy or roll back.
struct ImprovementBaseline: Sendable {
    var id: Int64?
    let measuredAt: String
    let modelID: String
    let adapterPath: String?
    let adapterVersion: String?
    let toolCallingAccuracy: Double?
    let faeCapabilityAccuracy: Double?
    let assistantFitAccuracy: Double?
    let serializationAccuracy: Double?
    let avgThroughputTPS: Double?
    let feedbackEventCount: Int
}

/// Persistent state for the ImprovementCycleCoordinator state machine.
///
/// Only one row exists at a time. The coordinator reads this at startup and writes
/// it at every state transition so recovery is possible after a crash.
struct ImprovementState: Sendable {
    var id: Int64?
    /// Current state: idle | collecting | training | evaluating | proposing | deploying.
    var cycleState: String
    var lastCycleAt: String?
    var completedCycles: Int
    var userApprovedCycles: Int
    var currentAdapterPath: String?
    var previousAdapterPath: String?
    var trainingStartedAt: String?
    var lastCycleError: String?
    /// Number of consecutive CONCERN deferrals in the current review sequence.
    var deferralCount: Int
}

/// A detected gap between current Fae capabilities and desired behaviour.
struct CapabilityGap: Sendable {
    var id: Int64?
    let detectedAt: String
    let category: String
    let description: String
    var evidenceCount: Int
    let priority: String
    var addressed: Bool
}

/// A single episode recorded for shadow evaluation.
struct ShadowEvalEpisode: Sendable {
    var id: Int64?
    let recordedAt: String
    /// JSON-serialised conversation history (array of {role, content} objects).
    let conversationJSON: String
    let actualResponse: String
    let receptionScore: Double?
    var evaluated: Bool
    var evalOutcome: String?
}

// MARK: - Errors

/// Errors produced by `ImprovementStore` operations.
enum ImprovementStoreError: Error, Sendable {
    /// The store has not been opened yet.
    case notOpen
    /// No singleton improvement state row exists. Call `ensureStateRow()` first.
    case stateNotInitialised
}

// MARK: - ImprovementStore

/// Persistent store for the autonomous self-improvement loop.
///
/// `ImprovementStore` owns `improvement.db` — a dedicated SQLite database separate
/// from `fae.db` and `scheduler.db`. Keeping improvement data isolated prevents a
/// training-cycle schema change from affecting the main memory database.
///
/// All operations are actor-isolated; callers always use `await`.
///
/// ## Usage
/// ```swift
/// let store = ImprovementStore()
/// try store.open()
/// try store.appendFeedbackEvent(...)
/// ```
actor ImprovementStore {

    // MARK: - State

    private var db: DatabaseQueue?

    // MARK: - Lifecycle

    /// Open the database at the default path, running schema migrations as needed.
    ///
    /// Safe to call multiple times; subsequent calls are no-ops if already open.
    func open() throws {
        try open(at: FaeDirectories.improvementDatabase)
    }

    /// Open the database at a custom path, running schema migrations as needed.
    ///
    /// Primarily used for testing with isolated temporary databases.
    /// Safe to call multiple times; subsequent calls are no-ops if already open.
    ///
    /// - Parameter url: The file URL for the SQLite database.
    func open(at url: URL) throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try queue.write { db in try Self.applySchema(db) }
        self.db = queue
        NSLog("ImprovementStore: opened at %@", url.path)
    }

    /// Close the database connection.
    func close() {
        db = nil
    }

    // MARK: - Schema (private, sync)

    private static func applySchema(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS feedback_events (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                recorded_at      TEXT    NOT NULL,
                signal_type      TEXT    NOT NULL,
                turn_fingerprint TEXT    NOT NULL,
                user_input       TEXT,
                assistant_output TEXT,
                sentiment_score  REAL,
                consumed         INTEGER NOT NULL DEFAULT 0
            )
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_fe_consumed
            ON feedback_events (consumed, recorded_at ASC)
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS improvement_baselines (
                id                       INTEGER PRIMARY KEY AUTOINCREMENT,
                measured_at              TEXT    NOT NULL,
                model_id                 TEXT    NOT NULL,
                adapter_path             TEXT,
                adapter_version          TEXT,
                tool_calling_accuracy    REAL,
                fae_capability_accuracy  REAL,
                assistant_fit_accuracy   REAL,
                serialization_accuracy   REAL,
                avg_throughput_tps       REAL,
                feedback_event_count     INTEGER NOT NULL DEFAULT 0
            )
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS improvement_state (
                id                    INTEGER PRIMARY KEY AUTOINCREMENT,
                cycle_state           TEXT    NOT NULL DEFAULT 'idle',
                last_cycle_at         TEXT,
                completed_cycles      INTEGER NOT NULL DEFAULT 0,
                user_approved_cycles  INTEGER NOT NULL DEFAULT 0,
                current_adapter_path  TEXT,
                previous_adapter_path TEXT,
                training_started_at   TEXT,
                last_cycle_error      TEXT,
                deferral_count        INTEGER NOT NULL DEFAULT 0
            )
        """)
        // Migration: add deferral_count to existing databases that lack the column.
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(improvement_state)")
        let columnNames = columns.compactMap { $0["name"] as? String }
        if !columnNames.contains("deferral_count") {
            try db.execute(sql: "ALTER TABLE improvement_state ADD COLUMN deferral_count INTEGER NOT NULL DEFAULT 0")
        }
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS capability_gaps (
                id             INTEGER PRIMARY KEY AUTOINCREMENT,
                detected_at    TEXT    NOT NULL,
                category       TEXT    NOT NULL,
                description    TEXT    NOT NULL,
                evidence_count INTEGER NOT NULL DEFAULT 1,
                priority       TEXT    NOT NULL DEFAULT 'medium',
                addressed      INTEGER NOT NULL DEFAULT 0
            )
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS shadow_eval (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                recorded_at       TEXT    NOT NULL,
                conversation_json TEXT    NOT NULL,
                actual_response   TEXT    NOT NULL,
                reception_score   REAL,
                evaluated         INTEGER NOT NULL DEFAULT 0,
                eval_outcome      TEXT
            )
        """)
    }

    // MARK: - Singleton State Row

    /// Ensure the singleton `improvement_state` row exists. Idempotent.
    func ensureStateRow() throws {
        guard let db else { throw ImprovementStoreError.notOpen }
        try db.write { db in
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM improvement_state"
            ) ?? 0
            if count == 0 {
                try db.execute(sql: """
                    INSERT INTO improvement_state
                        (cycle_state, completed_cycles, user_approved_cycles, deferral_count)
                    VALUES ('idle', 0, 0, 0)
                """)
            }
        }
    }

    // MARK: - FeedbackEvent CRUD

    /// Append a new feedback event and return the stored record with its `id` assigned.
    @discardableResult
    func appendFeedbackEvent(_ event: FeedbackEvent) throws -> FeedbackEvent {
        guard let db else { throw ImprovementStoreError.notOpen }
        let rowID = try db.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO feedback_events
                        (recorded_at, signal_type, turn_fingerprint, user_input,
                         assistant_output, sentiment_score, consumed)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    event.recordedAt, event.signalType, event.turnFingerprint,
                    event.userInput, event.assistantOutput, event.sentimentScore,
                    event.consumed ? 1 : 0,
                ]
            )
            return db.lastInsertedRowID
        }
        var stored = event
        stored.id = rowID
        return stored
    }

    /// Fetch all unconsumed feedback events, ordered oldest-first.
    func pendingFeedbackEvents() throws -> [FeedbackEvent] {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, recorded_at, signal_type, turn_fingerprint, user_input,
                       assistant_output, sentiment_score, consumed
                FROM feedback_events
                WHERE consumed = 0
                ORDER BY recorded_at ASC
            """)
            return rows.map { Self.feedbackEvent(from: $0) }
        }
    }

    /// Mark a list of feedback events as consumed.
    func markConsumed(ids: [Int64]) throws {
        guard let db else { throw ImprovementStoreError.notOpen }
        guard !ids.isEmpty else { return }
        try db.write { db in
            for id in ids {
                try db.execute(
                    sql: "UPDATE feedback_events SET consumed = 1 WHERE id = ?",
                    arguments: [id]
                )
            }
        }
    }

    /// Count unconsumed feedback events.
    func pendingFeedbackCount() throws -> Int {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM feedback_events WHERE consumed = 0"
            ) ?? 0
        }
    }

    /// Count unconsumed feedback events whose `signal_type` is `"correction"`.
    func correctionFeedbackCount() throws -> Int {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM feedback_events WHERE consumed = 0 AND signal_type = 'correction'"
            ) ?? 0
        }
    }

    // MARK: - ImprovementBaseline CRUD

    /// Insert a new baseline measurement. Returns the stored record with `id` assigned.
    @discardableResult
    func insertBaseline(_ baseline: ImprovementBaseline) throws -> ImprovementBaseline {
        guard let db else { throw ImprovementStoreError.notOpen }
        let rowID = try db.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO improvement_baselines
                        (measured_at, model_id, adapter_path, adapter_version,
                         tool_calling_accuracy, fae_capability_accuracy,
                         assistant_fit_accuracy, serialization_accuracy,
                         avg_throughput_tps, feedback_event_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    baseline.measuredAt, baseline.modelID,
                    baseline.adapterPath, baseline.adapterVersion,
                    baseline.toolCallingAccuracy, baseline.faeCapabilityAccuracy,
                    baseline.assistantFitAccuracy, baseline.serializationAccuracy,
                    baseline.avgThroughputTPS, baseline.feedbackEventCount,
                ]
            )
            return db.lastInsertedRowID
        }
        var stored = baseline
        stored.id = rowID
        return stored
    }

    /// Fetch the most recent baseline for a given model ID.
    func latestBaseline(for modelID: String) throws -> ImprovementBaseline? {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, measured_at, model_id, adapter_path, adapter_version,
                       tool_calling_accuracy, fae_capability_accuracy,
                       assistant_fit_accuracy, serialization_accuracy,
                       avg_throughput_tps, feedback_event_count
                FROM improvement_baselines
                WHERE model_id = ?
                ORDER BY measured_at DESC
                LIMIT 1
            """, arguments: [modelID]) else { return nil }
            return Self.improvementBaseline(from: row)
        }
    }

    // MARK: - ImprovementState CRUD

    /// Read the singleton improvement state.
    func readState() throws -> ImprovementState {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, cycle_state, last_cycle_at, completed_cycles,
                       user_approved_cycles, current_adapter_path,
                       previous_adapter_path, training_started_at, last_cycle_error,
                       deferral_count
                FROM improvement_state LIMIT 1
            """) else {
                throw ImprovementStoreError.stateNotInitialised
            }
            return Self.improvementState(from: row)
        }
    }

    /// Overwrite the singleton improvement state.
    func writeState(_ state: ImprovementState) throws {
        guard let db else { throw ImprovementStoreError.notOpen }
        try db.write { db in
            if let id = state.id {
                try db.execute(
                    sql: """
                        UPDATE improvement_state SET
                            cycle_state = ?, last_cycle_at = ?, completed_cycles = ?,
                            user_approved_cycles = ?, current_adapter_path = ?,
                            previous_adapter_path = ?, training_started_at = ?,
                            last_cycle_error = ?, deferral_count = ?
                        WHERE id = ?
                    """,
                    arguments: [
                        state.cycleState, state.lastCycleAt,
                        state.completedCycles, state.userApprovedCycles,
                        state.currentAdapterPath, state.previousAdapterPath,
                        state.trainingStartedAt, state.lastCycleError,
                        state.deferralCount, id,
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO improvement_state
                            (cycle_state, last_cycle_at, completed_cycles,
                             user_approved_cycles, current_adapter_path,
                             previous_adapter_path, training_started_at, last_cycle_error,
                             deferral_count)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        state.cycleState, state.lastCycleAt,
                        state.completedCycles, state.userApprovedCycles,
                        state.currentAdapterPath, state.previousAdapterPath,
                        state.trainingStartedAt, state.lastCycleError,
                        state.deferralCount,
                    ]
                )
            }
        }
    }

    /// Increment the deferral counter by 1 and return the new value.
    @discardableResult
    func incrementDeferral() throws -> Int {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.write { db in
            try db.execute(sql: "UPDATE improvement_state SET deferral_count = deferral_count + 1")
            return try Int.fetchOne(db, sql: "SELECT deferral_count FROM improvement_state LIMIT 1") ?? 0
        }
    }

    /// Reset the deferral counter to 0.
    func resetDeferrals() throws {
        guard let db else { throw ImprovementStoreError.notOpen }
        try db.write { db in
            try db.execute(sql: "UPDATE improvement_state SET deferral_count = 0")
        }
    }

    // MARK: - CapabilityGap CRUD

    /// Insert a new capability gap. Returns the stored record with `id` assigned.
    @discardableResult
    func insertGap(_ gap: CapabilityGap) throws -> CapabilityGap {
        guard let db else { throw ImprovementStoreError.notOpen }
        let rowID = try db.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO capability_gaps
                        (detected_at, category, description,
                         evidence_count, priority, addressed)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    gap.detectedAt, gap.category, gap.description,
                    gap.evidenceCount, gap.priority, gap.addressed ? 1 : 0,
                ]
            )
            return db.lastInsertedRowID
        }
        var stored = gap
        stored.id = rowID
        return stored
    }

    /// Fetch all unaddressed gaps, ordered by priority (high first) then detection time.
    func unaddressedGaps() throws -> [CapabilityGap] {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, detected_at, category, description,
                       evidence_count, priority, addressed
                FROM capability_gaps
                WHERE addressed = 0
                ORDER BY
                    CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END,
                    detected_at ASC
            """)
            return rows.map { Self.capabilityGap(from: $0) }
        }
    }

    /// Mark a gap as addressed.
    func markGapAddressed(id: Int64) throws {
        guard let db else { throw ImprovementStoreError.notOpen }
        try db.write { db in
            try db.execute(
                sql: "UPDATE capability_gaps SET addressed = 1 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - ShadowEvalEpisode CRUD

    /// Append a new shadow eval episode. Returns the stored record with `id` assigned.
    @discardableResult
    func appendShadowEpisode(_ episode: ShadowEvalEpisode) throws -> ShadowEvalEpisode {
        guard let db else { throw ImprovementStoreError.notOpen }
        let rowID = try db.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO shadow_eval
                        (recorded_at, conversation_json, actual_response,
                         reception_score, evaluated, eval_outcome)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    episode.recordedAt, episode.conversationJSON, episode.actualResponse,
                    episode.receptionScore, episode.evaluated ? 1 : 0, episode.evalOutcome,
                ]
            )
            return db.lastInsertedRowID
        }
        var stored = episode
        stored.id = rowID
        return stored
    }

    /// Fetch episodes not yet evaluated, up to `limit` results.
    func unevaluatedEpisodes(limit: Int = 50) throws -> [ShadowEvalEpisode] {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, recorded_at, conversation_json, actual_response,
                       reception_score, evaluated, eval_outcome
                FROM shadow_eval
                WHERE evaluated = 0
                ORDER BY recorded_at ASC
                LIMIT \(limit)
            """)
            return rows.map { Self.shadowEvalEpisode(from: $0) }
        }
    }

    /// Record the outcome of a shadow eval episode.
    func recordEvalOutcome(id: Int64, outcome: String) throws {
        guard let db else { throw ImprovementStoreError.notOpen }
        try db.write { db in
            try db.execute(
                sql: "UPDATE shadow_eval SET evaluated = 1, eval_outcome = ? WHERE id = ?",
                arguments: [outcome, id]
            )
        }
    }

    /// Count shadow eval episodes by outcome.
    ///
    /// - Returns: A tuple with counts for base-wins, adapter-wins, and ties.
    func shadowEvalCounts() throws -> (baseWins: Int, adapterWins: Int, ties: Int) {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            let base = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM shadow_eval WHERE eval_outcome = 'base_wins'"
            ) ?? 0
            let adapter = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM shadow_eval WHERE eval_outcome = 'adapter_wins'"
            ) ?? 0
            let ties = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM shadow_eval WHERE eval_outcome = 'tie'"
            ) ?? 0
            return (base, adapter, ties)
        }
    }

    // MARK: - Row Mappers (private, static, sync)

    private static func feedbackEvent(from row: Row) -> FeedbackEvent {
        FeedbackEvent(
            id: row["id"],
            recordedAt: row["recorded_at"] ?? "",
            signalType: row["signal_type"] ?? "",
            turnFingerprint: row["turn_fingerprint"] ?? "",
            userInput: row["user_input"],
            assistantOutput: row["assistant_output"],
            sentimentScore: row["sentiment_score"],
            consumed: (row["consumed"] as? Int64 ?? 0) != 0
        )
    }

    private static func improvementBaseline(from row: Row) -> ImprovementBaseline {
        ImprovementBaseline(
            id: row["id"],
            measuredAt: row["measured_at"] ?? "",
            modelID: row["model_id"] ?? "",
            adapterPath: row["adapter_path"],
            adapterVersion: row["adapter_version"],
            toolCallingAccuracy: row["tool_calling_accuracy"],
            faeCapabilityAccuracy: row["fae_capability_accuracy"],
            assistantFitAccuracy: row["assistant_fit_accuracy"],
            serializationAccuracy: row["serialization_accuracy"],
            avgThroughputTPS: row["avg_throughput_tps"],
            feedbackEventCount: Int(row["feedback_event_count"] as? Int64 ?? 0)
        )
    }

    private static func improvementState(from row: Row) -> ImprovementState {
        ImprovementState(
            id: row["id"],
            cycleState: row["cycle_state"] ?? "idle",
            lastCycleAt: row["last_cycle_at"],
            completedCycles: Int(row["completed_cycles"] as? Int64 ?? 0),
            userApprovedCycles: Int(row["user_approved_cycles"] as? Int64 ?? 0),
            currentAdapterPath: row["current_adapter_path"],
            previousAdapterPath: row["previous_adapter_path"],
            trainingStartedAt: row["training_started_at"],
            lastCycleError: row["last_cycle_error"],
            deferralCount: Int(row["deferral_count"] as? Int64 ?? 0)
        )
    }

    private static func capabilityGap(from row: Row) -> CapabilityGap {
        CapabilityGap(
            id: row["id"],
            detectedAt: row["detected_at"] ?? "",
            category: row["category"] ?? "",
            description: row["description"] ?? "",
            evidenceCount: Int(row["evidence_count"] as? Int64 ?? 1),
            priority: row["priority"] ?? "medium",
            addressed: (row["addressed"] as? Int64 ?? 0) != 0
        )
    }

    private static func shadowEvalEpisode(from row: Row) -> ShadowEvalEpisode {
        ShadowEvalEpisode(
            id: row["id"],
            recordedAt: row["recorded_at"] ?? "",
            conversationJSON: row["conversation_json"] ?? "",
            actualResponse: row["actual_response"] ?? "",
            receptionScore: row["reception_score"],
            evaluated: (row["evaluated"] as? Int64 ?? 0) != 0,
            evalOutcome: row["eval_outcome"]
        )
    }
}

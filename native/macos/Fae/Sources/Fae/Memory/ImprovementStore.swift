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
    /// The directive text before the last directive-tuning amendment, for rollback.
    var previousDirective: String?

    // Meta-optimization tracking (Phase 1).

    /// Lifetime count of kept meta-optimization changes.
    var metaOptKeptTotal: Int
    /// Lifetime count of tested meta-optimization hypotheses.
    var metaOptTestedTotal: Int
    /// ISO-8601 timestamp of last meta-optimization run.
    var metaOptLastRunAt: String?
    /// Consecutive cycles with zero kept changes (plateau detection).
    var metaOptConsecutiveNoImprovement: Int

    // P9/C4 (W3) — candidate state, kept SEPARATE from the deployed pointer.

    /// The candidate adapter under evaluation. Written by the training step; it is
    /// NEVER the deployed pointer. Promoted to `currentAdapterPath` only by a gated
    /// deploy, and cleared on any terminal non-deploy outcome (block / reject /
    /// abort). This keeps an un-evaluated candidate from ever polluting the live
    /// `currentAdapterPath`, on any path or after a crash.
    var pendingAdapterPath: String? = nil

    /// The candidate's artifact kind ("gguf" | "mlxDir"), for the W4 evaluator and
    /// deploy routing.
    var pendingAdapterKind: String? = nil

    /// The cycle id that produced the pending candidate (P9/C4 W4). Binds the candidate
    /// to its `gate_receipts` row so the deploy gate can require a verifying receipt for
    /// this exact cycle.
    var pendingCycleId: String? = nil
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
    /// The gate receipt to consume was missing or already consumed (P9/C4 W4) — the
    /// atomic promote+consume transaction was rolled back.
    case receiptNotConsumable
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
                deferral_count        INTEGER NOT NULL DEFAULT 0,
                previous_directive    TEXT,
                pending_adapter_path  TEXT,
                pending_adapter_kind  TEXT,
                pending_cycle_id      TEXT
            )
        """)
        // Migration: add columns to existing databases that lack them.
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(improvement_state)")
        let columnNames = columns.compactMap { $0["name"] as? String }
        if !columnNames.contains("deferral_count") {
            try db.execute(sql: "ALTER TABLE improvement_state ADD COLUMN deferral_count INTEGER NOT NULL DEFAULT 0")
        }
        if !columnNames.contains("previous_directive") {
            try db.execute(sql: "ALTER TABLE improvement_state ADD COLUMN previous_directive TEXT")
        }
        // Migration: meta-optimization tracking columns (Phase 1).
        if !columnNames.contains("meta_opt_kept_total") {
            try db.execute(sql: "ALTER TABLE improvement_state ADD COLUMN meta_opt_kept_total INTEGER NOT NULL DEFAULT 0")
        }
        if !columnNames.contains("meta_opt_tested_total") {
            try db.execute(sql: "ALTER TABLE improvement_state ADD COLUMN meta_opt_tested_total INTEGER NOT NULL DEFAULT 0")
        }
        if !columnNames.contains("meta_opt_last_run_at") {
            try db.execute(sql: "ALTER TABLE improvement_state ADD COLUMN meta_opt_last_run_at TEXT")
        }
        if !columnNames.contains("meta_opt_consecutive_no_improvement") {
            try db.execute(sql: "ALTER TABLE improvement_state ADD COLUMN meta_opt_consecutive_no_improvement INTEGER NOT NULL DEFAULT 0")
        }
        // Migration: candidate (pending) adapter columns, kept separate from the
        // deployed pointer (P9/C4 W3).
        if !columnNames.contains("pending_adapter_path") {
            try db.execute(sql: "ALTER TABLE improvement_state ADD COLUMN pending_adapter_path TEXT")
        }
        if !columnNames.contains("pending_adapter_kind") {
            try db.execute(sql: "ALTER TABLE improvement_state ADD COLUMN pending_adapter_kind TEXT")
        }
        if !columnNames.contains("pending_cycle_id") {
            try db.execute(sql: "ALTER TABLE improvement_state ADD COLUMN pending_cycle_id TEXT")
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
        // Meta-optimization results log (Phase 1).
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS meta_optimization_log (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                cycle_number     INTEGER NOT NULL,
                hypothesis_id    TEXT    NOT NULL,
                surface          TEXT    NOT NULL,
                description      TEXT    NOT NULL,
                target_dimension TEXT    NOT NULL,
                before_scores    TEXT    NOT NULL,
                after_scores     TEXT    NOT NULL,
                delta            TEXT    NOT NULL,
                kept             INTEGER NOT NULL DEFAULT 0,
                reason           TEXT    NOT NULL,
                created_at       TEXT    NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_mol_cycle
            ON meta_optimization_log (cycle_number, kept)
        """)
        // P9/C4 (W2): persisted gate receipts — tamper-evident proof a candidate passed
        // a real eval. W4 requires a verifying, unconsumed receipt before any deploy.
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS gate_receipts (
                cycle_id            TEXT    PRIMARY KEY,
                candidate_path      TEXT    NOT NULL,
                kind                TEXT    NOT NULL,
                artifact_digest     TEXT    NOT NULL,
                measured_json       TEXT    NOT NULL,
                decision            TEXT    NOT NULL,
                evaluator_id        TEXT    NOT NULL,
                base_model_id       TEXT    NOT NULL,
                eval_suite_version  TEXT    NOT NULL,
                gate_policy_version INTEGER NOT NULL,
                receipt_version     INTEGER NOT NULL,
                minted_at           TEXT    NOT NULL,
                hmac                TEXT    NOT NULL,
                consumed_at         TEXT
            )
        """)
        // F14: crash-durable rollback journal for the DISK-persisting meta-opt surfaces
        // (directive file, live config). A row is written BEFORE the change is applied and
        // deleted after a confirmed rollback OR a confirmed keep. Any row still present at
        // startup is an orphaned unvalidated change (the app crashed/was killed mid-benchmark)
        // and is rolled back by replaying its stored old value. Skills/memory seeds are NOT
        // journaled here (they persist to their own stores with their own rollback).
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS meta_opt_rollback_journal (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                surface     TEXT    NOT NULL,
                config_key  TEXT,
                old_value   TEXT    NOT NULL,
                description TEXT    NOT NULL,
                applied_at  TEXT    NOT NULL
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
                        (cycle_state, completed_cycles, user_approved_cycles, deferral_count,
                         meta_opt_kept_total, meta_opt_tested_total, meta_opt_consecutive_no_improvement)
                    VALUES ('idle', 0, 0, 0, 0, 0, 0)
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
                       deferral_count, previous_directive,
                       meta_opt_kept_total, meta_opt_tested_total,
                       meta_opt_last_run_at, meta_opt_consecutive_no_improvement,
                       pending_adapter_path, pending_adapter_kind, pending_cycle_id
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
        try db.write { db in try Self.upsertState(db, state) }
    }

    /// Atomically promote (write `state`) AND consume the gate receipt for `cycleId` in
    /// ONE transaction (P9/C4 W4). The consume is `UPDATE … WHERE consumed_at IS NULL`;
    /// it must affect exactly one row — otherwise the receipt is missing or already
    /// consumed, the whole transaction rolls back, and this throws. This makes deploy +
    /// single-use atomic: a deploy can never commit without consuming a STORED, unconsumed
    /// receipt, and a receipt can never be double-spent (closes the missing-row bypass,
    /// the promote-then-consume window, and the check/consume TOCTOU together).
    func promoteAndConsumeReceipt(
        state: ImprovementState, cycleId: String, at timestamp: String
    ) throws {
        guard let db else { throw ImprovementStoreError.notOpen }
        try db.write { db in
            try db.execute(
                sql: "UPDATE gate_receipts SET consumed_at = ? WHERE cycle_id = ? AND consumed_at IS NULL",
                arguments: [timestamp, cycleId]
            )
            guard db.changesCount == 1 else {
                throw ImprovementStoreError.receiptNotConsumable
            }
            try Self.upsertState(db, state)
        }
    }

    private static func upsertState(_ db: GRDB.Database, _ state: ImprovementState) throws {
            if let id = state.id {
                try db.execute(
                    sql: """
                        UPDATE improvement_state SET
                            cycle_state = ?, last_cycle_at = ?, completed_cycles = ?,
                            user_approved_cycles = ?, current_adapter_path = ?,
                            previous_adapter_path = ?, training_started_at = ?,
                            last_cycle_error = ?, deferral_count = ?,
                            previous_directive = ?,
                            meta_opt_kept_total = ?, meta_opt_tested_total = ?,
                            meta_opt_last_run_at = ?, meta_opt_consecutive_no_improvement = ?,
                            pending_adapter_path = ?, pending_adapter_kind = ?, pending_cycle_id = ?
                        WHERE id = ?
                    """,
                    arguments: [
                        state.cycleState, state.lastCycleAt,
                        state.completedCycles, state.userApprovedCycles,
                        state.currentAdapterPath, state.previousAdapterPath,
                        state.trainingStartedAt, state.lastCycleError,
                        state.deferralCount, state.previousDirective,
                        state.metaOptKeptTotal, state.metaOptTestedTotal,
                        state.metaOptLastRunAt, state.metaOptConsecutiveNoImprovement,
                        state.pendingAdapterPath, state.pendingAdapterKind, state.pendingCycleId,
                        id,
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO improvement_state
                            (cycle_state, last_cycle_at, completed_cycles,
                             user_approved_cycles, current_adapter_path,
                             previous_adapter_path, training_started_at, last_cycle_error,
                             deferral_count, previous_directive,
                             meta_opt_kept_total, meta_opt_tested_total,
                             meta_opt_last_run_at, meta_opt_consecutive_no_improvement,
                             pending_adapter_path, pending_adapter_kind, pending_cycle_id)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        state.cycleState, state.lastCycleAt,
                        state.completedCycles, state.userApprovedCycles,
                        state.currentAdapterPath, state.previousAdapterPath,
                        state.trainingStartedAt, state.lastCycleError,
                        state.deferralCount, state.previousDirective,
                        state.metaOptKeptTotal, state.metaOptTestedTotal,
                        state.metaOptLastRunAt, state.metaOptConsecutiveNoImprovement,
                        state.pendingAdapterPath, state.pendingAdapterKind, state.pendingCycleId,
                    ]
                )
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

    // MARK: - MetaOptimization CRUD

    /// Insert a meta-optimization result into the log.
    func insertMetaOptResult(
        cycleNumber: Int,
        hypothesisId: String,
        surface: String,
        description: String,
        targetDimension: String,
        beforeScores: String,
        afterScores: String,
        delta: String,
        kept: Bool,
        reason: String,
        createdAt: String
    ) throws {
        guard let db else { throw ImprovementStoreError.notOpen }
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meta_optimization_log
                        (cycle_number, hypothesis_id, surface, description,
                         target_dimension, before_scores, after_scores, delta,
                         kept, reason, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cycleNumber, hypothesisId, surface, description,
                    targetDimension, beforeScores, afterScores, delta,
                    kept ? 1 : 0, reason, createdAt,
                ]
            )
        }
    }

    /// Fetch the most recent meta-optimization results for morning briefing or analysis.
    ///
    /// - Parameter limit: Maximum number of results to return.
    /// - Returns: Recent results ordered newest-first.
    func recentMetaOptResults(limit: Int = 20) throws -> [[String: Any]] {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT cycle_number, hypothesis_id, surface, description,
                       target_dimension, before_scores, after_scores, delta,
                       kept, reason, created_at
                FROM meta_optimization_log
                ORDER BY created_at DESC
                LIMIT \(limit)
            """)
            return rows.map { row in
                [
                    "cycle_number": row["cycle_number"] as Any,
                    "surface": row["surface"] as Any,
                    "description": row["description"] as Any,
                    "kept": (row["kept"] as? Int64 ?? 0) != 0,
                    "reason": row["reason"] as Any,
                    "delta": row["delta"] as Any,
                    "created_at": row["created_at"] as Any,
                ]
            }
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
            deferralCount: Int(row["deferral_count"] as? Int64 ?? 0),
            previousDirective: row["previous_directive"],
            metaOptKeptTotal: Int(row["meta_opt_kept_total"] as? Int64 ?? 0),
            metaOptTestedTotal: Int(row["meta_opt_tested_total"] as? Int64 ?? 0),
            metaOptLastRunAt: row["meta_opt_last_run_at"],
            metaOptConsecutiveNoImprovement: Int(row["meta_opt_consecutive_no_improvement"] as? Int64 ?? 0),
            pendingAdapterPath: row["pending_adapter_path"],
            pendingAdapterKind: row["pending_adapter_kind"],
            pendingCycleId: row["pending_cycle_id"]
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

    // MARK: - Gate Receipts (P9/C4 W2)

    /// Persist a minted gate receipt (one per cycle). Replaces any prior receipt for the
    /// same cycle id. Failures surface (Rule 12) — a swallowed receipt write followed by
    /// a deploy that requires a receipt must not silently mis-gate.
    func insertGateReceipt(_ receipt: GateReceipt) throws {
        guard let db else { throw ImprovementStoreError.notOpen }
        let measuredJSON = String(
            data: try JSONEncoder().encode(receipt.measured), encoding: .utf8
        ) ?? "{}"
        try db.write { db in
            // Plain INSERT (not OR REPLACE): re-inserting a cycle id is a programming
            // error and must fail loudly rather than silently reset `consumed_at` and
            // un-consume a spent receipt.
            try db.execute(
                sql: """
                    INSERT INTO gate_receipts
                        (cycle_id, candidate_path, kind, artifact_digest, measured_json,
                         decision, evaluator_id, base_model_id, eval_suite_version,
                         gate_policy_version, receipt_version, minted_at, hmac, consumed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                arguments: [
                    receipt.cycleId, receipt.candidatePath, receipt.kind.rawValue,
                    receipt.artifactDigest, measuredJSON, receipt.decision,
                    receipt.evaluatorId, receipt.baseModelId, receipt.evalSuiteVersion,
                    receipt.gatePolicyVersion, receipt.receiptVersion,
                    receipt.mintedAt, receipt.hmac,
                ]
            )
        }
    }

    /// Fetch the gate receipt for a cycle, if present.
    func gateReceipt(forCycleId cycleId: String) throws -> GateReceipt? {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM gate_receipts WHERE cycle_id = ? LIMIT 1",
                arguments: [cycleId]
            ) else { return nil }
            return Self.gateReceipt(from: row)
        }
    }

    /// Whether ANY consumed gate receipt exists for a given candidate/adapter path
    /// (P9/C4 W5). Used by recovery to tell a genuinely-deployed `currentAdapterPath`
    /// (which always has a consumed receipt from its deploy) apart from a pre-P9 un-gated
    /// candidate (which has none).
    func hasConsumedReceipt(forCandidatePath path: String) throws -> Bool {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM gate_receipts WHERE candidate_path = ? AND consumed_at IS NOT NULL",
                arguments: [path]
            ) ?? 0
            return count > 0
        }
    }

    /// Fetch the most-recently-minted CONSUMED gate receipt for a candidate/adapter path
    /// (P9/C4 F6). A genuinely-deployed `currentAdapterPath` always has a consumed receipt
    /// from its deploy; startup adapter-replay re-verifies THAT receipt against the on-disk
    /// artifact before re-applying it, so an edited/moved artifact is caught and the pointer
    /// is cleared rather than served un-gated.
    func consumedGateReceipt(forCandidatePath path: String) throws -> GateReceipt? {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM gate_receipts
                    WHERE candidate_path = ? AND consumed_at IS NOT NULL
                    ORDER BY minted_at DESC LIMIT 1
                """,
                arguments: [path]
            ) else { return nil }
            return Self.gateReceipt(from: row)
        }
    }

    /// Whether the receipt for a cycle has already been consumed (single-use gate).
    func isGateReceiptConsumed(cycleId: String) throws -> Bool {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT consumed_at FROM gate_receipts WHERE cycle_id = ? LIMIT 1",
                arguments: [cycleId]
            ) else { return false }
            let consumed: String? = row["consumed_at"]
            return consumed != nil
        }
    }

    /// Mark a receipt consumed (single-use). Sets `consumed_at` only if still null, so a
    /// replayed deploy of the same receipt cannot re-consume it.
    func consumeGateReceipt(cycleId: String, at timestamp: String) throws {
        guard let db else { throw ImprovementStoreError.notOpen }
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE gate_receipts SET consumed_at = ?
                    WHERE cycle_id = ? AND consumed_at IS NULL
                """,
                arguments: [timestamp, cycleId]
            )
        }
    }

    private static func gateReceipt(from row: Row) -> GateReceipt? {
        let measuredJSON: String = row["measured_json"] ?? "{}"
        let decoded = try? JSONDecoder().decode([String: Double].self, from: Data(measuredJSON.utf8))
        if decoded == nil {
            // Surface (don't silently swallow) a corrupt measured payload — the receipt's
            // HMAC will fail verification anyway, but a logged decode failure flags DB damage.
            NSLog("ImprovementStore: gate_receipts.measured_json failed to decode (db damage?)")
        }
        let measured = decoded ?? [:]
        guard let kindRaw: String = row["kind"], let kind = AdapterKind(rawValue: kindRaw) else {
            return nil
        }
        return GateReceipt(
            cycleId: row["cycle_id"] ?? "",
            candidatePath: row["candidate_path"] ?? "",
            kind: kind,
            artifactDigest: row["artifact_digest"] ?? "",
            measured: measured,
            decision: row["decision"] ?? "",
            evaluatorId: row["evaluator_id"] ?? "",
            baseModelId: row["base_model_id"] ?? "",
            evalSuiteVersion: row["eval_suite_version"] ?? "",
            gatePolicyVersion: Int(row["gate_policy_version"] as? Int64 ?? 0),
            receiptVersion: Int(row["receipt_version"] as? Int64 ?? 0),
            mintedAt: row["minted_at"] ?? "",
            hmac: row["hmac"] ?? ""
        )
    }

    // MARK: - Meta-Opt Rollback Journal (F14)

    /// One pending rollback-journal entry for a DISK-persisting meta-opt surface.
    struct MetaOptRollbackEntry: Sendable, Equatable {
        let id: Int64
        /// `MetaOptSurface.rawValue` — only `directive` or `configKnob` are journaled.
        let surface: String
        /// The config key (for `configKnob`); `nil` for `directive`.
        let configKey: String?
        /// The value to restore on rollback (prior directive text, or prior config value).
        let oldValue: String
        let description: String
        let appliedAt: String
    }

    /// Write a rollback-journal row BEFORE a disk-persisting change is applied. Returns the
    /// row id so the caller can delete it after a confirmed rollback or keep.
    func insertRollbackJournalEntry(
        surface: String, configKey: String?, oldValue: String, description: String
    ) throws -> Int64 {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meta_opt_rollback_journal
                        (surface, config_key, old_value, description, applied_at)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    surface, configKey, oldValue, description,
                    ISO8601DateFormatter().string(from: Date()),
                ]
            )
            return db.lastInsertedRowID
        }
    }

    /// Delete a journal row after its change was confirmed rolled back OR confirmed kept.
    func deleteRollbackJournalEntry(id: Int64) throws {
        guard let db else { throw ImprovementStoreError.notOpen }
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM meta_opt_rollback_journal WHERE id = ?", arguments: [id])
        }
    }

    /// All unresolved journal rows (oldest first) — replayed as rollbacks at startup to
    /// undo changes orphaned by a crash mid-benchmark.
    func pendingRollbackJournalEntries() throws -> [MetaOptRollbackEntry] {
        guard let db else { throw ImprovementStoreError.notOpen }
        return try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM meta_opt_rollback_journal ORDER BY id ASC"
            ).compactMap { row in
                guard let id = row["id"] as? Int64,
                      let surface: String = row["surface"],
                      let oldValue: String = row["old_value"],
                      let description: String = row["description"],
                      let appliedAt: String = row["applied_at"]
                else { return nil }
                return MetaOptRollbackEntry(
                    id: id, surface: surface, configKey: row["config_key"],
                    oldValue: oldValue, description: description, appliedAt: appliedAt)
            }
        }
    }
}

import Foundation
import GRDB

/// GRDB-backed SQLite persistence for scheduler state.
///
/// Stores task run records (idempotency, retries, history) and
/// task enabled/disabled state. Separate from `fae.db` to avoid
/// coupling with the memory store.
///
/// Path: `~/Library/Application Support/fae/scheduler.db`
actor SchedulerPersistenceStore {
    private let dbQueue: DatabaseQueue

    /// Open or create the scheduler database at the given path.
    init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try dbQueue.write { db in
            try Self.applySchema(db)
        }

        NSLog("SchedulerPersistenceStore: opened at %@", path)
    }

    // MARK: - Schema

    private static func applySchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS task_runs (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id         TEXT NOT NULL,
                idempotency_key TEXT NOT NULL UNIQUE,
                state           TEXT NOT NULL,
                attempt         INTEGER NOT NULL DEFAULT 0,
                updated_at      REAL NOT NULL,
                last_error      TEXT
            )
            """)
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_task_runs_task_id ON task_runs(task_id)"
        )

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS scheduler_state (
                task_id    TEXT PRIMARY KEY,
                enabled    INTEGER NOT NULL DEFAULT 1,
                updated_at REAL NOT NULL
            )
            """)
    }

    // MARK: - Task Runs

    /// Check whether an idempotency key has already been recorded.
    func hasSeenKey(_ key: String) throws -> Bool {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM task_runs WHERE idempotency_key = ? LIMIT 1",
                arguments: [key]
            )
            return row != nil
        }
    }

    /// Insert a new task run record. Silently ignores duplicate idempotency keys.
    func insertRun(_ record: TaskRunRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO task_runs
                        (task_id, idempotency_key, state, attempt, updated_at, last_error)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.taskID,
                    record.idempotencyKey,
                    record.state.rawValue,
                    record.attempt,
                    record.updatedAt.timeIntervalSince1970,
                    record.lastError,
                ]
            )
        }
    }

    /// Update the state (and optionally error) of an existing run by idempotency key.
    func updateRunState(idempotencyKey: String, state: TaskRunState, error: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE task_runs
                    SET state = ?, last_error = ?, updated_at = ?
                    WHERE idempotency_key = ?
                    """,
                arguments: [
                    state.rawValue,
                    error,
                    Date().timeIntervalSince1970,
                    idempotencyKey,
                ]
            )
        }
    }

    /// Return the most recent run record for a task, or nil.
    func latestRun(taskID: String) throws -> TaskRunRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT task_id, idempotency_key, state, attempt, updated_at, last_error
                    FROM task_runs
                    WHERE task_id = ?
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [taskID]
            ) else { return nil }
            return Self.recordFromRow(row)
        }
    }

    /// Return recent run records for a task, ordered by most recent first.
    func recentRuns(taskID: String, limit: Int = 20) throws -> [TaskRunRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT task_id, idempotency_key, state, attempt, updated_at, last_error
                    FROM task_runs
                    WHERE task_id = ?
                    ORDER BY updated_at DESC
                    LIMIT ?
                    """,
                arguments: [taskID, limit]
            )
            return rows.map { Self.recordFromRow($0) }
        }
    }

    /// Delete runs older than the given date. Returns the number of deleted rows.
    @discardableResult
    func pruneOldRuns(olderThan date: Date) throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM task_runs WHERE updated_at < ?",
                arguments: [date.timeIntervalSince1970]
            )
            return db.changesCount
        }
    }

    /// Return timestamps of successful runs for a task, most recent first.
    func runHistory(taskID: String, limit: Int = 20) throws -> [Date] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT updated_at FROM task_runs
                    WHERE task_id = ? AND state = ?
                    ORDER BY updated_at DESC
                    LIMIT ?
                    """,
                arguments: [taskID, TaskRunState.success.rawValue, limit]
            )
            return rows.map { Date(timeIntervalSince1970: $0["updated_at"]) }
        }
    }

    // MARK: - Task Enabled/Disabled State

    /// Load all task IDs that are currently disabled.
    func loadDisabledTaskIDs() throws -> Set<String> {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT task_id FROM scheduler_state WHERE enabled = 0"
            )
            return Set(rows.map { $0["task_id"] as String })
        }
    }

    /// Set a task's enabled/disabled state (INSERT OR REPLACE).
    func setTaskEnabled(id: String, enabled: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO scheduler_state (task_id, enabled, updated_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [id, enabled ? 1 : 0, Date().timeIntervalSince1970]
            )
        }
    }

    // MARK: - Row Mapping

    private static func recordFromRow(_ row: Row) -> TaskRunRecord {
        TaskRunRecord(
            taskID: row["task_id"],
            idempotencyKey: row["idempotency_key"],
            state: TaskRunState(rawValue: row["state"]) ?? .idle,
            attempt: row["attempt"],
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            lastError: row["last_error"]
        )
    }
}

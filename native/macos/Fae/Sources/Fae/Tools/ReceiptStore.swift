import Foundation
import GRDB

// MARK: - ActionReversibility

/// Characterizes whether a tool invocation can be undone.
///
/// The receipts engine uses this to decide whether to capture a pre-state
/// blob and whether to offer an undo operation after execution.
enum ActionReversibility: String, Codable, Sendable {
    /// The action mutated state that can be restored from the pre-state blob
    /// (e.g. a file overwrite, a calendar event deletion, a note update).
    case reversible

    /// The action caused side-effects that cannot be undone by Fae
    /// (e.g. sending an email, running an arbitrary bash command).
    case irreversible

    /// The action is read-only and leaves no persistent state to undo
    /// (e.g. reading a file, taking a screenshot, searching the web).
    case notApplicable

    // MARK: - Classification

    /// Classify a tool invocation by name and arguments.
    ///
    /// For `bash`, delegates to `BashReversibilityClassifier` using the
    /// `command` argument.
    static func classify(toolName: String, arguments: [String: Any]) -> ActionReversibility {
        switch toolName {

        // ── Read-only tools ───────────────────────────────────────────
        case "read",
             "session_search",
             "web_search",
             "fetch_url",
             "screenshot",
             "camera",
             "read_screen",
             "find_element",
             "input_request",
             "activate_skill",
             "window_control",
             "roleplay",
             "till_done":
            return .notApplicable

        // ── Voice identity: read-only for most actions ─────────────────
        case "voice_identity":
            let action = arguments["action"] as? String ?? ""
            if action == "enroll" || action == "delete" || action == "update" {
                return .reversible
            }
            return .notApplicable

        // ── File write tools ──────────────────────────────────────────
        case "write", "edit":
            return .reversible

        // ── Self-config: mutates config.toml ──────────────────────────
        case "self_config":
            let op = arguments["operation"] as? String ?? ""
            if op == "get" || op == "get_directive" {
                return .notApplicable
            }
            return .reversible

        // ── Channel setup: mutates config ─────────────────────────────
        case "channel_setup":
            return .reversible

        // ── Scheduler tools ───────────────────────────────────────────
        case "scheduler_list":
            return .notApplicable
        case "scheduler_create", "scheduler_update", "scheduler_delete", "scheduler_trigger":
            return .reversible

        // ── Skill management ──────────────────────────────────────────
        case "manage_skill":
            let action = arguments["action"] as? String ?? ""
            if action == "list" || action == "info" || action == "status" {
                return .notApplicable
            }
            return .reversible

        case "run_skill":
            return .irreversible

        case "plugin_manage":
            let action = arguments["action"] as? String ?? ""
            if action == "list" || action == "status" {
                return .notApplicable
            }
            return .reversible

        // ── Apple framework tools ────────────────────────────────────
        case "calendar":
            let action = arguments["action"] as? String ?? ""
            if action == "list" || action == "get" || action == "search" {
                return .notApplicable
            }
            return .reversible

        case "reminders":
            let action = arguments["action"] as? String ?? ""
            if action == "list" || action == "get" || action == "search" {
                return .notApplicable
            }
            return .reversible

        case "contacts":
            let action = arguments["action"] as? String ?? ""
            if action == "search" || action == "get" || action == "list" {
                return .notApplicable
            }
            return .reversible

        case "notes":
            let action = arguments["action"] as? String ?? ""
            if action == "list" || action == "get" || action == "search" {
                return .notApplicable
            }
            return .reversible

        // ── Mail: sending is irreversible ────────────────────────────
        case "mail":
            let action = arguments["action"] as? String ?? ""
            if action == "list" || action == "get" || action == "search" || action == "read" {
                return .notApplicable
            }
            return .irreversible

        // ── Computer use: UI interactions are irreversible ──────────
        case "click", "type_text", "scroll":
            return .irreversible

        // ── Delegation: side-effects in external agents ──────────────
        case "delegate_agent", "agent_session":
            return .irreversible

        // ── Bash: per-command classification ─────────────────────────
        case "bash":
            let command = arguments["command"] as? String ?? ""
            return BashReversibilityClassifier.classify(command: command)

        default:
            return .irreversible
        }
    }
}

// MARK: - BashReversibilityClassifier

/// Classifies a bash command string as reversible or irreversible.
///
/// Only a narrow allowlist of commands is considered reversible because
/// Fae can snapshot the file before executing them:
///
/// - `echo ... > file` / `echo ... >> file` — file write/append
/// - `cp src dst` — file copy (dst may be overwritten)
/// - `mv src dst` — file rename/move
/// - `mkdir path` — directory creation (can be removed)
/// - `touch path` — file creation/timestamp update
///
/// Everything else is `.irreversible`.
enum BashReversibilityClassifier {

    /// Classify a bash command string.
    static func classify(command: String) -> ActionReversibility {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // Multi-command pipelines / chained commands are irreversible.
        if trimmed.contains("|") || trimmed.contains("&&") || trimmed.contains(";") {
            return .irreversible
        }

        for prefix in reversiblePrefixes {
            if trimmed.hasPrefix(prefix) {
                return .reversible
            }
        }

        return .irreversible
    }

    private static let reversiblePrefixes: [String] = [
        "echo ",
        "cp ",
        "mv ",
        "mkdir ",
        "touch ",
    ]
}

// MARK: - ActionReceiptRecord

/// A single persisted receipt row in `action_receipts`.
struct ActionReceiptRecord: Codable, Sendable {
    let id: String
    let createdAt: Int
    let toolName: String
    let argumentsJSON: String
    let reversibility: String
    let preStateBlob: Data?
    let preStatePath: String?
    let speakerId: String?
    let sessionId: String?
    let turnId: String?
    var undoneAt: Int?
    var undoError: String?
}

// MARK: - ReceiptStoreError

/// Errors returned by `ReceiptStore` undo operations.
enum ReceiptStoreError: Error, Sendable {
    case receiptNotFound
    case alreadyUndone
    case notReversible
    case noPreState
    case restoreFailed(String)
    case databaseError(String)
}

// MARK: - ReceiptStore

/// SQLite-backed actor that stores action receipts for the undo/reversibility system.
///
/// Uses a **separate** database file (`receipts.db`) so that receipt failures
/// are isolated from the main memory database (`fae.db`).
///
/// All database operations use GRDB's synchronous API (matching the pattern
/// established by `SQLiteMemoryStore`). Actor isolation provides thread safety.
///
/// Wiring:
/// - `ToolExecutor` calls `createReceipt()` after every successful write-tool execution.
/// - `FaeScheduler` calls `pruneExpired()` from `memory_gc` (daily at 03:30).
/// - `GitVaultManager` includes `receipts.db` in the daily vault backup.
actor ReceiptStore {

    // MARK: - Constants

    /// Pre-state blobs larger than this are not captured (receipt still created).
    static let maxPreStateBlobBytes = 50 * 1024 * 1024  // 50 MB

    /// Maximum rows retained before oldest are pruned during GC.
    static let maxRetainedReceipts = 10_000

    /// Receipts older than this are eligible for GC (if already undone).
    static let retentionDays = 7

    // MARK: - Storage

    private let dbQueue: DatabaseQueue

    // MARK: - Init

    /// Open or create the receipts database at the given path.
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

        NSLog("ReceiptStore: opened at %@", path)
    }

    // MARK: - Schema

    private static func applySchema(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS action_receipts (
                id              TEXT PRIMARY KEY,
                created_at      INTEGER NOT NULL,
                tool_name       TEXT NOT NULL,
                arguments_json  TEXT NOT NULL DEFAULT '{}',
                reversibility   TEXT NOT NULL,
                pre_state_blob  BLOB,
                pre_state_path  TEXT,
                speaker_id      TEXT,
                session_id      TEXT,
                turn_id         TEXT,
                undone_at       INTEGER,
                undo_error      TEXT
            )
            """)

        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_receipts_created_at
            ON action_receipts (created_at DESC)
            """)

        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_receipts_undone_at
            ON action_receipts (undone_at)
            """)

        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_receipts_speaker_id
            ON action_receipts (speaker_id, created_at DESC)
            """)
    }

    // MARK: - Pre-State Capture (call BEFORE tool execution)

    /// Capture the pre-execution state for a tool invocation.
    ///
    /// **Must be called BEFORE executing the tool** so the file snapshot reflects
    /// the original content, not the post-mutation content.  Returns `nil` when
    /// pre-state capture is not applicable (read-only or irreversible tools).
    ///
    /// Pass the returned value directly to `createReceipt(preState:...)`.
    nonisolated func capturePreStateForTool(
        toolName: String,
        arguments: [String: Any]
    ) -> PreStateCaptureResult? {
        let reversibility = ActionReversibility.classify(toolName: toolName, arguments: arguments)
        guard reversibility == .reversible else { return nil }
        return capturePreState(toolName: toolName, arguments: arguments)
    }

    // MARK: - Create

    /// Persist a receipt row using a pre-state snapshot captured BEFORE execution.
    ///
    /// - Parameter preState: Result from `capturePreStateForTool(_:arguments:)`,
    ///   called before the tool executed. Pass `nil` for tools that do not support undo.
    ///
    /// Returns the new receipt ID, or `nil` if the operation failed.
    /// Designed to be called fire-and-forget — never throws.
    @discardableResult
    func createReceipt(
        toolName: String,
        arguments: [String: Any],
        preState: PreStateCaptureResult?,
        speakerId: String?,
        sessionId: String?,
        turnId: String?
    ) -> String? {
        let id = UUID().uuidString
        let reversibility = ActionReversibility.classify(toolName: toolName, arguments: arguments)

        let argumentsJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: arguments),
           let str = String(data: data, encoding: .utf8) {
            argumentsJSON = str
        } else {
            argumentsJSON = "{}"
        }

        // Use the externally-captured pre-state (taken before tool execution).
        // Do NOT re-capture here — the file has already been mutated.
        let preStateBlob = preState?.blob
        let preStatePath = preState?.path

        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO action_receipts
                            (id, created_at, tool_name, arguments_json, reversibility,
                             pre_state_blob, pre_state_path, speaker_id, session_id, turn_id,
                             undone_at, undo_error)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                        """,
                    arguments: [
                        id,
                        Int(Date().timeIntervalSince1970),
                        toolName,
                        argumentsJSON,
                        reversibility.rawValue,
                        preStateBlob,
                        preStatePath,
                        speakerId,
                        sessionId,
                        turnId,
                    ]
                )
            }
            return id
        } catch {
            NSLog("ReceiptStore: createReceipt failed for %@: %@", toolName, error.localizedDescription)
            return nil
        }
    }

    // MARK: - Undo

    /// Restore state from a previously created receipt.
    func undo(receiptId: String) -> Result<Void, ReceiptStoreError> {
        do {
            guard let row = try dbQueue.read({ db in
                try Row.fetchOne(db, sql: "SELECT * FROM action_receipts WHERE id = ?", arguments: [receiptId])
            }) else {
                return .failure(.receiptNotFound)
            }

            let undoneAt: Int? = row["undone_at"]
            if undoneAt != nil {
                return .failure(.alreadyUndone)
            }

            let reversibility = row["reversibility"] as? String ?? ""
            if reversibility != ActionReversibility.reversible.rawValue {
                return .failure(.notReversible)
            }

            let preStatePath = row["pre_state_path"] as? String
            let preStateBlob = row["pre_state_blob"] as? Data

            let restoreResult = performRestore(preStatePath: preStatePath, preStateBlob: preStateBlob)
            if case .failure(let err) = restoreResult {
                try? dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE action_receipts SET undo_error = ? WHERE id = ?",
                        arguments: [err.localizedDescription, receiptId]
                    )
                }
                return .failure(err)
            }

            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE action_receipts SET undone_at = ? WHERE id = ?",
                    arguments: [Int(Date().timeIntervalSince1970), receiptId]
                )
            }
            return .success(())

        } catch {
            return .failure(.databaseError(error.localizedDescription))
        }
    }

    // MARK: - Batch Undo

    /// Undo all reversible receipts created after `since`, in reverse chronological order.
    ///
    /// Returns `(succeeded, failed)` counts. Individual failures do not stop the batch.
    func batchUndo(since: Date) -> (succeeded: Int, failed: Int) {
        let cutoff = Int(since.timeIntervalSince1970)

        do {
            let receiptIds = try dbQueue.read { db -> [String] in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id FROM action_receipts
                        WHERE created_at >= ?
                          AND undone_at IS NULL
                          AND reversibility = ?
                        ORDER BY created_at DESC
                        """,
                    arguments: [cutoff, ActionReversibility.reversible.rawValue]
                )
                return rows.compactMap { $0["id"] as? String }
            }

            var succeeded = 0
            var failed = 0

            for receiptId in receiptIds {
                switch undo(receiptId: receiptId) {
                case .success:
                    succeeded += 1
                case .failure:
                    failed += 1
                }
            }

            return (succeeded, failed)
        } catch {
            NSLog("ReceiptStore: batchUndo query failed: %@", error.localizedDescription)
            return (0, 0)
        }
    }

    // MARK: - GC

    /// Prune expired receipts to keep the database lean.
    ///
    /// Deletion criteria:
    /// 1. Receipts already undone that are older than `retentionDays`.
    /// 2. Oldest excess rows when the total exceeds `maxRetainedReceipts`.
    ///
    /// Returns the number of rows pruned.
    @discardableResult
    func pruneExpired() -> Int {
        var pruned = 0

        do {
            let cutoff = Int(Date().addingTimeInterval(-Double(Self.retentionDays) * 86400).timeIntervalSince1970)

            try dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM action_receipts WHERE undone_at IS NOT NULL AND created_at < ?",
                    arguments: [cutoff]
                )
                pruned += db.changesCount
            }

            let count = try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM action_receipts") ?? 0
            }

            if count > Self.maxRetainedReceipts {
                let excess = count - Self.maxRetainedReceipts
                try dbQueue.write { db in
                    try db.execute(
                        sql: """
                            DELETE FROM action_receipts
                            WHERE id IN (
                                SELECT id FROM action_receipts
                                ORDER BY created_at ASC
                                LIMIT ?
                            )
                            """,
                        arguments: [excess]
                    )
                    pruned += db.changesCount
                }
            }
        } catch {
            NSLog("ReceiptStore: pruneExpired failed: %@", error.localizedDescription)
        }

        if pruned > 0 {
            NSLog("ReceiptStore: pruned %d expired receipts", pruned)
        }

        return pruned
    }

    // MARK: - Query Helpers

    /// Fetch recent receipts, newest first.
    func recentReceipts(speakerId: String?, limit: Int = 20) -> [ActionReceiptRecord] {
        do {
            let rows = try dbQueue.read { db -> [Row] in
                if let sid = speakerId {
                    return try Row.fetchAll(
                        db,
                        sql: """
                            SELECT * FROM action_receipts
                            WHERE speaker_id = ?
                            ORDER BY created_at DESC
                            LIMIT ?
                            """,
                        arguments: [sid, limit]
                    )
                } else {
                    return try Row.fetchAll(
                        db,
                        sql: """
                            SELECT * FROM action_receipts
                            ORDER BY created_at DESC
                            LIMIT ?
                            """,
                        arguments: [limit]
                    )
                }
            }
            return rows.compactMap { Self.record(from: $0) }
        } catch {
            NSLog("ReceiptStore: recentReceipts query failed: %@", error.localizedDescription)
            return []
        }
    }

    // MARK: - Private Helpers

    struct PreStateCaptureResult {
        let blob: Data?
        let path: String?
    }

    nonisolated private func capturePreState(
        toolName: String,
        arguments: [String: Any]
    ) -> PreStateCaptureResult {
        switch toolName {
        case "write", "edit":
            guard let path = arguments["path"] as? String else {
                return PreStateCaptureResult(blob: nil, path: nil)
            }
            return captureFilePreState(atPath: path)

        case "bash":
            let command = arguments["command"] as? String ?? ""
            if let path = extractBashOutputPath(command: command) {
                return captureFilePreState(atPath: path)
            }
            return PreStateCaptureResult(blob: nil, path: nil)

        case "self_config", "channel_setup":
            let configPath = FaeDirectories.configFile.path
            return captureFilePreState(atPath: configPath)

        default:
            return PreStateCaptureResult(blob: nil, path: nil)
        }
    }

    nonisolated private func captureFilePreState(atPath path: String) -> PreStateCaptureResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return PreStateCaptureResult(blob: nil, path: path)
        }

        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else {
            return PreStateCaptureResult(blob: nil, path: path)
        }

        if size > Self.maxPreStateBlobBytes {
            NSLog("ReceiptStore: pre-state blob skipped for %@ (size %d > 50MB cap)", path, size)
            return PreStateCaptureResult(blob: nil, path: path)
        }

        let blob = try? Data(contentsOf: URL(fileURLWithPath: path))
        return PreStateCaptureResult(blob: blob, path: path)
    }

    nonisolated private func extractBashOutputPath(command: String) -> String? {
        let patterns = [#"\s>>\s*(\S+)\s*$"#, #"\s>\s*(\S+)\s*$"#]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
               let range = Range(match.range(at: 1), in: command) {
                let path = String(command[range])
                return path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    private func performRestore(
        preStatePath: String?,
        preStateBlob: Data?
    ) -> Result<Void, ReceiptStoreError> {
        guard let path = preStatePath else {
            return .failure(.noPreState)
        }

        let fm = FileManager.default

        if let blob = preStateBlob {
            do {
                // Ensure the parent directory exists (it may have been deleted).
                let parentDir = (path as NSString).deletingLastPathComponent
                try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                // Atomic write prevents partial content on power failure.
                try blob.write(to: URL(fileURLWithPath: path), options: .atomic)
                return .success(())
            } catch {
                return .failure(.restoreFailed(error.localizedDescription))
            }
        } else {
            if fm.fileExists(atPath: path) {
                do {
                    try fm.removeItem(atPath: path)
                    return .success(())
                } catch {
                    return .failure(.restoreFailed(error.localizedDescription))
                }
            }
            return .success(())
        }
    }

    private static func record(from row: Row) -> ActionReceiptRecord? {
        guard let id = row["id"] as? String,
              let toolName = row["tool_name"] as? String,
              let argumentsJSON = row["arguments_json"] as? String,
              let reversibility = row["reversibility"] as? String
        else { return nil }

        // SQLite INTEGER columns are decoded as Int64 by GRDB.
        // Use Int64 first, then bridge to Int.
        let createdAt: Int
        if let v64 = row["created_at"] as? Int64 {
            createdAt = Int(v64)
        } else if let vInt = row["created_at"] as? Int {
            createdAt = vInt
        } else {
            return nil
        }

        let undoneAt: Int?
        if let v64 = row["undone_at"] as? Int64 {
            undoneAt = Int(v64)
        } else {
            undoneAt = row["undone_at"] as? Int
        }

        return ActionReceiptRecord(
            id: id,
            createdAt: createdAt,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            reversibility: reversibility,
            preStateBlob: row["pre_state_blob"] as? Data,
            preStatePath: row["pre_state_path"] as? String,
            speakerId: row["speaker_id"] as? String,
            sessionId: row["session_id"] as? String,
            turnId: row["turn_id"] as? String,
            undoneAt: undoneAt,
            undoError: row["undo_error"] as? String
        )
    }
}

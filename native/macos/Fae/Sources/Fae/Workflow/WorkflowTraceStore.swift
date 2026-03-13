import Foundation
import GRDB

enum WorkflowRunStatus: String, Sendable {
    case open
    case completed
    case abandoned
}

enum WorkflowStepType: String, Sendable {
    case toolCall = "tool_call"
    case toolResult = "tool_result"
}

enum SkillDraftCandidateStatus: String, Sendable {
    case pending
    case dismissed
    case applied
}

enum SkillDraftAction: String, Sendable {
    case create
    case update
}

struct WorkflowRunRecord: Sendable, Equatable {
    let id: String
    let sessionId: String?
    let turnId: String?
    let source: String
    let userGoal: String
    let assistantOutcome: String?
    let toolSequenceSignature: String?
    let stepCount: Int
    let success: Bool
    let userApproved: Bool
    let damageControlIntervened: Bool
    let status: WorkflowRunStatus
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
}

struct WorkflowStepRecord: Sendable, Equatable {
    let id: String
    let runId: String
    let toolCallId: String?
    let stepIndex: Int
    let stepType: WorkflowStepType
    let toolName: String?
    let sanitizedInputJSON: String?
    let outputPreview: String?
    let success: Bool?
    let approved: Bool?
    let latencyMs: Int?
    let createdAt: Date
}

struct SkillDraftCandidateRecord: Sendable, Equatable {
    let id: String
    let workflowSignature: String
    let status: SkillDraftCandidateStatus
    let action: SkillDraftAction
    let targetSkillName: String
    let title: String
    let rationale: String
    let evidenceJSON: String?
    let draftSkillMD: String
    let draftManifestJSON: String?
    let draftScript: String?
    let confidence: Double
    let createdAt: Date
    let updatedAt: Date
}

actor WorkflowTraceStore {
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
            arguments: ["workflow.schema_version", "1"]
        )

        // NOTE: session_id references conversation_sessions which is created by SessionStore.
        // SessionStore must be initialised before WorkflowTraceStore on the same DatabaseQueue.
        // SQLite defers FK target validation so this will not fail at DDL time, but the FK
        // constraint only functions correctly when both tables exist in the same database.
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS workflow_runs (
                id                         TEXT PRIMARY KEY,
                session_id                 TEXT REFERENCES conversation_sessions(id) ON DELETE SET NULL,
                turn_id                    TEXT,
                source                     TEXT NOT NULL,
                user_goal                  TEXT NOT NULL,
                assistant_outcome          TEXT,
                tool_sequence_signature    TEXT,
                step_count                 INTEGER NOT NULL DEFAULT 0,
                success                    INTEGER NOT NULL DEFAULT 0,
                user_approved              INTEGER NOT NULL DEFAULT 0,
                damage_control_intervened  INTEGER NOT NULL DEFAULT 0,
                status                     TEXT NOT NULL DEFAULT 'open',
                created_at                 INTEGER NOT NULL,
                updated_at                 INTEGER NOT NULL,
                completed_at               INTEGER
            )
            """)
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_workflow_runs_turn_id ON workflow_runs(turn_id)"
        )
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_workflow_runs_created_at ON workflow_runs(created_at)"
        )
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_workflow_runs_signature ON workflow_runs(tool_sequence_signature)"
        )
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_workflow_runs_status ON workflow_runs(status)"
        )

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS workflow_steps (
                id                    TEXT PRIMARY KEY,
                run_id                TEXT NOT NULL REFERENCES workflow_runs(id) ON DELETE CASCADE,
                tool_call_id          TEXT,
                step_index            INTEGER NOT NULL,
                step_type             TEXT NOT NULL,
                tool_name             TEXT,
                sanitized_input_json  TEXT,
                output_preview        TEXT,
                success               INTEGER,
                approved              INTEGER,
                latency_ms            INTEGER,
                created_at            INTEGER NOT NULL
            )
            """)
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_workflow_steps_run_id ON workflow_steps(run_id)"
        )
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_workflow_steps_tool_call_id ON workflow_steps(tool_call_id)"
        )
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_workflow_steps_created_at ON workflow_steps(created_at)"
        )

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS skill_draft_candidates (
                id                  TEXT PRIMARY KEY,
                workflow_signature  TEXT NOT NULL,
                status              TEXT NOT NULL,
                action              TEXT NOT NULL,
                target_skill_name   TEXT NOT NULL,
                title               TEXT NOT NULL,
                rationale           TEXT NOT NULL,
                evidence_json       TEXT,
                draft_skill_md      TEXT NOT NULL,
                draft_manifest_json TEXT,
                draft_script        TEXT,
                confidence          REAL NOT NULL DEFAULT 0,
                created_at          INTEGER NOT NULL,
                updated_at          INTEGER NOT NULL
            )
            """)
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_skill_draft_candidates_status ON skill_draft_candidates(status)"
        )
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_skill_draft_candidates_signature ON skill_draft_candidates(workflow_signature)"
        )
    }

    func createRun(
        sessionId: String?,
        turnId: String?,
        source: String,
        userGoal: String,
        createdAt: Date = Date()
    ) throws -> WorkflowRunRecord {
        let record = WorkflowRunRecord(
            id: Self.newID(prefix: "workflow_run"),
            sessionId: sessionId,
            turnId: turnId,
            source: source,
            userGoal: Self.redactedAndTrimmed(userGoal, limit: 1_200),
            assistantOutcome: nil,
            toolSequenceSignature: nil,
            stepCount: 0,
            success: false,
            userApproved: false,
            damageControlIntervened: false,
            status: .open,
            createdAt: createdAt,
            updatedAt: createdAt,
            completedAt: nil
        )

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO workflow_runs
                        (id, session_id, turn_id, source, user_goal, assistant_outcome, tool_sequence_signature,
                         step_count, success, user_approved, damage_control_intervened, status, created_at,
                         updated_at, completed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id,
                    record.sessionId,
                    record.turnId,
                    record.source,
                    record.userGoal,
                    record.assistantOutcome,
                    record.toolSequenceSignature,
                    record.stepCount,
                    record.success ? 1 : 0,
                    record.userApproved ? 1 : 0,
                    record.damageControlIntervened ? 1 : 0,
                    record.status.rawValue,
                    Self.unixTimestamp(record.createdAt),
                    Self.unixTimestamp(record.updatedAt),
                    nil,
                ]
            )
        }

        return record
    }

    @discardableResult
    func appendStep(
        runId: String,
        toolCallId: String?,
        stepType: WorkflowStepType,
        toolName: String?,
        sanitizedInputJSON: String?,
        outputPreview: String?,
        success: Bool?,
        approved: Bool?,
        latencyMs: Int?,
        createdAt: Date = Date()
    ) throws -> WorkflowStepRecord {
        try dbQueue.write { db in
            let nextIndex = (try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(step_index), -1) + 1 FROM workflow_steps WHERE run_id = ?",
                arguments: [runId]
            )) ?? 0

            let record = WorkflowStepRecord(
                id: Self.newID(prefix: "workflow_step"),
                runId: runId,
                toolCallId: toolCallId,
                stepIndex: nextIndex,
                stepType: stepType,
                toolName: toolName,
                sanitizedInputJSON: Self.optionalRedactedAndTrimmed(sanitizedInputJSON, limit: 3_000),
                outputPreview: Self.optionalRedactedAndTrimmed(outputPreview, limit: 1_200),
                success: success,
                approved: approved,
                latencyMs: latencyMs,
                createdAt: createdAt
            )

            try db.execute(
                sql: """
                    INSERT INTO workflow_steps
                        (id, run_id, tool_call_id, step_index, step_type, tool_name, sanitized_input_json,
                         output_preview, success, approved, latency_ms, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id,
                    record.runId,
                    record.toolCallId,
                    record.stepIndex,
                    record.stepType.rawValue,
                    record.toolName,
                    record.sanitizedInputJSON,
                    record.outputPreview,
                    Self.optionalInt(success),
                    Self.optionalInt(approved),
                    record.latencyMs,
                    Self.unixTimestamp(record.createdAt),
                ]
            )

            try db.execute(
                sql: """
                    UPDATE workflow_runs
                    SET step_count = step_count + 1, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [Self.unixTimestamp(createdAt), runId]
            )

            return record
        }
    }

    func finalizeRun(
        id: String,
        assistantOutcome: String?,
        success: Bool,
        userApproved: Bool,
        toolSequenceSignature: String?,
        damageControlIntervened: Bool,
        status: WorkflowRunStatus = .completed,
        completedAt: Date = Date()
    ) throws -> WorkflowRunRecord? {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE workflow_runs
                    SET assistant_outcome = ?, tool_sequence_signature = ?, success = ?, user_approved = ?,
                        damage_control_intervened = ?, status = ?, updated_at = ?, completed_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    Self.optionalRedactedAndTrimmed(assistantOutcome, limit: 1_400),
                    toolSequenceSignature,
                    success ? 1 : 0,
                    userApproved ? 1 : 0,
                    damageControlIntervened ? 1 : 0,
                    status.rawValue,
                    Self.unixTimestamp(completedAt),
                    Self.unixTimestamp(completedAt),
                    id,
                ]
            )

            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM workflow_runs WHERE id = ? LIMIT 1",
                arguments: [id]
            ) else {
                return nil
            }

            return Self.runRecord(from: row)
        }
    }

    func recentSuccessfulRuns(
        since: Date,
        minimumStepCount: Int,
        limit: Int = 200
    ) throws -> [WorkflowRunRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM workflow_runs
                    WHERE success = 1
                      AND status = 'completed'
                      AND step_count >= ?
                      AND completed_at >= ?
                      AND tool_sequence_signature IS NOT NULL
                      AND tool_sequence_signature != ''
                    ORDER BY completed_at DESC
                    LIMIT ?
                    """,
                arguments: [minimumStepCount, Self.unixTimestamp(since), limit]
            )
            return rows.map(Self.runRecord(from:))
        }
    }

    func steps(runId: String) throws -> [WorkflowStepRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM workflow_steps
                    WHERE run_id = ?
                    ORDER BY step_index ASC
                    """,
                arguments: [runId]
            )
            return rows.map(Self.stepRecord(from:))
        }
    }

    func hasActiveCandidate(forWorkflowSignature signature: String) throws -> Bool {
        try dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM skill_draft_candidates
                    WHERE workflow_signature = ?
                      AND status IN ('pending', 'applied')
                    """,
                arguments: [signature]
            ) ?? 0
            return count > 0
        }
    }

    func insertDraftCandidate(
        workflowSignature: String,
        action: SkillDraftAction,
        targetSkillName: String,
        title: String,
        rationale: String,
        evidenceJSON: String?,
        draftSkillMD: String,
        draftManifestJSON: String? = nil,
        draftScript: String? = nil,
        confidence: Double,
        createdAt: Date = Date()
    ) throws -> SkillDraftCandidateRecord {
        let record = SkillDraftCandidateRecord(
            id: Self.newID(prefix: "skill_draft"),
            workflowSignature: workflowSignature,
            status: .pending,
            action: action,
            targetSkillName: targetSkillName,
            title: Self.trimmed(title, limit: 200),
            rationale: Self.redactedAndTrimmed(rationale, limit: 1_500),
            evidenceJSON: Self.optionalRedactedAndTrimmed(evidenceJSON, limit: 8_000),
            draftSkillMD: Self.trimmed(draftSkillMD, limit: 20_000),
            draftManifestJSON: Self.optionalTrimmed(draftManifestJSON, limit: 10_000),
            draftScript: Self.optionalTrimmed(draftScript, limit: 20_000),
            confidence: min(max(confidence, 0), 1),
            createdAt: createdAt,
            updatedAt: createdAt
        )

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO skill_draft_candidates
                        (id, workflow_signature, status, action, target_skill_name, title, rationale,
                         evidence_json, draft_skill_md, draft_manifest_json, draft_script, confidence,
                         created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id,
                    record.workflowSignature,
                    record.status.rawValue,
                    record.action.rawValue,
                    record.targetSkillName,
                    record.title,
                    record.rationale,
                    record.evidenceJSON,
                    record.draftSkillMD,
                    record.draftManifestJSON,
                    record.draftScript,
                    record.confidence,
                    Self.unixTimestamp(record.createdAt),
                    Self.unixTimestamp(record.updatedAt),
                ]
            )
        }

        return record
    }

    func listDraftCandidates(
        statuses: [SkillDraftCandidateStatus]? = nil,
        limit: Int = 20
    ) throws -> [SkillDraftCandidateRecord] {
        try dbQueue.read { db in
            if let statuses, !statuses.isEmpty {
                let placeholders = statuses.map { _ in "?" }.joined(separator: ",")
                var arguments = StatementArguments()
                for value in statuses.map(\.rawValue) {
                    arguments += [value]
                }
                arguments += [limit]
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM skill_draft_candidates
                        WHERE status IN (\(placeholders))
                        ORDER BY updated_at DESC
                        LIMIT ?
                        """,
                    arguments: arguments
                )
                return rows.map(Self.candidateRecord(from:))
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM skill_draft_candidates
                    ORDER BY updated_at DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return rows.map(Self.candidateRecord(from:))
        }
    }

    func fetchDraftCandidate(id: String) throws -> SkillDraftCandidateRecord? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM skill_draft_candidates WHERE id = ? LIMIT 1",
                arguments: [id]
            )
            return row.map(Self.candidateRecord(from:))
        }
    }

    func updateDraftCandidateStatus(
        id: String,
        status: SkillDraftCandidateStatus,
        updatedAt: Date = Date()
    ) throws -> SkillDraftCandidateRecord? {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE skill_draft_candidates
                    SET status = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [status.rawValue, Self.unixTimestamp(updatedAt), id]
            )
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM skill_draft_candidates WHERE id = ? LIMIT 1",
                arguments: [id]
            ) else {
                return nil
            }
            return Self.candidateRecord(from: row)
        }
    }

    private static func runRecord(from row: Row) -> WorkflowRunRecord {
        WorkflowRunRecord(
            id: row["id"],
            sessionId: row["session_id"],
            turnId: row["turn_id"],
            source: row["source"],
            userGoal: row["user_goal"],
            assistantOutcome: row["assistant_outcome"],
            toolSequenceSignature: row["tool_sequence_signature"],
            stepCount: row["step_count"],
            success: (row["success"] as Int? ?? 0) != 0,
            userApproved: (row["user_approved"] as Int? ?? 0) != 0,
            damageControlIntervened: (row["damage_control_intervened"] as Int? ?? 0) != 0,
            status: WorkflowRunStatus(rawValue: row["status"] as String? ?? "") ?? .open,
            createdAt: Self.dateFromRow(row, column: "created_at") ?? Date.distantPast,
            updatedAt: Self.dateFromRow(row, column: "updated_at") ?? Date.distantPast,
            completedAt: Self.dateFromRow(row, column: "completed_at")
        )
    }

    private static func stepRecord(from row: Row) -> WorkflowStepRecord {
        WorkflowStepRecord(
            id: row["id"],
            runId: row["run_id"],
            toolCallId: row["tool_call_id"],
            stepIndex: row["step_index"],
            stepType: WorkflowStepType(rawValue: row["step_type"] as String? ?? "") ?? .toolResult,
            toolName: row["tool_name"],
            sanitizedInputJSON: row["sanitized_input_json"],
            outputPreview: row["output_preview"],
            success: Self.optionalBool(from: row, column: "success"),
            approved: Self.optionalBool(from: row, column: "approved"),
            latencyMs: row["latency_ms"],
            createdAt: Self.dateFromRow(row, column: "created_at") ?? Date.distantPast
        )
    }

    private static func candidateRecord(from row: Row) -> SkillDraftCandidateRecord {
        SkillDraftCandidateRecord(
            id: row["id"],
            workflowSignature: row["workflow_signature"],
            status: SkillDraftCandidateStatus(rawValue: row["status"] as String? ?? "") ?? .pending,
            action: SkillDraftAction(rawValue: row["action"] as String? ?? "") ?? .create,
            targetSkillName: row["target_skill_name"],
            title: row["title"],
            rationale: row["rationale"],
            evidenceJSON: row["evidence_json"],
            draftSkillMD: row["draft_skill_md"],
            draftManifestJSON: row["draft_manifest_json"],
            draftScript: row["draft_script"],
            confidence: row["confidence"] as Double? ?? 0,
            createdAt: Self.dateFromRow(row, column: "created_at") ?? Date.distantPast,
            updatedAt: Self.dateFromRow(row, column: "updated_at") ?? Date.distantPast
        )
    }

    private static func newID(prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString)"
    }

    private static func unixTimestamp(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970)
    }

    private static func dateFromRow(_ row: Row, column: String) -> Date? {
        if let timestamp = row[column] as Int64? {
            return Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        if let timestamp = row[column] as Int? {
            return Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        if let timestamp = row[column] as Double? {
            return Date(timeIntervalSince1970: timestamp)
        }
        return nil
    }

    private static func redactedAndTrimmed(_ value: String, limit: Int) -> String {
        let redacted = SensitiveDataRedactor.redact(value) ?? value
        let trimmed = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(limit))
    }

    private static func trimmed(_ value: String, limit: Int) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(limit))
    }

    private static func optionalRedactedAndTrimmed(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let normalized = redactedAndTrimmed(value, limit: limit)
        return normalized.isEmpty ? nil : normalized
    }

    private static func optionalTrimmed(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let normalized = trimmed(value, limit: limit)
        return normalized.isEmpty ? nil : normalized
    }

    private static func optionalInt(_ value: Bool?) -> Int? {
        guard let value else { return nil }
        return value ? 1 : 0
    }

    private static func optionalBool(from row: Row, column: String) -> Bool? {
        if let intValue = row[column] as Int? {
            return intValue != 0
        }
        if let int64Value = row[column] as Int64? {
            return int64Value != 0
        }
        return nil
    }
}

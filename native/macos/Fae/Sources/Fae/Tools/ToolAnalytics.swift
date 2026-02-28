import Foundation
import GRDB

/// Tracks tool usage analytics for observability and pattern detection.
///
/// Records every tool invocation with timing, success/failure, and approval status.
/// Stored in a dedicated SQLite database alongside the memory store.
actor ToolAnalytics {
    private let dbQueue: DatabaseQueue

    /// Open or create the analytics database at the given path.
    init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS tool_usage (
                    id          TEXT PRIMARY KEY,
                    tool_name   TEXT NOT NULL,
                    success     INTEGER NOT NULL,
                    latency_ms  INTEGER,
                    approved    INTEGER,
                    error       TEXT,
                    at          INTEGER NOT NULL
                )
                """)
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_tool_usage_name ON tool_usage(tool_name)"
            )
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_tool_usage_at ON tool_usage(at)"
            )
        }

        NSLog("ToolAnalytics: opened at %@", path)
    }

    /// Record a tool invocation.
    func record(
        toolName: String,
        success: Bool,
        latencyMs: Int?,
        approved: Bool?,
        error: String?
    ) {
        let now = UInt64(Date().timeIntervalSince1970)
        let id = "tool-\(now)-\(Int.random(in: 1000 ... 9999))"

        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO tool_usage (id, tool_name, success, latency_ms, approved, error, at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        id, toolName, success ? 1 : 0,
                        latencyMs, approved.map { $0 ? 1 : 0 },
                        error, now,
                    ]
                )
            }
        } catch {
            NSLog("ToolAnalytics: record error: %@", error.localizedDescription)
        }
    }

    /// Summary of tool usage for diagnostics.
    struct ToolSummary: Sendable {
        let toolName: String
        let totalCalls: Int
        let successCount: Int
        let failureCount: Int
        let avgLatencyMs: Int?
        let approvalRate: Float?
    }

    /// Get usage summary for all tools.
    func summary() -> [ToolSummary] {
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT
                        tool_name,
                        COUNT(*) as total,
                        SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) as successes,
                        SUM(CASE WHEN success = 0 THEN 1 ELSE 0 END) as failures,
                        AVG(latency_ms) as avg_latency,
                        AVG(CASE WHEN approved IS NOT NULL THEN CAST(approved AS REAL) END) as approval_rate
                    FROM tool_usage
                    GROUP BY tool_name
                    ORDER BY total DESC
                    """)

                return rows.map { row in
                    ToolSummary(
                        toolName: row["tool_name"],
                        totalCalls: row["total"],
                        successCount: row["successes"],
                        failureCount: row["failures"],
                        avgLatencyMs: (row["avg_latency"] as Double?).map { Int($0) },
                        approvalRate: (row["approval_rate"] as Double?).map { Float($0) }
                    )
                }
            }
        } catch {
            NSLog("ToolAnalytics: summary error: %@", error.localizedDescription)
            return []
        }
    }

    /// Total number of recorded invocations.
    func totalRecords() -> Int {
        do {
            return try dbQueue.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM tool_usage"
                )
                return row?[0] as? Int ?? 0
            }
        } catch {
            return 0
        }
    }
}

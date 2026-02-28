import Foundation
import GRDB

/// Persistent store for quality metrics using GRDB/SQLite.
actor QualityMetricStore {
    private let dbQueue: DatabaseQueue

    init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try Self.applySchema(db)
        }
        dbQueue = try DatabaseQueue(path: path, configuration: config)
    }

    private static func applySchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS quality_metrics (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                category    TEXT NOT NULL,
                metric_name TEXT NOT NULL,
                value       REAL NOT NULL,
                unit        TEXT NOT NULL,
                context     TEXT,
                recorded_at REAL NOT NULL,
                run_id      TEXT
            )
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_qm_name ON quality_metrics(metric_name)
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_qm_recorded ON quality_metrics(recorded_at)
        """)
    }

    // MARK: - Write

    func record(metric: QualityMetricRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO quality_metrics (category, metric_name, value, unit, context, recorded_at, run_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    metric.category.rawValue,
                    metric.metricName.rawValue,
                    metric.value,
                    metric.unit,
                    metric.context,
                    metric.recordedAt.timeIntervalSince1970,
                    metric.runId,
                ]
            )
        }
    }

    func recordBatch(metrics: [QualityMetricRecord]) throws {
        try dbQueue.write { db in
            for metric in metrics {
                try db.execute(
                    sql: """
                        INSERT INTO quality_metrics (category, metric_name, value, unit, context, recorded_at, run_id)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        metric.category.rawValue,
                        metric.metricName.rawValue,
                        metric.value,
                        metric.unit,
                        metric.context,
                        metric.recordedAt.timeIntervalSince1970,
                        metric.runId,
                    ]
                )
            }
        }
    }

    // MARK: - Read

    func latestMetrics(name: MetricName, limit: Int = 20) throws -> [QualityMetricRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM quality_metrics
                    WHERE metric_name = ?
                    ORDER BY recorded_at DESC
                    LIMIT ?
                """,
                arguments: [name.rawValue, limit]
            )
            return rows.compactMap { Self.recordFromRow($0) }
        }
    }

    func metricsInRange(name: MetricName, from: Date, to: Date) throws -> [QualityMetricRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM quality_metrics
                    WHERE metric_name = ? AND recorded_at >= ? AND recorded_at <= ?
                    ORDER BY recorded_at ASC
                """,
                arguments: [name.rawValue, from.timeIntervalSince1970, to.timeIntervalSince1970]
            )
            return rows.compactMap { Self.recordFromRow($0) }
        }
    }

    // MARK: - Aggregation

    func aggregate(name: MetricName, windowSeconds: TimeInterval) throws -> MetricAggregation? {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        return try dbQueue.read { db in
            let statsRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) as cnt, MIN(value) as min_val, MAX(value) as max_val, AVG(value) as avg_val
                    FROM quality_metrics
                    WHERE metric_name = ? AND recorded_at >= ?
                """,
                arguments: [name.rawValue, cutoff.timeIntervalSince1970]
            )

            guard let stats = statsRow, stats["cnt"] as? Int64 ?? 0 > 0 else {
                return nil
            }

            let count = Int(stats["cnt"] as? Int64 ?? 0)
            let minVal = stats["min_val"] as? Double ?? 0
            let maxVal = stats["max_val"] as? Double ?? 0
            let meanVal = stats["avg_val"] as? Double ?? 0

            let valueRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT value FROM quality_metrics
                    WHERE metric_name = ? AND recorded_at >= ?
                    ORDER BY value ASC
                """,
                arguments: [name.rawValue, cutoff.timeIntervalSince1970]
            )

            let values = valueRows.compactMap { $0["value"] as? Double }
            let p50 = Self.percentile(values, 0.50)
            let p95 = Self.percentile(values, 0.95)
            let p99 = Self.percentile(values, 0.99)

            return MetricAggregation(
                metricName: name,
                count: count,
                min: minVal,
                max: maxVal,
                mean: meanVal,
                p50: p50,
                p95: p95,
                p99: p99
            )
        }
    }

    // MARK: - Threshold Checks

    func checkThreshold(name: MetricName, threshold: QualityThreshold) throws -> ThresholdResult? {
        let latest = try latestMetrics(name: name, limit: 1)
        guard let metric = latest.first else { return nil }
        let thresholdSet = QualityThresholdSet(thresholds: [threshold])
        return thresholdSet.check(metricName: name, value: metric.value)
    }

    func checkAllThresholds(thresholds: QualityThresholdSet) throws -> [ThresholdResult] {
        var results: [ThresholdResult] = []
        for threshold in thresholds.thresholds {
            if let result = try checkThreshold(name: threshold.metricName, threshold: threshold) {
                results.append(result)
            }
        }
        return results
    }

    // MARK: - Maintenance

    func pruneOlderThan(days: Int) throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        return try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM quality_metrics WHERE recorded_at < ?",
                arguments: [cutoff.timeIntervalSince1970]
            )
            return db.changesCount
        }
    }

    // MARK: - Helpers

    private static func recordFromRow(_ row: Row) -> QualityMetricRecord? {
        guard
            let nameStr = row["metric_name"] as? String,
            let name = MetricName(rawValue: nameStr),
            let value = row["value"] as? Double,
            let timestamp = row["recorded_at"] as? Double
        else { return nil }

        return QualityMetricRecord(
            id: row["id"] as? Int64,
            metricName: name,
            value: value,
            context: row["context"] as? String,
            recordedAt: Date(timeIntervalSince1970: timestamp),
            runId: row["run_id"] as? String
        )
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = p * Double(sorted.count - 1)
        let lower = Int(index)
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = index - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }
}

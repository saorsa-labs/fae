import Foundation

/// Simple local checkpoint/rollback primitives for destructive file operations.
enum ReversibilityEngine {
    struct CheckpointRecord: Codable, Sendable {
        let id: String
        let createdAt: Date
        let originalPath: String
        let backupPath: String?
        let existedBefore: Bool
        let reason: String
    }

    private static var recoveryDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/recovery")
    }

    private static var indexURL: URL {
        recoveryDir.appendingPathComponent("checkpoints.json")
    }

    /// Create a checkpoint for the target path before mutation.
    ///
    /// Returns checkpoint id, or nil on failure.
    @discardableResult
    static func createCheckpoint(for path: String, reason: String) -> String? {
        do {
            let target = URL(fileURLWithPath: path).standardized.resolvingSymlinksInPath()
            let fm = FileManager.default

            try fm.createDirectory(at: recoveryDir, withIntermediateDirectories: true)

            let existed = fm.fileExists(atPath: target.path)
            let id = UUID().uuidString
            var backupPath: String?

            if existed {
                let backupURL = recoveryDir.appendingPathComponent("\(id).bak")
                try? fm.removeItem(at: backupURL)
                try fm.copyItem(at: target, to: backupURL)
                backupPath = backupURL.path
            }

            let record = CheckpointRecord(
                id: id,
                createdAt: Date(),
                originalPath: target.path,
                backupPath: backupPath,
                existedBefore: existed,
                reason: reason
            )

            var records = loadRecords()
            records.append(record)
            try saveRecords(records)
            pruneExpired(hours: 24)

            return id
        } catch {
            NSLog("ReversibilityEngine: createCheckpoint failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Restore from a previously created checkpoint.
    @discardableResult
    static func restore(checkpointId: String) -> Bool {
        let records = loadRecords()
        guard let record = records.first(where: { $0.id == checkpointId }) else {
            return false
        }

        let fm = FileManager.default
        let original = URL(fileURLWithPath: record.originalPath)

        do {
            if record.existedBefore {
                guard let backupPath = record.backupPath else { return false }
                let backupURL = URL(fileURLWithPath: backupPath)
                guard fm.fileExists(atPath: backupURL.path) else { return false }

                if fm.fileExists(atPath: original.path) {
                    try? fm.removeItem(at: original)
                }
                try fm.copyItem(at: backupURL, to: original)
            } else {
                // File didn't exist before operation; remove created file.
                if fm.fileExists(atPath: original.path) {
                    try fm.removeItem(at: original)
                }
            }
            return true
        } catch {
            NSLog("ReversibilityEngine: restore failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Remove expired checkpoints and old backup files.
    static func pruneExpired(hours: Int) {
        let cutoff = Date().addingTimeInterval(TimeInterval(-hours * 3600))
        let fm = FileManager.default

        var records = loadRecords()
        let (keep, expired) = records.partitioned { $0.createdAt >= cutoff }
        records = keep
        try? saveRecords(records)

        for record in expired {
            if let backup = record.backupPath {
                try? fm.removeItem(atPath: backup)
            }
        }
    }

    static func latestCheckpoint(for path: String) -> String? {
        let canonical = URL(fileURLWithPath: path).standardized.resolvingSymlinksInPath().path
        let records = loadRecords().filter { $0.originalPath == canonical }
        return records.max(by: { $0.createdAt < $1.createdAt })?.id
    }

    private static func loadRecords() -> [CheckpointRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([CheckpointRecord].self, from: data)) ?? []
    }

    private static func saveRecords(_ records: [CheckpointRecord]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(records)
        try data.write(to: indexURL, options: .atomic)
    }
}

private extension Array {
    func partitioned(_ predicate: (Element) -> Bool) -> ([Element], [Element]) {
        var a: [Element] = []
        var b: [Element] = []
        for element in self {
            if predicate(element) {
                a.append(element)
            } else {
                b.append(element)
            }
        }
        return (a, b)
    }
}

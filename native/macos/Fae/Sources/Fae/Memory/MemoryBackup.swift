import Foundation
import GRDB

/// Manages memory database backups using SQLite VACUUM INTO.
///
/// Replaces: `src/memory/backup.rs`
enum MemoryBackup {

    /// Create an atomic backup of the memory database.
    ///
    /// Uses `VACUUM INTO` for a consistent, compact copy.
    /// Returns the path to the created backup file.
    static func backup(dbPath: String, backupDir: String) throws -> String {
        try FileManager.default.createDirectory(
            atPath: backupDir,
            withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let timestamp = formatter.string(from: Date())
        let backupName = "fae-backup-\(timestamp).db"
        let backupPath = (backupDir as NSString).appendingPathComponent(backupName)

        // Escape single quotes in path for SQL.
        let escaped = backupPath.replacingOccurrences(of: "'", with: "''")

        let dbQueue = try DatabaseQueue(path: dbPath)
        try dbQueue.write { db in
            try db.execute(sql: "VACUUM INTO '\(escaped)'")
        }

        NSLog("MemoryBackup: created backup at %@", backupPath)
        return backupPath
    }

    /// Rotate backups, keeping only the most recent `keepCount`.
    ///
    /// Returns the number of deleted backup files.
    static func rotateBackups(backupDir: String, keepCount: Int = 7) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupDir) else { return 0 }

        let contents = try fm.contentsOfDirectory(atPath: backupDir)
        let backupFiles = contents
            .filter { $0.hasPrefix("fae-backup-") && $0.hasSuffix(".db") }
            .sorted(by: >) // Newest first (timestamp format ensures correct ordering).

        guard backupFiles.count > keepCount else { return 0 }

        var deleted = 0
        for file in backupFiles.dropFirst(keepCount) {
            let path = (backupDir as NSString).appendingPathComponent(file)
            do {
                try fm.removeItem(atPath: path)
                deleted += 1
            } catch {
                NSLog("MemoryBackup: failed to delete %@: %@", file, error.localizedDescription)
            }
        }

        NSLog("MemoryBackup: rotated %d old backups", deleted)
        return deleted
    }
}

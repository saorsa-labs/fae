import XCTest
import GRDB
@testable import Fae

/// Coverage for two 0%-covered files: AudioToneGenerator (pure signal
/// generation) and MemoryBackup (SQLite VACUUM-INTO backup + rotation, tested
/// with temp dirs + an in-memory-derived DB file).
final class AudioAndBackupStaticTests: XCTestCase {

    private let tempDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("fae-audiobackup-\(UUID().uuidString)")

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - AudioToneGenerator

    func testThinkingToneProducesNonEmptySamples() {
        let tone = AudioToneGenerator.thinkingTone()
        XCTAssertGreaterThan(tone.count, 0)
        // Two notes @ 0.150s each at 24kHz -> ~7200 samples.
        XCTAssertGreaterThan(tone.count, 5000)
    }

    func testListeningToneProducesNonEmptySamples() {
        let tone = AudioToneGenerator.listeningTone()
        XCTAssertGreaterThan(tone.count, 0)
    }

    func testReadyBeepProducesNonEmptySamples() {
        let beep = AudioToneGenerator.readyBeep()
        // 0.150s at 24kHz -> ~3600 samples.
        XCTAssertEqual(beep.count, Int(AudioToneGenerator.sampleRate * 0.150))
    }

    func testToneAmplitudesBoundedByVolume() {
        // All samples must be within [-volume, +volume]; volume <= 0.12.
        for sample in AudioToneGenerator.readyBeep() {
            XCTAssertLessThanOrEqual(abs(sample), 0.13)
        }
        for sample in AudioToneGenerator.thinkingTone() {
            XCTAssertLessThanOrEqual(abs(sample), 0.06)
        }
    }

    // MARK: - MemoryBackup.backup

    func testBackupCreatesBackupFile() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Create a real (small) SQLite DB to back up.
        let dbPath = tempDir.appendingPathComponent("fae.db").path
        let dbQueue = try DatabaseQueue(path: dbPath)
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO t (id) VALUES (1)")
        }

        let backupDir = tempDir.appendingPathComponent("backups").path
        let result = try MemoryBackup.backup(dbPath: dbPath, backupDir: backupDir)
        XCTAssertTrue(result.contains("fae-backup-"))
        XCTAssertTrue(result.hasSuffix(".db"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result))

        // The backup should be a valid readable SQLite DB.
        let restored = try DatabaseQueue(path: result)
        let count = try restored.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testBackupCreatesBackupDirIfMissing() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("src.db").path
        let dbQueue = try DatabaseQueue(path: dbPath)
        try dbQueue.write { db in try db.execute(sql: "CREATE TABLE t (id INTEGER)") }

        let backupDir = tempDir.appendingPathComponent("newdir").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDir))
        _ = try MemoryBackup.backup(dbPath: dbPath, backupDir: backupDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDir))
    }

    // MARK: - MemoryBackup.rotateBackups

    func testRotateBackupsDeletesOldestBeyondKeepCount() throws {
        let backupDir = tempDir.appendingPathComponent("rot").path
        try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        // Create 5 fake backup files with distinct timestamps.
        for ts in ["20240101-000001", "20240102-000001", "20240103-000001",
                   "20240104-000001", "20240105-000001"] {
            let p = (backupDir as NSString).appendingPathComponent("fae-backup-\(ts).db")
            try "x".write(toFile: p, atomically: true, encoding: .utf8)
        }

        let deleted = try MemoryBackup.rotateBackups(backupDir: backupDir, keepCount: 3)
        XCTAssertEqual(deleted, 2)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: backupDir)
            .filter { $0.hasSuffix(".db") }
        XCTAssertEqual(remaining.count, 3)
    }

    func testRotateBackupsNoOpWhenUnderKeepCount() throws {
        let backupDir = tempDir.appendingPathComponent("under").path
        try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        for ts in ["20240101-000001", "20240102-000001"] {
            let p = (backupDir as NSString).appendingPathComponent("fae-backup-\(ts).db")
            try "x".write(toFile: p, atomically: true, encoding: .utf8)
        }
        let deleted = try MemoryBackup.rotateBackups(backupDir: backupDir, keepCount: 7)
        XCTAssertEqual(deleted, 0)
    }

    func testRotateBackupsMissingDirReturnsZero() throws {
        let deleted = try MemoryBackup.rotateBackups(
            backupDir: tempDir.appendingPathComponent("nonexistent").path, keepCount: 3)
        XCTAssertEqual(deleted, 0)
    }
}

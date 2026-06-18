import Foundation
import XCTest
@testable import Fae

final class ReversibilityEngineFilesystemTests: XCTestCase {
    private var tempRoot: URL!
    private var recoveryDir: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-reversibility-")
            .appendingPathComponent(UUID().uuidString)
        recoveryDir = tempRoot.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("FAE_REVERSIBILITY_RECOVERY_DIR", recoveryDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("FAE_REVERSIBILITY_RECOVERY_DIR")
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        recoveryDir = nil
    }

    func testCreateCheckpointForExistingFileBacksUpAndRestoreRevertsContents() throws {
        let target = tempRoot.appendingPathComponent("note.txt")
        try "before".write(to: target, atomically: true, encoding: .utf8)

        let checkpointID = try XCTUnwrap(ReversibilityEngine.createCheckpoint(for: target.path, reason: "unit test"))
        try "after".write(to: target, atomically: true, encoding: .utf8)

        XCTAssertEqual(ReversibilityEngine.latestCheckpoint(for: target.path), checkpointID)
        XCTAssertTrue(ReversibilityEngine.restore(checkpointId: checkpointID))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "before")

        let records = try loadRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, checkpointID)
        XCTAssertTrue(records[0].existedBefore)
        XCTAssertEqual(records[0].reason, "unit test")
        XCTAssertNotNil(records[0].backupPath)
    }

    func testRestoreForMissingOriginalRemovesNewFile() throws {
        let target = tempRoot.appendingPathComponent("created-later.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        let checkpointID = try XCTUnwrap(ReversibilityEngine.createCheckpoint(for: target.path, reason: "new file"))
        try "created".write(to: target, atomically: true, encoding: .utf8)

        XCTAssertTrue(ReversibilityEngine.restore(checkpointId: checkpointID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testRestoreUnknownCheckpointReturnsFalse() {
        XCTAssertFalse(ReversibilityEngine.restore(checkpointId: "missing"))
    }

    func testRestoreReturnsFalseWhenBackupIsMissing() throws {
        let target = tempRoot.appendingPathComponent("lost-backup.txt")
        try "before".write(to: target, atomically: true, encoding: .utf8)

        let checkpointID = try XCTUnwrap(ReversibilityEngine.createCheckpoint(for: target.path, reason: "backup missing"))
        let record = try XCTUnwrap(loadRecords().first)
        if let backupPath = record.backupPath {
            try FileManager.default.removeItem(atPath: backupPath)
        }

        XCTAssertFalse(ReversibilityEngine.restore(checkpointId: checkpointID))
    }

    func testPruneExpiredDeletesOldBackupsAndKeepsRecentRecords() throws {
        try FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)
        let oldBackup = recoveryDir.appendingPathComponent("old.bak")
        let recentBackup = recoveryDir.appendingPathComponent("recent.bak")
        try "old".write(to: oldBackup, atomically: true, encoding: .utf8)
        try "recent".write(to: recentBackup, atomically: true, encoding: .utf8)

        let old = ReversibilityEngine.CheckpointRecord(
            id: "old",
            createdAt: Date(timeIntervalSinceNow: -48 * 3600),
            originalPath: tempRoot.appendingPathComponent("old.txt").path,
            backupPath: oldBackup.path,
            existedBefore: true,
            reason: "expired"
        )
        let recent = ReversibilityEngine.CheckpointRecord(
            id: "recent",
            createdAt: Date(),
            originalPath: tempRoot.appendingPathComponent("recent.txt").path,
            backupPath: recentBackup.path,
            existedBefore: true,
            reason: "fresh"
        )
        try saveRecords([old, recent])

        ReversibilityEngine.pruneExpired(hours: 24)

        let records = try loadRecords()
        XCTAssertEqual(records.map(\.id), ["recent"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBackup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentBackup.path))
    }

    private func indexURL() -> URL {
        recoveryDir.appendingPathComponent("checkpoints.json")
    }

    private func loadRecords() throws -> [ReversibilityEngine.CheckpointRecord] {
        let data = try Data(contentsOf: indexURL())
        return try JSONDecoder().decode([ReversibilityEngine.CheckpointRecord].self, from: data)
    }

    private func saveRecords(_ records: [ReversibilityEngine.CheckpointRecord]) throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: indexURL(), options: .atomic)
    }
}

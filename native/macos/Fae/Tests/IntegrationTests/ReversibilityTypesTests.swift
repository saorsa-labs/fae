import XCTest
@testable import Fae

final class ReversibilityTypesTests: XCTestCase {

    // MARK: - CheckpointRecord

    func testCheckpointRecordInit() {
        let record = ReversibilityEngine.CheckpointRecord(
            id: "test-id",
            createdAt: Date(),
            originalPath: "/tmp/test.txt",
            backupPath: "/tmp/recovery/test-id.bak",
            existedBefore: true,
            reason: "User requested file edit"
        )
        XCTAssertEqual(record.id, "test-id")
        XCTAssertTrue(record.existedBefore)
    }

    func testCheckpointRecordCodable() throws {
        let record = ReversibilityEngine.CheckpointRecord(
            id: "test-id",
            createdAt: Date(timeIntervalSince1970: 1000000),
            originalPath: "/tmp/test.txt",
            backupPath: "/tmp/recovery/test-id.bak",
            existedBefore: true,
            reason: "Test checkpoint"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ReversibilityEngine.CheckpointRecord.self, from: data)

        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.originalPath, record.originalPath)
        XCTAssertEqual(decoded.backupPath, record.backupPath)
        XCTAssertEqual(decoded.existedBefore, record.existedBefore)
        XCTAssertEqual(decoded.reason, record.reason)
    }

    func testCheckpointRecordNoBackup() {
        let record = ReversibilityEngine.CheckpointRecord(
            id: "test-id-2",
            createdAt: Date(),
            originalPath: "/tmp/newfile.txt",
            backupPath: nil,
            existedBefore: false,
            reason: "New file creation"
        )
        XCTAssertNil(record.backupPath)
        XCTAssertFalse(record.existedBefore)
    }

    func testCheckpointRecordArrayCodable() throws {
        let records = [
            ReversibilityEngine.CheckpointRecord(
                id: "id-1", createdAt: Date(), originalPath: "/a", backupPath: "/b", existedBefore: true, reason: "r1"
            ),
            ReversibilityEngine.CheckpointRecord(
                id: "id-2", createdAt: Date(), originalPath: "/c", backupPath: nil, existedBefore: false, reason: "r2"
            ),
        ]

        let data = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode([ReversibilityEngine.CheckpointRecord].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].id, "id-1")
        XCTAssertEqual(decoded[1].id, "id-2")
    }


}

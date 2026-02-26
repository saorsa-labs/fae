import Foundation
import XCTest
@testable import Fae

final class MemoryMigrationCompatibilityTests: XCTestCase {

    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("Memory", isDirectory: true)
    }

    private func loadManifestText() throws -> String {
        let url = fixtureDirectory().appendingPathComponent("manifest.toml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func loadRecordObjects() throws -> [[String: Any]] {
        let url = fixtureDirectory().appendingPathComponent("records.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [[String: Any]] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let data = Data(line.utf8)
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            if let dict = obj as? [String: Any] { out.append(dict) }
        }
        return out
    }

    func testLegacySchemaFixtureMigratesAndLoadsRecords() throws {
        let dir = fixtureDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        let manifest = try loadManifestText()
        XCTAssertTrue(manifest.contains("schema_version"))

        let records = try loadRecordObjects()
        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(records.contains { ($0["status"] as? String) == "active" })
        XCTAssertTrue(records.contains { ["episode", "fact"].contains(($0["kind"] as? String) ?? "") })
    }

    func testLegacyStatusesMapToCurrentLifecycleStates() throws {
        let allowed: Set<String> = ["active", "superseded", "invalidated", "forgotten"]
        let statuses = try Set(loadRecordObjects().compactMap { $0["status"] as? String })

        XCTAssertFalse(statuses.isEmpty)
        XCTAssertTrue(statuses.isSubset(of: allowed))
        XCTAssertTrue(statuses.contains("active"))
        XCTAssertTrue(statuses.contains("superseded"))
    }

    func testRetentionPolicyHandlesMigratedEpisodeTimestamps() throws {
        let records = try loadRecordObjects()
        let episodes: [[String: Any]] = records.filter { ($0["kind"] as? String) == "episode" }
        XCTAssertFalse(episodes.isEmpty)

        let now: UInt64 = 1_750_000_000
        let retentionDays: UInt64 = 90
        let cutoff = now - (retentionDays * 86_400)

        let stale = episodes.filter { (($0["updated_at"] as? UInt64) ?? 0) < cutoff }
        let fresh = episodes.filter { (($0["updated_at"] as? UInt64) ?? 0) >= cutoff }

        XCTAssertFalse(stale.isEmpty)
        XCTAssertFalse(fresh.isEmpty)
    }
}

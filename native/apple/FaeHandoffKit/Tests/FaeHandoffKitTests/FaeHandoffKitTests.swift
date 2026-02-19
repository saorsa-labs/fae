import XCTest
@testable import FaeHandoffKit

// MARK: - FaeHandoffContract Tests

final class FaeHandoffKitTests: XCTestCase {
    func testPayloadRoundTrip() throws {
        let payload = FaeHandoffPayload(
            target: .watch,
            command: "move to my watch",
            issuedAtEpochMs: 1_701_000_000_000
        )

        let userInfo = FaeHandoffContract.userInfo(from: payload)
        let decoded = try FaeHandoffContract.payload(from: userInfo)
        XCTAssertEqual(decoded, payload)
    }

    func testMissingTargetFails() {
        XCTAssertThrowsError(
            try FaeHandoffContract.payload(from: ["command": "move to my phone"])
        ) { error in
            XCTAssertEqual(error as? FaeHandoffError, .missingField("target"))
        }
    }

    func testInvalidTargetFails() {
        XCTAssertThrowsError(
            try FaeHandoffContract.payload(
                from: ["target": "tablet", "issuedAtEpochMs": 123]
            )
        ) { error in
            XCTAssertEqual(error as? FaeHandoffError, .invalidTarget("tablet"))
        }
    }
}

// MARK: - ConversationSnapshot Tests

final class ConversationSnapshotTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Round-trip

    func testSnapshotRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ConversationSnapshot(
            entries: [
                SnapshotEntry(role: "user", content: "Hello"),
                SnapshotEntry(role: "assistant", content: "Hi there"),
            ],
            orbMode: "idle",
            orbFeeling: "calm",
            timestamp: now
        )

        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(ConversationSnapshot.self, from: data)

        XCTAssertEqual(decoded.entries.count, 2)
        XCTAssertEqual(decoded.entries[0].role, "user")
        XCTAssertEqual(decoded.entries[0].content, "Hello")
        XCTAssertEqual(decoded.entries[1].role, "assistant")
        XCTAssertEqual(decoded.entries[1].content, "Hi there")
        XCTAssertEqual(decoded.orbMode, "idle")
        XCTAssertEqual(decoded.orbFeeling, "calm")
        // Timestamp round-trips within 1-second precision due to ISO-8601 granularity.
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970,
                       now.timeIntervalSince1970,
                       accuracy: 1.0)
    }

    func testEmptyEntriesRoundTrip() throws {
        let snapshot = ConversationSnapshot(
            entries: [],
            orbMode: "thinking",
            orbFeeling: "focus",
            timestamp: Date()
        )
        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(ConversationSnapshot.self, from: data)
        XCTAssertTrue(decoded.entries.isEmpty)
    }

    // MARK: Role Filtering Contract

    /// Verifies that entries with "system", "tool", or "memory" roles are NOT
    /// present in a correctly filtered snapshot. The filtering is the provider's
    /// responsibility; this test documents the expected contract.
    func testOnlyUserAndAssistantRolesArePresent() throws {
        // Simulate a correctly-filtered snapshot (as the provider must supply).
        let filtered = ConversationSnapshot(
            entries: [
                SnapshotEntry(role: "user", content: "What time is it?"),
                SnapshotEntry(role: "assistant", content: "It's 3 PM."),
            ],
            orbMode: "idle",
            orbFeeling: "neutral",
            timestamp: Date()
        )

        let data = try encoder.encode(filtered)
        let decoded = try decoder.decode(ConversationSnapshot.self, from: data)

        let roles = Set(decoded.entries.map(\.role))
        XCTAssertTrue(roles.isSubset(of: ["user", "assistant"]),
                      "Expected only user/assistant roles, got: \(roles)")
    }

    func testSystemRoleIsNotInSnapshot() {
        // A snapshot built by a correct provider must exclude system entries.
        let entries = [
            SnapshotEntry(role: "user", content: "Hello"),
            SnapshotEntry(role: "assistant", content: "Hi"),
        ]
        let systemFiltered = entries.filter { $0.role == "user" || $0.role == "assistant" }
        XCTAssertEqual(systemFiltered.count, 2)
        XCTAssertFalse(systemFiltered.map(\.role).contains("system"))
        XCTAssertFalse(systemFiltered.map(\.role).contains("tool"))
        XCTAssertFalse(systemFiltered.map(\.role).contains("memory"))
    }

    // MARK: Entry Capping

    func testMaxEntriesConstantIsReasonable() {
        // Ensures the cap is set to a sensible value for NSUserActivity limits.
        XCTAssertGreaterThanOrEqual(ConversationSnapshot.maxEntries, 10)
        XCTAssertLessThanOrEqual(ConversationSnapshot.maxEntries, 50)
    }

    func testSuffixCappingPreservesNewestEntries() {
        let allEntries = (0..<30).map { i in
            SnapshotEntry(role: i.isMultiple(of: 2) ? "user" : "assistant",
                          content: "message \(i)")
        }
        let capped = Array(allEntries.suffix(ConversationSnapshot.maxEntries))
        XCTAssertEqual(capped.count, ConversationSnapshot.maxEntries)
        XCTAssertEqual(capped.last?.content, "message 29")
        XCTAssertEqual(capped.first?.content, "message 10")
    }

    // MARK: Encoding Edge Cases

    func testSnapshotWithUnicodeContent() throws {
        let snapshot = ConversationSnapshot(
            entries: [SnapshotEntry(role: "user", content: "你好 🌸 café")],
            orbMode: "idle",
            orbFeeling: "warmth",
            timestamp: Date()
        )
        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(ConversationSnapshot.self, from: data)
        XCTAssertEqual(decoded.entries.first?.content, "你好 🌸 café")
    }

    func testSnapshotIsValidJSONString() throws {
        let snapshot = ConversationSnapshot(
            entries: [SnapshotEntry(role: "user", content: "test")],
            orbMode: "idle",
            orbFeeling: "calm",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try encoder.encode(snapshot)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            XCTFail("Encoded data was not valid UTF-8")
            return
        }
        XCTAssertTrue(jsonString.hasPrefix("{"))
        XCTAssertTrue(jsonString.hasSuffix("}"))
        XCTAssertTrue(jsonString.contains("\"entries\""))
        XCTAssertTrue(jsonString.contains("\"orbMode\""))
        XCTAssertTrue(jsonString.contains("\"orbFeeling\""))
        XCTAssertTrue(jsonString.contains("\"timestamp\""))
    }
}

// MARK: - SnapshotEntry Tests

final class SnapshotEntryTests: XCTestCase {

    func testEntryRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let entry = SnapshotEntry(role: "user", content: "Hello, world!")
        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(SnapshotEntry.self, from: data)
        XCTAssertEqual(decoded.role, "user")
        XCTAssertEqual(decoded.content, "Hello, world!")
    }

    func testEntryWithEmptyContent() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let entry = SnapshotEntry(role: "assistant", content: "")
        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(SnapshotEntry.self, from: data)
        XCTAssertEqual(decoded.content, "")
    }
}

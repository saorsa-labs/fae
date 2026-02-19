import XCTest
@testable import FaeHandoffKit

// MARK: - DeviceCommandParser (copied for isolated testing)

/// Mirrors the production `DeviceCommandParser` in DeviceHandoff.swift.
/// Copied here so tests can run without linking libfae.a.
private enum TestDeviceCommand: Equatable {
    case move(String)   // rawValue of target
    case goHome
    case unsupported
}

private enum TestDeviceCommandParser {
    static func parse(_ text: String) -> TestDeviceCommand {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return .unsupported
        }

        if normalized.contains("go home") || normalized.contains("move home") {
            return .goHome
        }

        if normalized.contains("move to my watch")
            || normalized.contains("move to watch")
            || normalized.contains("to watch")
        {
            return .move("watch")
        }

        if normalized.contains("move to my phone")
            || normalized.contains("move to phone")
            || normalized.contains("move to my iphone")
            || normalized.contains("move to iphone")
            || normalized.contains("to iphone")
            || normalized.contains("to phone")
        {
            return .move("iphone")
        }

        if normalized.contains("back to mac") {
            return .goHome
        }

        return .unsupported
    }
}

// MARK: - DeviceCommandParser Tests

final class DeviceCommandParserTests: XCTestCase {

    // MARK: Watch Commands

    func testMoveToMyWatch() {
        XCTAssertEqual(TestDeviceCommandParser.parse("move to my watch"), .move("watch"))
    }

    func testMoveToWatch() {
        XCTAssertEqual(TestDeviceCommandParser.parse("move to watch"), .move("watch"))
    }

    func testToWatch() {
        XCTAssertEqual(TestDeviceCommandParser.parse("to watch"), .move("watch"))
    }

    func testWatchCaseInsensitive() {
        XCTAssertEqual(TestDeviceCommandParser.parse("Move To My Watch"), .move("watch"))
    }

    // MARK: iPhone Commands

    func testMoveToMyPhone() {
        XCTAssertEqual(TestDeviceCommandParser.parse("move to my phone"), .move("iphone"))
    }

    func testMoveToIphone() {
        XCTAssertEqual(TestDeviceCommandParser.parse("move to my iphone"), .move("iphone"))
    }

    func testToPhone() {
        XCTAssertEqual(TestDeviceCommandParser.parse("to phone"), .move("iphone"))
    }

    func testToIphone() {
        XCTAssertEqual(TestDeviceCommandParser.parse("to iphone"), .move("iphone"))
    }

    func testPhoneCaseInsensitive() {
        XCTAssertEqual(TestDeviceCommandParser.parse("MOVE TO MY IPHONE"), .move("iphone"))
    }

    // MARK: Go Home Commands

    func testGoHome() {
        XCTAssertEqual(TestDeviceCommandParser.parse("go home"), .goHome)
    }

    func testMoveHome() {
        XCTAssertEqual(TestDeviceCommandParser.parse("move home"), .goHome)
    }

    func testBackToMac() {
        XCTAssertEqual(TestDeviceCommandParser.parse("back to mac"), .goHome)
    }

    // MARK: Unsupported Commands

    func testEmptyString() {
        XCTAssertEqual(TestDeviceCommandParser.parse(""), .unsupported)
    }

    func testWhitespaceOnly() {
        XCTAssertEqual(TestDeviceCommandParser.parse("   "), .unsupported)
    }

    func testUnrelatedText() {
        XCTAssertEqual(TestDeviceCommandParser.parse("hello world"), .unsupported)
    }

    func testPartialMatch() {
        XCTAssertEqual(TestDeviceCommandParser.parse("move to"), .unsupported)
    }

    // MARK: Punctuation Normalization

    func testApostropheRemoval() {
        XCTAssertEqual(TestDeviceCommandParser.parse("move to my watch's"), .move("watch"))
    }

    func testDotNormalization() {
        XCTAssertEqual(TestDeviceCommandParser.parse("go.home"), .goHome)
    }

    func testCommaNormalization() {
        XCTAssertEqual(TestDeviceCommandParser.parse("go,home"), .goHome)
    }
}

// MARK: - ConversationSnapshot Handoff Scenario Tests

final class HandoffScenarioTests: XCTestCase {

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

    // MARK: Snapshot Capping Behavior

    func testSnapshotCappingToMaxEntries() throws {
        let entries = (0..<50).map { i in
            SnapshotEntry(role: i.isMultiple(of: 2) ? "user" : "assistant",
                          content: "message \(i)")
        }
        let capped = Array(entries.suffix(ConversationSnapshot.maxEntries))
        let snapshot = ConversationSnapshot(
            entries: capped,
            orbMode: "idle",
            orbFeeling: "neutral",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(snapshot.entries.count, ConversationSnapshot.maxEntries)
        // Newest entries preserved (suffix)
        XCTAssertEqual(snapshot.entries.last?.content, "message 49")

        // Roundtrip
        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(ConversationSnapshot.self, from: data)
        XCTAssertEqual(decoded.entries.count, ConversationSnapshot.maxEntries)
    }

    // MARK: Malformed Snapshot Handling

    func testMalformedJSONReturnsNil() {
        let garbage = Data("not json at all".utf8)
        let decoded = try? decoder.decode(ConversationSnapshot.self, from: garbage)
        XCTAssertNil(decoded)
    }

    func testMissingFieldReturnsNil() {
        // JSON with missing required fields
        let partial = Data("""
        {"entries": []}
        """.utf8)
        let decoded = try? decoder.decode(ConversationSnapshot.self, from: partial)
        XCTAssertNil(decoded)
    }

    func testEmptyDataReturnsNil() {
        let empty = Data()
        let decoded = try? decoder.decode(ConversationSnapshot.self, from: empty)
        XCTAssertNil(decoded)
    }

    func testWrongDateFormatReturnsNil() {
        // Timestamp in wrong format (not ISO 8601)
        let bad = Data("""
        {
            "entries": [],
            "orbMode": "idle",
            "orbFeeling": "calm",
            "timestamp": "not-a-date"
        }
        """.utf8)
        let decoded = try? decoder.decode(ConversationSnapshot.self, from: bad)
        XCTAssertNil(decoded)
    }

    // MARK: NSUserActivity UserInfo Simulation

    func testHandoffPayloadWithSnapshot() throws {
        let snapshot = ConversationSnapshot(
            entries: [
                SnapshotEntry(role: "user", content: "What time is it?"),
                SnapshotEntry(role: "assistant", content: "3:00 PM"),
            ],
            orbMode: "listening",
            orbFeeling: "curiosity",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // Simulate building userInfo as DeviceHandoffController does
        let snapshotData = try encoder.encode(snapshot)
        let snapshotJSON = String(data: snapshotData, encoding: .utf8)
        XCTAssertNotNil(snapshotJSON)

        let userInfo: [String: Any] = [
            "target": "watch",
            "command": "move to my watch",
            "issuedAtEpochMs": Int(Date().timeIntervalSince1970 * 1000),
            "conversationSnapshot": snapshotJSON!,
        ]

        // Simulate receiving side: decode payload and snapshot
        let payload = try FaeHandoffContract.payload(from: userInfo)
        XCTAssertEqual(payload.target, .watch)

        let receivedJSON = userInfo["conversationSnapshot"] as? String
        XCTAssertNotNil(receivedJSON)

        let receivedData = receivedJSON!.data(using: .utf8)!
        let receivedSnapshot = try decoder.decode(ConversationSnapshot.self, from: receivedData)
        XCTAssertEqual(receivedSnapshot.entries.count, 2)
        XCTAssertEqual(receivedSnapshot.orbMode, "listening")
    }

    func testHandoffPayloadWithoutSnapshot() throws {
        // Graceful degradation when snapshot is missing
        let userInfo: [String: Any] = [
            "target": "iphone",
            "command": "move to my iphone",
            "issuedAtEpochMs": Int(Date().timeIntervalSince1970 * 1000),
        ]

        let payload = try FaeHandoffContract.payload(from: userInfo)
        XCTAssertEqual(payload.target, .iphone)

        // No snapshot key — receiving side should handle nil gracefully
        let snapshotJSON = userInfo["conversationSnapshot"] as? String
        XCTAssertNil(snapshotJSON)
    }

    // MARK: Role Filtering Scenario

    func testFilteringExcludesNonConversationRoles() {
        let rawEntries = [
            SnapshotEntry(role: "system", content: "You are Fae"),
            SnapshotEntry(role: "user", content: "Hello"),
            SnapshotEntry(role: "assistant", content: "Hi there"),
            SnapshotEntry(role: "tool", content: "{\"result\": 42}"),
            SnapshotEntry(role: "memory", content: "User prefers dark mode"),
            SnapshotEntry(role: "user", content: "What's the weather?"),
            SnapshotEntry(role: "assistant", content: "Let me check."),
        ]

        // Provider contract: filter to user+assistant only
        let filtered = rawEntries.filter { $0.role == "user" || $0.role == "assistant" }

        XCTAssertEqual(filtered.count, 4)
        XCTAssertTrue(filtered.allSatisfy { $0.role == "user" || $0.role == "assistant" })
        XCTAssertEqual(filtered[0].content, "Hello")
        XCTAssertEqual(filtered[1].content, "Hi there")
        XCTAssertEqual(filtered[2].content, "What's the weather?")
        XCTAssertEqual(filtered[3].content, "Let me check.")
    }

    // MARK: Snapshot Size Estimation

    func testSnapshotJSONSizeIsReasonable() throws {
        // NSUserActivity userInfo has platform size limits (~4 MB).
        // A max-entries snapshot should stay well under that.
        let entries = (0..<ConversationSnapshot.maxEntries).map { i in
            SnapshotEntry(
                role: i.isMultiple(of: 2) ? "user" : "assistant",
                // ~200 chars per message is a realistic upper bound
                content: String(repeating: "x", count: 200)
            )
        }
        let snapshot = ConversationSnapshot(
            entries: entries,
            orbMode: "idle",
            orbFeeling: "neutral",
            timestamp: Date()
        )
        let data = try encoder.encode(snapshot)
        // Should be under 100 KB (well within NSUserActivity limits)
        XCTAssertLessThan(data.count, 100_000,
                          "Snapshot JSON is \(data.count) bytes — exceeds expected limit")
    }
}

// MARK: - FaeDeviceTarget Tests

final class FaeDeviceTargetTests: XCTestCase {

    func testAllCasesExist() {
        let cases = FaeDeviceTarget.allCases
        XCTAssertEqual(cases.count, 3)
        XCTAssertTrue(cases.contains(.mac))
        XCTAssertTrue(cases.contains(.iphone))
        XCTAssertTrue(cases.contains(.watch))
    }

    func testRawValues() {
        XCTAssertEqual(FaeDeviceTarget.mac.rawValue, "mac")
        XCTAssertEqual(FaeDeviceTarget.iphone.rawValue, "iphone")
        XCTAssertEqual(FaeDeviceTarget.watch.rawValue, "watch")
    }

    func testCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for target in FaeDeviceTarget.allCases {
            let data = try encoder.encode(target)
            let decoded = try decoder.decode(FaeDeviceTarget.self, from: data)
            XCTAssertEqual(decoded, target)
        }
    }
}

// MARK: - Manual Test Plan
//
// The following scenarios require a running macOS app with Handoff-capable devices.
// They cannot be automated in unit tests due to system framework dependencies
// (NSUserActivity, NWPathMonitor, NSUbiquitousKeyValueStore, NSWorkspace).
//
// ## DeviceHandoffController State Transitions
//
// 1. MOVE TO IPHONE:
//    - Call handoff.move(to: .iphone)
//    - Verify currentTarget == .iphone
//    - Verify handoffStateText == "handoff requested to iPhone"
//    - Verify NSUserActivity is published with correct activityType
//    - Verify conversationSnapshot is present in userInfo
//    - Verify iCloud KV store receives snapshot as fallback
//    - Verify orb flashes .thinking/.dawnLight for 1.5s
//
// 2. MOVE TO WATCH:
//    - Same as above but with .watch target
//    - Verify handoffStateText == "handoff requested to Watch"
//
// 3. GO HOME:
//    - Call handoff.goHome()
//    - Verify currentTarget == .mac
//    - Verify handoffStateText == "on this Mac"
//    - Verify NSUserActivity is invalidated
//    - Verify timeout timer is cancelled
//
// 4. MOVE THEN GO HOME:
//    - Move to .iphone, then goHome()
//    - Verify state resets cleanly
//    - Verify no dangling NSUserActivity
//
// ## Offline Handling
//
// 5. OFFLINE TRANSFER:
//    - Disable network (airplane mode or Network Link Conditioner)
//    - Call handoff.move(to: .iphone)
//    - Verify handoffStateText shows "Offline — saved for later"
//    - Verify snapshot saved to iCloud KV store
//    - Verify pendingRetry is set
//
// 6. NETWORK RESTORE AUTO-RETRY:
//    - From state 5, restore network
//    - Verify NWPathMonitor triggers auto-retry
//    - Verify NSUserActivity is published
//    - Verify pendingRetry is cleared
//
// 7. OFFLINE UI:
//    - With network offline, open HandoffToolbarButton
//    - Verify "Offline — handoff unavailable" message shown
//    - Verify transfer buttons are disabled
//    - Restore network, verify buttons re-enable
//
// ## Handoff Enable/Disable
//
// 8. DISABLE HANDOFF:
//    - Toggle handoff.handoffEnabled = false
//    - Verify HandoffToolbarButton is hidden
//    - Verify move(to:) returns early with "Handoff is disabled"
//    - Verify NWPathMonitor is stopped
//    - Verify UserDefaults persists false
//
// 9. RE-ENABLE HANDOFF:
//    - Toggle handoff.handoffEnabled = true
//    - Verify toolbar button reappears
//    - Verify NWPathMonitor resumes
//    - Verify move(to:) works again
//
// 10. PERSISTED PREFERENCE:
//     - Set handoffEnabled = false, quit app
//     - Relaunch — verify handoffEnabled is still false
//     - Verify default is true on fresh install
//
// ## Receive Handoff
//
// 11. INCOMING HANDOFF:
//     - On a second Mac (or simulator), publish NSUserActivity with snapshot
//     - Verify FaeNativeApp receives via onContinueUserActivity
//     - Verify ConversationController.restoredSnapshot is set
//     - Verify orb flashes .listening/.rowanBerry for 2s
//     - Verify orb mode/feeling restored from snapshot
//
// 12. MALFORMED INCOMING HANDOFF:
//     - Publish NSUserActivity with garbled conversationSnapshot
//     - Verify app logs warning and continues (no crash)
//     - Verify restoredSnapshot remains nil
//
// 13. ICLOUD KV FALLBACK:
//     - Write snapshot to iCloud KV from another device
//     - Launch app — verify checkKVStoreForHandoff() loads it
//     - Verify ConversationController is populated
//     - Verify KV store is cleared after consumption
//
// ## Orb Flash
//
// 14. FLASH WITH REDUCE MOTION OFF:
//     - Trigger flash(mode: .thinking, palette: .dawnLight, duration: 1.5)
//     - Verify orb switches to .thinking/.dawnLight
//     - Wait 1.5s — verify orb returns to previous mode/palette
//
// 15. FLASH WITH REDUCE MOTION ON:
//     - Enable System Preferences > Accessibility > Reduce Motion
//     - Trigger flash()
//     - Verify only palette changes (no mode change)
//     - Wait duration — verify palette restores
//
// 16. RAPID FLASH CANCELLATION:
//     - Trigger flash(), immediately trigger another flash()
//     - Verify first flash is cancelled
//     - Verify only second flash's restore runs
//
// ## Handoff Timeout
//
// 17. TIMEOUT WARNING:
//     - Move to .iphone, wait 30s without goHome()
//     - Verify handoffStateText changes to "Transfer may not have completed"
//
// 18. TIMEOUT CANCELLED BY GO HOME:
//     - Move to .iphone, then goHome() within 30s
//     - Verify timeout does NOT fire
//     - Verify handoffStateText shows "on this Mac" (not timeout message)

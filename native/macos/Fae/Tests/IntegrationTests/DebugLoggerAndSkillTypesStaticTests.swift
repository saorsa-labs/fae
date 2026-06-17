import XCTest
@testable import Fae

/// Coverage for two 0%-covered files: DebugFileLogger (writes to the fixed
/// /tmp/fae-debug.jsonl path — safe for tests, not user state) and SkillTypes
/// (pure enums + SkillMetadata.isChannel computed property + Codable).
@MainActor
final class DebugLoggerAndSkillTypesStaticTests: XCTestCase {

    // MARK: - DebugFileLogger

    private var logPath: String { DebugFileLogger.logPath }

    override func setUp() {
        // Ensure a clean slate for the fixed /tmp log path.
        try? FileManager.default.removeItem(atPath: logPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: logPath)
        super.tearDown()
    }

    func testDebugLoggerCreatesFileOnInit() {
        // init() creates/truncates the log file.
        _ = DebugFileLogger()
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath),
                      "DebugFileLogger should create the log file on init")
    }

    func testDebugLoggerWritesJsonlLine() throws {
        let logger = DebugFileLogger()
        let event = DebugEvent(timestamp: Date(), kind: .llmToken, text: "hello world")
        logger.log(event: event, seq: 42)

        // Allow the write to flush, then read back.
        let data = try Data(contentsOf: URL(fileURLWithPath: logPath))
        let content = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(content.contains("\"seq\":42"), "log line should include seq: \(content)")
        XCTAssertTrue(content.contains("\"kind\":\"LLM\""), "log line should include kind raw value: \(content)")
        XCTAssertTrue(content.contains("hello world"), "log line should include text: \(content)")
        XCTAssertTrue(content.hasSuffix("\n"), "log line should be newline-terminated")
    }

    func testDebugLoggerAppendsMultipleLines() throws {
        let logger = DebugFileLogger()
        logger.log(event: DebugEvent(timestamp: Date(), kind: .stt, text: "first"), seq: 1)
        logger.log(event: DebugEvent(timestamp: Date(), kind: .toolCall, text: "second"), seq: 2)

        let content = try String(contentsOf: URL(fileURLWithPath: logPath), encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"seq\":1"))
        XCTAssertTrue(lines[1].contains("\"seq\":2"))
    }

    func testDebugLoggerLineIsSortedKeyJson() throws {
        let logger = DebugFileLogger()
        logger.log(event: DebugEvent(timestamp: Date(), kind: .memory, text: "x"), seq: 7)
        let content = try String(contentsOf: URL(fileURLWithPath: logPath), encoding: .utf8)
        // With .sortedKeys, "kind" precedes "seq" precedes "text" precedes "ts".
        let kindRange = content.range(of: "\"kind\"")
        let seqRange = content.range(of: "\"seq\"")
        let tsRange = content.range(of: "\"ts\"")
        XCTAssertNotNil(kindRange)
        XCTAssertNotNil(seqRange)
        XCTAssertNotNil(tsRange)
        if let k = kindRange, let s = seqRange, let t = tsRange {
            XCTAssertLessThan(k.lowerBound, s.lowerBound, "kind should precede seq")
            XCTAssertLessThan(s.lowerBound, t.lowerBound, "seq should precede ts")
        }
    }

    // MARK: - SkillTypes

    func testSkillTypeRawValues() {
        XCTAssertEqual(SkillType.instruction.rawValue.count > 0, true)
        XCTAssertEqual(SkillType.executable, SkillType(rawValue: "executable"))
    }

    func testSkillTierRoundTrip() {
        for tier in [SkillTier.builtin, .personal, .community] {
            XCTAssertEqual(SkillTier(rawValue: tier.rawValue), tier)
        }
    }

    func testSkillMetadataIsChannelTrueWhenTagged() {
        let md = SkillMetadata(
            name: "discord", description: "d", author: nil, version: nil,
            tags: ["channel", "discord"], type: .executable, tier: .community,
            isEnabled: true,
            directoryURL: URL(fileURLWithPath: "/tmp/skill")
        )
        XCTAssertTrue(md.isChannel)
    }

    func testSkillMetadataIsChannelFalseWhenUntagged() {
        let md = SkillMetadata(
            name: "notes", description: "d", author: nil, version: nil,
            tags: ["productivity"], type: .instruction, tier: .personal,
            isEnabled: false,
            directoryURL: URL(fileURLWithPath: "/tmp/skill")
        )
        XCTAssertFalse(md.isChannel)
    }

    func testSkillMetadataIsChannelFalseWhenEmptyTags() {
        let md = SkillMetadata(
            name: "x", description: "d", author: nil, version: nil,
            tags: [], type: .instruction, tier: .builtin,
            isEnabled: true,
            directoryURL: URL(fileURLWithPath: "/tmp/skill")
        )
        XCTAssertFalse(md.isChannel)
    }

    func testSkillMetadataFieldAccess() {
        let md = SkillMetadata(
            name: "test", description: "desc", author: "a", version: "1.0",
            tags: ["channel"], type: .executable, tier: .community,
            isEnabled: true,
            directoryURL: URL(fileURLWithPath: "/tmp/skill")
        )
        XCTAssertEqual(md.name, "test")
        XCTAssertEqual(md.type, .executable)
        XCTAssertEqual(md.tier, .community)
        XCTAssertEqual(md.author, "a")
        XCTAssertEqual(md.version, "1.0")
        XCTAssertTrue(md.isChannel)
        XCTAssertTrue(md.isEnabled)
    }
}

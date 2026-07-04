import XCTest
@testable import Fae

final class FaeConfigParsingTests: XCTestCase {

    // MARK: - parseString

    func testParseStringQuoted() {
        XCTAssertEqual(FaeConfig.parseString("\"hello\""), "hello")
    }

    func testParseStringNil() {
        XCTAssertNil(FaeConfig.parseString("nil"))
    }

    func testParseStringUnquoted() {
        XCTAssertNil(FaeConfig.parseString("hello"))
    }

    // MARK: - parseBool

    func testParseBoolTrue() {
        XCTAssertTrue(FaeConfig.parseBool("true") == true)
    }

    func testParseBoolFalse() {
        XCTAssertTrue(FaeConfig.parseBool("false") == false)
    }

    func testParseBoolInvalid() {
        XCTAssertNil(FaeConfig.parseBool("maybe"))
    }

    // MARK: - parseInt

    func testParseIntValid() {
        XCTAssertEqual(FaeConfig.parseInt("42"), 42)
    }

    func testParseIntInvalid() {
        XCTAssertNil(FaeConfig.parseInt("abc"))
    }

    // MARK: - parseFloat

    func testParseFloatValid() {
        if let f = FaeConfig.parseFloat("3.14") { XCTAssertEqual(f, 3.14, accuracy: 0.01) }
    }

    func testParseFloatInvalid() {
        XCTAssertNil(FaeConfig.parseFloat("abc"))
    }

    // MARK: - parseStringArray

    func testParseStringArrayValid() {
        let result = FaeConfig.parseStringArray("[\"a\", \"b\"]")
        XCTAssertEqual(result, ["a", "b"])
    }

    func testParseStringArrayEmpty() {
        let result = FaeConfig.parseStringArray("[]")
        XCTAssertEqual(result, [])
    }

    func testParseStringArrayInvalid() {
        XCTAssertNil(FaeConfig.parseStringArray("not an array"))
    }

    // MARK: - escapeString

    func testEscapeStringNewline() {
        let escaped = FaeConfig.escapeString("hello\nworld")
        XCTAssertTrue(escaped.contains("\\n"))
    }

    func testEscapeStringPlain() {
        let escaped = FaeConfig.escapeString("hello")
        XCTAssertEqual(escaped, "hello")
    }

    // MARK: - unescapeString

    func testUnescapeStringNewline() {
        let unescaped = FaeConfig.unescapeString("hello\\nworld")
        XCTAssertTrue(unescaped.contains("\n"))
    }

    func testUnescapeStringPlain() {
        let unescaped = FaeConfig.unescapeString("hello")
        XCTAssertEqual(unescaped, "hello")
    }

    // MARK: - ADR-014 cloud lane: privacyLane round-trip

    func testPrivacyLaneDefaultIsLocal() {
        let config = FaeConfig()
        XCTAssertEqual(config.llm.privacyLane, "local")
        XCTAssertEqual(config.llm.resolvedPrivacyLane, "local")
    }

    func testPrivacyLaneRoundTripLocal() throws {
        let toml = """
        [llm]
        privacyLane = "local"
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("priv-lane-local-\(UUID().uuidString).toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = FaeConfig.load(from: url)
        XCTAssertEqual(config.llm.privacyLane, "local")
        XCTAssertEqual(config.llm.resolvedPrivacyLane, "local")
    }

    func testPrivacyLaneRoundTripAll() throws {
        let toml = """
        [llm]
        privacyLane = "all"
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("priv-lane-all-\(UUID().uuidString).toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = FaeConfig.load(from: url)
        XCTAssertEqual(config.llm.privacyLane, "all")
    }

    func testPrivacyLaneUnknownFallsBackToLocal() throws {
        let toml = """
        [llm]
        privacyLane = "unknown_value"
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("priv-lane-unknown-\(UUID().uuidString).toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = FaeConfig.load(from: url)
        // Unknown value must silently resolve to "local".
        XCTAssertEqual(config.llm.privacyLane, "local")
        XCTAssertEqual(config.llm.resolvedPrivacyLane, "local")
    }

    // MARK: - ADR-014 cloud lane: cloudDailyBudgetUSD round-trip

    func testCloudDailyBudgetUSDDefault() {
        let config = FaeConfig()
        XCTAssertEqual(config.llm.cloudDailyBudgetUSD, 2.0, accuracy: 0.001)
    }

    func testCloudDailyBudgetUSDRoundTrip() throws {
        let toml = """
        [llm]
        cloudDailyBudgetUSD = 5.0
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-5-\(UUID().uuidString).toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = FaeConfig.load(from: url)
        XCTAssertEqual(config.llm.cloudDailyBudgetUSD, 5.0, accuracy: 0.01)
    }

    func testCloudDailyBudgetUSDClampsToMin() throws {
        let toml = """
        [llm]
        cloudDailyBudgetUSD = 0.0
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-zero-\(UUID().uuidString).toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = FaeConfig.load(from: url)
        // Clamp floor: must be at least 0.01.
        XCTAssertGreaterThanOrEqual(config.llm.cloudDailyBudgetUSD, 0.01)
    }

    func testCloudDailyBudgetUSDClampsToMax() throws {
        let toml = """
        [llm]
        cloudDailyBudgetUSD = 999.0
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-huge-\(UUID().uuidString).toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = FaeConfig.load(from: url)
        // Clamp ceiling: must not exceed 100.0.
        XCTAssertLessThanOrEqual(config.llm.cloudDailyBudgetUSD, 100.0)
    }
}

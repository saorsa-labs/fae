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
}

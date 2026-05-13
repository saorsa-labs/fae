import XCTest
@testable import Fae

final class ToolStaticTests: XCTestCase {

    // MARK: - shellEscape (SafeSkillExecutor)

    func testShellEscapeSimple() {
        XCTAssertEqual(SafeSkillExecutor.shellEscape("hello"), "'hello'")
    }

    func testShellEscapeWithQuote() {
        let escaped = SafeSkillExecutor.shellEscape("it's")
        XCTAssertTrue(escaped.contains("'"))
    }

    // MARK: - hashArguments (SecurityEventLogger)

    func testHashArgumentsValid() {
        let hash = SecurityEventLogger.hashArguments(["key": "value"])
        XCTAssertNotNil(hash)
        XCTAssertEqual(hash?.count, 64) // SHA256 hex
    }

    func testHashArgumentsDeterministic() {
        let h1 = SecurityEventLogger.hashArguments(["a": 1])
        let h2 = SecurityEventLogger.hashArguments(["a": 1])
        XCTAssertEqual(h1, h2)
    }

    // MARK: - redactLongOpaqueTokens (SensitiveDataRedactor)

    func testRedactLongOpaqueTokens() {
        let longToken = String(repeating: "a", count: 40)
        let redacted = SensitiveDataRedactor.redactLongOpaqueTokens(longToken)
        XCTAssertTrue(redacted.contains("[REDACTED_TOKEN]"))
    }

    func testRedactShortText() {
        let redacted = SensitiveDataRedactor.redactLongOpaqueTokens("hello world")
        XCTAssertEqual(redacted, "hello world")
    }

    // MARK: - escapeHTML (TillDoneTool)

    func testEscapeHTML() {
        let escaped = TillDoneManager.escapeHTML("<script>alert(\"xss\")</script>")
        XCTAssertTrue(escaped.contains("&lt;"))
        XCTAssertTrue(escaped.contains("&gt;"))
    }

    // MARK: - clampInteger (SessionSearchTool)

    func testClampIntegerInt() {
        let result = SessionSearchTool.clampInteger(5, defaultValue: 10, lower: 0, upper: 10)
        XCTAssertEqual(result, 5)
    }

    func testClampIntegerTooHigh() {
        let result = SessionSearchTool.clampInteger(100, defaultValue: 10, lower: 0, upper: 10)
        XCTAssertEqual(result, 10)
    }

    func testClampIntegerNil() {
        let result = SessionSearchTool.clampInteger(nil, defaultValue: 10, lower: 0, upper: 10)
        XCTAssertEqual(result, 10)
    }

    func testClampIntegerString() {
        let result = SessionSearchTool.clampInteger("7", defaultValue: 10, lower: 0, upper: 10)
        XCTAssertEqual(result, 7)
    }

    // MARK: - inferJSONSchemaType (Tool)

    func testInferJSONSchemaTypeInteger() {
        let (type, required) = ReadTool.inferJSONSchemaType(from: "integer value")
        XCTAssertEqual(type, "integer")
        XCTAssertFalse(required)
    }

    func testInferJSONSchemaTypeBoolean() {
        let (type, required) = ReadTool.inferJSONSchemaType(from: "bool flag required")
        XCTAssertEqual(type, "boolean")
        XCTAssertTrue(required)
    }

    func testInferJSONSchemaTypeDefault() {
        let (type, required) = ReadTool.inferJSONSchemaType(from: "some description")
        XCTAssertEqual(type, "string")
        XCTAssertFalse(required)
    }
}

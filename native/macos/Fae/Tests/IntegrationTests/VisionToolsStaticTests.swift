import XCTest
@testable import Fae

final class VisionToolsStaticTests: XCTestCase {

    // MARK: - normalize

    func testNormalizeCarriageReturn() {
        let normalized = TypeTextTool.normalize("hello\r\nworld")
        XCTAssertEqual(normalized, "hello\nworld")
    }

    func testNormalizeCROnly() {
        let normalized = TypeTextTool.normalize("hello\rworld")
        XCTAssertEqual(normalized, "hello\nworld")
    }

    func testNormalizeNil() {
        let normalized = TypeTextTool.normalize(nil as String?)
        XCTAssertNil(normalized)
    }

    // MARK: - didVerifyTypedText

    func testDidVerifyTypedTextSuccess() {
        XCTAssertTrue(TypeTextTool.didVerifyTypedText(
            "hello", beforeValue: "old text", afterValue: "old texthello"
        ))
    }

    func testDidVerifyTypedTextNotPresent() {
        XCTAssertFalse(TypeTextTool.didVerifyTypedText(
            "hello", beforeValue: "old text", afterValue: "old text"
        ))
    }

    func testDidVerifyTypedTextNoChange() {
        XCTAssertFalse(TypeTextTool.didVerifyTypedText(
            "hello", beforeValue: "hello", afterValue: "hello"
        ))
    }
}

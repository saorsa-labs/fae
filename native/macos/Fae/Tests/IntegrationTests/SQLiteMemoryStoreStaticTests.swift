import XCTest
@testable import Fae

final class SQLiteMemoryStoreStaticTests: XCTestCase {

    // MARK: - quotedFTSToken

    func testQuotedFTSToken() {
        let token = SQLiteMemoryStore.quotedFTSToken("hello")
        XCTAssertEqual(token, "\"hello\"")
    }

    func testQuotedFTSTokenEscapesQuotes() {
        let token = SQLiteMemoryStore.quotedFTSToken("say \"hi\"")
        XCTAssertEqual(token, "\"say \"\"hi\"\"\"")
    }

    // MARK: - escapeLikePattern

    func testEscapeLikePatternPercent() {
        let escaped = SQLiteMemoryStore.escapeLikePattern("100%")
        XCTAssertEqual(escaped, "100\\%")
    }

    func testEscapeLikePatternUnderscore() {
        let escaped = SQLiteMemoryStore.escapeLikePattern("user_name")
        XCTAssertEqual(escaped, "user\\_name")
    }

    func testEscapeLikePatternBackslash() {
        let escaped = SQLiteMemoryStore.escapeLikePattern("a\\b")
        XCTAssertEqual(escaped, "a\\\\b")
    }

    // MARK: - decodeTags

    func testDecodeTagsValid() {
        let tags = SQLiteMemoryStore.decodeTags(#"["swift","rust"]"#)
        XCTAssertEqual(tags, ["swift", "rust"])
    }

    func testDecodeTagsEmpty() {
        let tags = SQLiteMemoryStore.decodeTags("[]")
        XCTAssertTrue(tags.isEmpty)
    }

    func testDecodeTagsInvalid() {
        let tags = SQLiteMemoryStore.decodeTags("not json")
        XCTAssertTrue(tags.isEmpty)
    }
}

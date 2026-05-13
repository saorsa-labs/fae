import XCTest
@testable import Fae

final class MetaOptNarratorTests: XCTestCase {

    // MARK: - extractTopicHint

    func testExtractTopicHintTool() {
        XCTAssertEqual(MetaOptNarrator.extractTopicHint("fix tool calling"), "how I use tools")
    }

    func testExtractTopicHintFormat() {
        XCTAssertEqual(MetaOptNarrator.extractTopicHint("improve formatting"), "formatting")
    }

    func testExtractTopicHintMemory() {
        XCTAssertEqual(MetaOptNarrator.extractTopicHint("better memory usage"), "how I use our conversation history")
    }

    func testExtractTopicHintDefault() {
        XCTAssertEqual(MetaOptNarrator.extractTopicHint("random topic"), "how I help you")
    }

    // MARK: - describeFromKeywords

    func testDescribeFromKeywordsBrevity() {
        let desc = MetaOptNarrator.describeFromKeywords("reduce brevity and interruptions")
        XCTAssertTrue(desc.contains("shorter"))
    }

    func testDescribeFromKeywordsClarification() {
        let desc = MetaOptNarrator.describeFromKeywords("ask for clarification")
        XCTAssertTrue(desc.contains("understand"))
    }

    func testDescribeFromKeywordsDefault() {
        let desc = MetaOptNarrator.describeFromKeywords("completely unknown topic")
        XCTAssertFalse(desc.isEmpty)
    }
}

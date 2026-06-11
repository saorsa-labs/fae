import XCTest
@testable import Fae

final class ImplicitFeedbackDetectorTests: XCTestCase {

    // MARK: - wordBigrams

    func testWordBigrams() {
        let bigrams = ImplicitFeedbackDetector.wordBigrams("hello world foo")
        XCTAssertFalse(bigrams.isEmpty)
    }

    func testWordBigramsSingleWord() {
        // Single-word inputs fall back to the unigram so short re-asks
        // ("weather", "weather?") still compare as similar.
        let bigrams = ImplicitFeedbackDetector.wordBigrams("hello")
        XCTAssertEqual(bigrams, ["hello"])
    }

    func testWordBigramsEmpty() {
        let bigrams = ImplicitFeedbackDetector.wordBigrams("")
        XCTAssertTrue(bigrams.isEmpty)
    }
}
